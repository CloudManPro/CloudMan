# Importações
from fastapi import FastAPI, Request
import boto3
import json
import os
import logging
import watchtower
import datetime
from dotenv import load_dotenv
import asyncio
from concurrent.futures import ThreadPoolExecutor
from threading import Semaphore
from threading import Lock
import requests
# Carregar as variáveis de ambiente do arquivo .env e habilitar o patch automático
load_dotenv()
XRay = os.getenv('XRay_Enabled',"False")
if XRay == "True":
    XRayEnabled = True
    from aws_xray_sdk.core import xray_recorder
    from aws_xray_sdk.core import patch_all
    patch_all()
else:
    XRayEnabled = False



# Lendo as variáveis de ambiente
Region = os.getenv("Region")
AccountID = os.getenv("Account")
InstanceName = os.getenv("Name", "DefaultInstanceName")  # Valor padrão se Name não estiver definido
SegmentName = "EC2_" + InstanceName
InstanceID = os.environ.get('EC2_INSTANCE_ID',InstanceName)
PrimesCount = int(os.environ.get('Primes', 0))
VarLogs = os.environ.get('EnableStatusLogs', "True")
if VarLogs == "True":
    StatusLogsEnabled = True
else:
    StatusLogsEnabled = False


# Configurar a sessão do Boto3 com a região
boto3.setup_default_session(region_name=Region)

# Configurar logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)
cw_handler = watchtower.CloudWatchLogHandler(
    log_group=os.environ.get('aws_cloudwatch_log_group_Target_Name_0'),
    stream_name=SegmentName
)
logger.addHandler(cw_handler)
logger.info(f"EC2 Host: {InstanceName} Region {Region}")
app = FastAPI()

def LogMessage(Msg):
    if StatusLogsEnabled:
        logger.info(Msg)

def generate_primes(n):
    """
    Generate a list of prime numbers.
    :param n: The number of prime numbers to generate.
    :return: A list of prime numbers.
    """
    primes = []
    num = 2  # Starting from the first prime number
    while len(primes) < n:
        for i in range(2, num):
            if num % i == 0:
                break
        else:
            primes.append(num)
        num += 1
    return primes

def execute_with_xray(segment_name, function, *args, **kwargs):
    LogMessage(segment_name)
    if XRayEnabled:
        with xray_recorder.in_subsegment(segment_name):
            return function(*args, **kwargs)
    else:
        return function(*args, **kwargs)


# Identifica a URL e o cliente de cada SQS Target
SQSTargetClients = []  # Lista para armazenar pares de clientes SQS e URLs de fila
i = 0
while True:
    Name = os.getenv(f"aws_sqs_queue_Target_Name_{i}")
    Region = os.getenv(f"aws_sqs_queue_Target_Region_{i}")
    Account = os.getenv(f"aws_sqs_queue_Target_Account_{i}")
    if Name is not None:
        sqs_client = boto3.client('sqs', region_name=Region)
        URL = f"https://sqs.{Region}.amazonaws.com/{Account}/{Name}"
        SQSTargetClients.append((sqs_client, URL))
        logger.info(f"SQS Target {i} {Name}")
        logger.info(f"Queue Target Url: {URL}")
    else:
        logger.info(f"Total SQS Targets: {i}")
        break
    i += 1

# Identifica a ARN e o cliente de cada SNS Target
SNSTargetClients = []  # Lista para armazenar pares de clientes SNS e ARNs de tópicos
i = 0
while True:
    Name = os.getenv(f"aws_sns_topic_Target_Name_{i}")
    Region = os.getenv(f"aws_sns_topic_Target_Region_{i}")
    Account = os.getenv(f"aws_sns_topic_Target_Account_{i}")
    if Name is not None:
        sns_client = boto3.client('sns', region_name=Region)
        ARN = f"arn:aws:sns:{Region}:{Account}:{Name}"
        SNSTargetClients.append((sns_client, ARN))
        logger.info(f"SNS Target: {i} {Name}")
        logger.info(f"SNS Topic ARN: {ARN}")
    else:
        logger.info(f"Total SNS Targets: {i}")
        break
    i += 1

def init_table(table_resource, TableName):
    # Chamada ao wrapper para obter o item
    response = execute_with_xray(f"get_item_dynamodb_table_{TableName}", table_resource.get_item, Key={'ID': "1"})
    if 'Item' not in response:
        ItemData = f"Criado por {InstanceName}"
        execute_with_xray(f"put_item_dynamodb_table_{TableName}", table_resource.put_item, Item={'ID': "1", "InstanceName": ItemData, 'Cont': 0})
        logger.info(f"Initialized DynamoDB table: {TableName}")


DynamoDBTargetList = []
i = 0
while True:
    TableName = os.getenv(f"aws_dynamodb_table_Target_Name_{i}")
    Region = os.getenv(f"aws_dynamodb_table_Target_Region_{i}") 
    if TableName:
        dynamodb = boto3.resource('dynamodb', region_name=Region)
        table_resource = dynamodb.Table(TableName)
        DynamoDBTargetList.append((dynamodb, table_resource))
        init_table(table_resource, TableName)
    else:
        break
    i += 1

# Identifica cada S3 target
S3TargetList = []  # Lista para armazenar pares de clientes S3 e nomes de buckets
i = 0
while True:
    Name = os.getenv(f"aws_s3_bucket_Target_Name_{i}")
    Region = os.getenv(f"aws_s3_bucket_Target_Region_{i}")
    if Name is not None:
        s3_client = boto3.client('s3', region_name=Region)
        logger.info(f"S3 Target: {i} {Name}")
        S3TargetList.append((s3_client, Name))
    else:
        S3TargetMaxNumber = i
        break
    i += 1

# Identifica cada EFS target
EFSTargetList = []  # Lista para armazenar os nomes dos sistemas de arquivos EFS
i = 0
while True:
    Name = os.getenv(f"aws_efs_file_system_Target_Name_{i}")
    Path = os.getenv(f"aws_efs_access_point_Target_Path_{i}")
    if Name is not None:
        # Aqui você poderia inicializar um cliente EFS se necessário, 
        # mas para a montagem, normalmente usamos apenas o nome/identificador
        logger.info(f"EFS Target: {i} {Name}")
        EFSTargetList.append([Name,Path])
    else:
        EFSTargetMaxNumber = i
        break
    i += 1

# Identifica cada Lambda target
LambdaTargetList = []  # Lista para armazenar nomes de funções Lambda
i = 0
while True:
    FunctionName = os.getenv(f"aws_lambda_function_target_name_{i}")
    Region = os.getenv(f"aws_lambda_function_target_region_{i}")
    if FunctionName is not None:
        lambda_client = boto3.client('lambda', region_name=Region)
        logger.info(f"Lambda Target: {i} {FunctionName}")
        LambdaTargetList.append((lambda_client, FunctionName))
    else:
        LambdaTargetMaxNumber = i
        break
    i += 1

# Identifica a URL de cada ALB Target
ALBTargetURLs = []  # Lista para armazenar os nomes e URLs dos ALBs
i = 0 
while True:
    URL = os.getenv(f"aws_lb_DNS_Name_{i}")
    ALBName = os.getenv(f"aws_lb_Name_{i}")
    if URL is not None:
        ALBTargetURLs.append([ALBName, URL])
        logger.info(f"ALB Target {i}: {ALBName}, URL: {URL}")
    else:
        logger.info(f"Total ALBs Targets: {i}")
        break
    i += 1  

# Identifica a URL e o cliente de cada SQS Source
SQSSourceMaxNumber = 4
SQSSourceClients = []  # Lista para armazenar pares de clientes SQS e URLs de fila
i = 0
while True:
    Name = os.getenv(f"aws_sqs_queue_Source_Name_{i}")
    Region = os.getenv(f"aws_sqs_queue_Source_Region_{i}")
    Account = os.getenv(f"aws_sqs_queue_Source_Account_{i}")
    if Name is not None:
        sqs_client = boto3.client('sqs', region_name=Region)
        URL = f"https://sqs.{Region}.amazonaws.com/{Account}/{Name}"
        SQSSourceClients.append((sqs_client, URL))
        logger.info(f"SQS Source: {i} {Name}")
    else:
        SQSSourceMaxNumber = i
        break
    i += 1

send_to_all_outputs_semaphore = Semaphore(1)
def send_to_all_outputs(message_body, URLPath="", Method="GET"):
    with send_to_all_outputs_semaphore:
        Agora = datetime.datetime.now()
        execute_with_xray('send_to_all_outputs', _send_to_all_outputs_helper, message_body, URLPath, Method, Agora)

def _send_to_all_outputs_helper(message_body, URLPath, Method, Agora):
    for sqs_client, queue_url in SQSTargetClients:
        execute_with_xray(f'send_message_to_{queue_url}', sqs_client.send_message, QueueUrl=queue_url, MessageBody=message_body)
        
    for sns_client, topic_arn in SNSTargetClients:
        execute_with_xray(f'send_message_to_sns_{topic_arn}', sns_client.publish, TopicArn=topic_arn, Message=message_body)
    
    for dynamodb, Table in DynamoDBTargetList:
        response = execute_with_xray(f'get_item_{Table.table_name}', Table.get_item, Key={'ID': "1"})
        if 'Item' in response:
            item = response['Item']
            cont = item['Cont'] + 1
            execute_with_xray(f"update_item_{Table.table_name}", Table.update_item, Key={'ID': "1"}, UpdateExpression='SET Cont = :val1', ExpressionAttributeValues={':val1': cont})
            
            ID = InstanceName + ":" + str(Agora)
            execute_with_xray(f"put_item_{Table.table_name}", Table.put_item, Item={'ID': ID, "Message": message_body})

    for s3_client, bucket_name in S3TargetList:
        folder_name = InstanceName + "/"
        file_name = InstanceName + ":" + str(Agora) + ".txt"
        file_path = folder_name + file_name
        execute_with_xray(f"put_object_{bucket_name}", s3_client.put_object, Bucket=bucket_name, Key=file_path, Body=message_body)

    for EFSName, mount_path in EFSTargetList:
        if not os.path.exists(mount_path):
            os.makedirs(mount_path)
        file_name = f"{EFSName}-{Agora.strftime('%Y%m%d%H%M%S')}.txt"
        file_path = os.path.join(mount_path, file_name)
        with open(file_path, 'w') as file:
            file.write(message_body)
        LogMessage(f"Mensagem salva no EFS ({EFSName}): {mount_path} : {file_name}")

    for ALBName, URL in ALBTargetURLs:
        URL = "http://" + URL + "/" + URLPath
        try:
            headers = { 'Content-Type': 'application/json', 'X-Amzn-Trace-Id': f"Root={xray_recorder.current_subsegment().trace_id}"}
            def post_request():
                return requests.post(URL, data=json.dumps({"dados": message_body}), headers=headers)
            def get_request():
                return requests.get(URL, headers=headers)
            if Method == "POST":
                response = execute_with_xray(f"send_to_ALB_{ALBName}_POST", post_request)
            elif Method == "GET":
                response = execute_with_xray(f"send_to_ALB_{ALBName}_GET", get_request)
            if response.status_code == 200:
                LogMessage(f"Mensagem enviada para o ALB ({ALBName}) em {URL}")
            else:
                logger.error(f"Erro ao enviar para o ALB ({ALBName}) em {URL}: Status Code {response.status_code}")
        except requests.exceptions.RequestException as e:
            logger.error(f"Exceção ao enviar para o ALB ({ALBName}) em {URL}: {e}")


    for lambda_client, function_name in LambdaTargetList:
        payload = json.dumps({'message': message_body})
        execute_with_xray(f"invoke_lambda_{function_name}", lambda_client.invoke, FunctionName=function_name, InvocationType='Event', Payload=payload)

#Retorna a rota "/health" para o health check do target group
@app.get("/health")
async def health_check():
    return {"status": "healthy"}

# Rota catch-all para requisições GET
@app.api_route("/{full_path:path}", methods=["GET"])
async def catch_all_get(full_path: str, request: Request):
    xray_trace_id = request.headers.get('X-Amzn-Trace-Id')
    LogMessage(f"Receive GET Method to '{full_path}'")
    # Inicia um segmento X-Ray para a requisição da API
    segment = xray_recorder.begin_segment(SegmentName)
    try:
        Message = f"GET request received from {InstanceName} to path: {full_path}"
        send_to_all_outputs(Message,full_path,"GET")
    finally:
        # Encerra o segmento X-Ray após o processamento da requisição
        xray_recorder.end_segment()
    return {"message": Message}

@app.api_route("/{full_path:path}", methods=["POST"])
async def catch_all_post(full_path: str, request: Request):
    try:
        body = await request.json()
        message_body = str(body)
        LogMessage(f"Receive Post Method to '{full_path}': {message_body}")
        segment = xray_recorder.begin_segment(SegmentName)
        Message = f"Message received from API {InstanceName}: {message_body}"
        send_to_all_outputs(Message,full_path,"POST")
    except Exception as e:
        logger.error(f"Erro ao processar requisição POST: {e}")
        return {"status": "Error", "message": str(e)}, 500
    finally:
        xray_recorder.end_segment()
    return {"status": "Message processed"}

# Tarefa assíncrona para processar mensagens SQS
# Variável global e um lock para segurança em ambientes multithread
Count = 0
count_lock = Lock()

async def process_sqs_messages():
    global Count
    with count_lock:  # Garante que apenas uma thread modifique Count por vez
        Count += 1
        LogMessage(f"LoopMain {Count} {InstanceName}")
    with ThreadPoolExecutor(max_workers=len(SQSSourceClients)) as executor:
        loop = asyncio.get_event_loop()
        tasks = []
        for sqs_client, queue_url in SQSSourceClients:
            task = loop.run_in_executor(executor, process_messages_from_queue, sqs_client, queue_url)
            tasks.append(task)
        await asyncio.gather(*tasks)

# Evento de inicialização da aplicação para iniciar o processamento das mensagens SQS
@app.on_event("startup")
async def startup_event():
    if SQSSourceClients:
        asyncio.create_task(process_sqs_messages())
    else:
        logger.error("SQSSourceClients está vazio, nenhuma tarefa de processamento de SQS foi criada.")

# A função 'process_messages_from_queue' permanece a mesma
def process_messages_from_queue(sqs_client, queue_url):
    while True:
        # Iniciar um segmento para cada iteração de processamento de mensagem na thread
        segment = xray_recorder.begin_segment(SegmentName)
        try:
            with xray_recorder.in_subsegment('receive_message') as subsegment:
                messages = sqs_client.receive_message(
                    QueueUrl=queue_url,
                    MaxNumberOfMessages=1,
                    WaitTimeSeconds=20  # Long polling
                )
            if 'Messages' in messages:
                for message in messages['Messages']:
                    # Tratar cada mensagem em um subsegmento próprio
                    with xray_recorder.in_subsegment('process_message') as subsegment:
                        send_to_all_outputs(message['Body'])

                    with xray_recorder.in_subsegment('delete_message') as subsegment:
                        sqs_client.delete_message(
                            QueueUrl=queue_url,
                            ReceiptHandle=message['ReceiptHandle']
                        )
                    LogMessage(f"Mensagem processada por {InstanceID} e deletada da fila: {queue_url}")
        except Exception as e:
            logger.error(f"Erro ao processar mensagem da fila {queue_url}: {e}")
        finally:
            # Encerrar o segmento após processar a mensagem na thread
            xray_recorder.end_segment()

