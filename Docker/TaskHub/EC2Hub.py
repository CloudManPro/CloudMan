# Importações
from fastapi import FastAPI, Request
import boto3
import json
import os
import logging
import datetime
from dotenv import load_dotenv
import asyncio
from concurrent.futures import ThreadPoolExecutor
from threading import Semaphore, Lock
import requests
import random

# Importações condicionais
database = os.getenv(f"AWS_DB_INSTANCE_TARGET_NAME_0")
if database is not None:
    import mysql.connector
    from mysql.connector import Error
    import pymysql

# Carregar as variáveis de ambiente do arquivo .env
load_dotenv()

ClaudMapNamespaceName = os.environ.get('AWS_SERVICE_DISCOVERY_SERVICE_TARGET_NAME_0', '')
ClaudMapServiceRegion = os.environ.get('AWS_SERVICE_DISCOVERY_SERVICE_TARGET_REGION_0')
if ClaudMapNamespaceName:
    import dns.resolver

# Lendo as variáveis de ambiente para configuração
Region = os.getenv("REGION")
AccountID = os.getenv("ACCOUNT")
InstanceName = os.getenv("NAME", "DefaultInstanceName")
SegmentName = InstanceName # Usado pelo X-Ray se ativado
InstanceID = os.environ.get('EC2_INSTANCE_ID', InstanceName)
PrimesFloor = int(os.environ.get('PRIMES_FLOOR', 0))
PrimesCeil = int(os.environ.get('PRIMES_CEIL', 0))

# Controle de logging baseado em variável de ambiente. Simplificado.
StatusLogsEnabled = os.environ.get('ENABLESTATUSLOGS', 'True').lower() == 'true'

# Configurar a sessão do Boto3 com a região correta
if Region:
    boto3.setup_default_session(region_name=Region)

# --- CORREÇÃO APLICADA AQUI ---
# Configuração de Logging Simplificada.
# Remove a dependência do Watchtower. Os logs agora são enviados para a saída padrão (stdout),
# onde serão capturados pelo systemd e encaminhados para um arquivo. Este arquivo, por sua vez,
# é monitorado pelo Agente do CloudWatch, que envia os logs para a AWS.

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)

# Obtém uma instância do logger para ser usada em toda a aplicação.
logger = logging.getLogger(__name__)

# Instancia a aplicação FastAPI
app = FastAPI()

# Função auxiliar para logar mensagens, respeitando a flag de habilitação.
def LogMessage(Msg):
    if StatusLogsEnabled:
        logger.info(Msg)

# Log inicial para confirmar que a aplicação foi configurada e está iniciando
LogMessage(f"Logging configurado. Instância '{InstanceName}' na região '{Region}' iniciando.")

XRay = os.getenv('XRay_Enabled',"False")
if XRay == "True":
    XRayEnabled = True
    from aws_xray_sdk.core import xray_recorder
    from aws_xray_sdk.core import patch_all
    patch_all()
    LogMessage(f"Enable XRay")
else:

    XRayEnabled = False

# Função para listar todos os serviços em um namespace
def list_services_in_namespace(client, namespace_id):
    services = []
    paginator = client.get_paginator('list_services')
    for page in paginator.paginate(Filters=[{'Name': 'NAMESPACE_ID', 'Values': [namespace_id]}]):
        services.extend(page['Services'])
    return services


# Função para encontrar o ID de um namespace pelo nome
def find_namespace_id_by_name(client, namespace_name):
    paginator = client.get_paginator('list_namespaces')
    for page in paginator.paginate():
        for ns in page['Namespaces']:
            if ns['Name'] == namespace_name:
                return ns['Id']
    return None

# Função para listar instâncias de um serviço
def list_instances_of_service(client, service_id):
    instances = []
    paginator = client.get_paginator('list_instances')
    for page in paginator.paginate(ServiceId=service_id):
        instances.extend(page['Instances'])
    return instances

#Função que resolve DNS SRV
def resolve_srv_record(service_name):
   if True:#try:
        LogMessage(f" service_name {service_name}")
        answers = dns.resolver.resolve(service_name, 'SRV')
        LogMessage(f" answers {answers}")
        for rdata in answers:
            return str(rdata.target).rstrip('.'), rdata.port
   # except Exception as e:
   #     LogMessage(f"Erro ao resolver SRV para {service_name}: {e}")
        return None, None
    
ClientService = boto3.client('servicediscovery', region_name=ClaudMapServiceRegion)
# Encontrar o ID do namespace
if ClaudMapNamespaceName != "":
    if XRayEnabled:
            xray_recorder.begin_segment(SegmentName)
    ClaudMapNamespaceID = find_namespace_id_by_name(ClientService, ClaudMapNamespaceName)
    if ClaudMapNamespaceID:
        LogMessage(f"Cloud Map Namespace ID encontrado: {ClaudMapNamespaceID}")
        # Listar todos os serviços no namespace
        services = list_services_in_namespace(ClientService, ClaudMapNamespaceID)
        for service in services:
            service_id = service['Id']
            service_name = service['Name']
            LogMessage(f"Service: {service_name} (ID: {service_id})")
            # Listar instâncias para cada serviço
            instances = list_instances_of_service(ClientService, service_id)
            for instance in instances:
                LogMessage(f"InstanceId: {instance['Id']}")
                for key, value in instance['Attributes'].items():
                    LogMessage(f"  {key}: {value}")
    else:
        LogMessage("CloudMap Namespace não encontrado.")
    if XRayEnabled:
            xray_recorder.end_segment()
    
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
    #LogMessage(f"Primes Number generated: {num}")
    return primes

def execute_with_xray(segment_name, function, *args, **kwargs):
    if XRayEnabled:
        with xray_recorder.in_subsegment(segment_name):
            return function(*args, **kwargs)
    else:
        return function(*args, **kwargs)

def send_request(Name, URL, Method, message_body=None):
    """
    Envia uma requisição HTTP para a URL especificada.
    :param name: Nome do ALB ou Task para o qual a mensagem está sendo enviada.
    :param URL: URL para enviar a requisição.
    :param Method: Método HTTP ('GET' ou 'POST').
    :param message_body: Corpo da mensagem para requisições POST (opcional).
    :return: None
    """
    UnknownMethod = False
    try:
        headers = {'Content-Type': 'application/json'}
        def post_request():
            return requests.post(URL, data=json.dumps({"MSG Data": message_body}), headers=headers)
        def get_request():
            return requests.get(URL, headers=headers)
        LogMessage(f"Target Name {Name}")
        if Method == "POST":
            response = execute_with_xray(Name, post_request)
        elif Method == "GET":
            response = execute_with_xray(Name, get_request)
        else:
            UnknownMethod = True
        if not UnknownMethod:
            if response.status_code == 200:
                #LogMessage(f"Send Message to {name}: {URL}")
                pass
            else:
                LogMessage(f"Erro ao enviar para {Name} em {URL}: Status Code {response.status_code}")
        else:
            LogMessage("Unknown Method")

    except requests.exceptions.RequestException as e:
        LogMessage(f"Exceção ao enviar para {Name} em {URL}: {e}")

# Funções para conectar e executar queries no MySQL
def create_connection(host_name, user_name, user_password, db_name):
    connection = None
    try:
        connection = mysql.connector.connect(
            host=host_name,
            user=user_name,
            passwd=user_password,
            database=db_name
        )
        LogMessage("Conexão ao MySQL DB bem-sucedida")
    except Error as e:
        LogMessage(f"O erro '{e}' ocorreu")
    return connection

def execute_query(connection, query, values=None):
    cursor = connection.cursor()
    LogMessage(f"Passou aqui B")
    try:
        if values:
            cursor.execute(query, values)
        else:
            cursor.execute(query)
        connection.commit()
    except Error as e:
        LogMessage(f"O erro '{e}' ocorreu")

def fetch_query(connection, query):
    try:
        with connection.cursor() as cursor:
            cursor.execute(query)
            return cursor.fetchall()  # Retorna todos os registros obtidos
    except Exception as e:
        LogMessage(f"Erro ao buscar dados: {e}")
        return None

    
#Identificação dos dos recursos conectados
    
# Identifica a URL e o cliente de cada SQS Target
SQSTargetClients = []  # Lista para armazenar pares de clientes SQS e URLs de fila
SQSNameList = []
i = 0
while True:
    Name = os.getenv(f"aws_sqs_queue_Target_Name_{i}")
    Region = os.getenv(f"aws_sqs_queue_Target_Region_{i}")
    Account = os.getenv(f"aws_sqs_queue_Target_Account_{i}")
    if Name is not None:
        sqs_client = boto3.client('sqs', region_name=Region)
        URL = f"https://sqs.{Region}.amazonaws.com/{Account}/{Name}"
        SQSTargetClients.append((sqs_client, URL,Name))
        SQSNameList.append(Name)
    else:
        break
    i += 1
logger.info(f"SQS Target Total: {i} {SQSNameList}")

# Identifica a ARN e o cliente de cada SNS Target
SNSTargetClients = []  # Lista para armazenar pares de clientes SNS e ARNs de tópicos
SNSNameList =[]
i = 0
while True:
    Name = os.getenv(f"aws_sns_topic_Target_Name_{i}")
    Region = os.getenv(f"aws_sns_topic_Target_Region_{i}")
    Account = os.getenv(f"aws_sns_topic_Target_Account_{i}")
    if Name is not None:
        sns_client = boto3.client('sns', region_name=Region)
        ARN = f"arn:aws:sns:{Region}:{Account}:{Name}"
        SNSTargetClients.append((sns_client, ARN, Name))
        SNSNameList.append(Name)
    else:
        break
    i += 1
logger.info(f"SNS Target Total: {i} {SNSNameList}")

def init_table(table_resource, TableName):
    if XRayEnabled:
            xray_recorder.begin_segment(SegmentName)
    try:
        response = execute_with_xray(TableName, table_resource.get_item, Key={'ID': "1"})
        if 'Item' not in response:
            ItemData = f"Criado por {InstanceName}"
            execute_with_xray(TableName, table_resource.put_item, Item={'ID': "1", "InstanceName": ItemData, 'Cont': 0})
    except Exception as e:
        LogMessage(f"Erro ao iniciar a tabela {TableName}: {e}")
    finally:
        if XRayEnabled:
            xray_recorder.end_segment()

DynamoDBTargetList = []
DynamoNameList = []
i = 0
while True:
    TableName = os.getenv(f"aws_dynamodb_table_Target_Name_{i}")
    Region = os.getenv(f"aws_dynamodb_table_Target_Region_{i}") 
    if TableName:
        dynamodb = boto3.resource('dynamodb', region_name=Region)
        table_resource = dynamodb.Table(TableName)
        DynamoDBTargetList.append((dynamodb, table_resource,TableName ))
        DynamoNameList.append(TableName)
        init_table(table_resource, TableName)
    else:
        break
    i += 1
logger.info(f"DynamoDB Target Total: {i} {DynamoNameList}")

# Identifica cada S3 target
S3TargetList = []  # Lista para armazenar pares de clientes S3 e nomes de buckets
S3NameList = []
i = 0
while True:
    Name = os.getenv(f"aws_s3_bucket_Target_Name_{i}")
    Region = os.getenv(f"aws_s3_bucket_Target_Region_{i}")
    if Name is not None:
        s3_client = boto3.client('s3', region_name=Region)
        S3TargetList.append((s3_client, Name))
        S3NameList.append(Name)
    else:
        S3TargetMaxNumber = i
        break
    i += 1
logger.info(f"S3 Target Total: {i} {S3NameList}")

# Identifica cada EFS target
EFSTargetList = []  # Lista para armazenar os nomes dos sistemas de arquivos EFS
EFSNameList = []
i = 0
while True:
    Name = os.getenv(f"aws_efs_file_system_Target_Name_{i}")
    Path = os.getenv(f"aws_efs_access_point_Target_Path_{i}")
    if Name is not None:
        # Aqui você poderia inicializar um cliente EFS se necessário, 
        # mas para a montagem, normalmente usamos apenas o nome/identificador
        EFSTargetList.append([Name,Path])
        EFSNameList.append(Name)
    else:
        EFSTargetMaxNumber = i
        break
    i += 1
logger.info(f"EFS Target Total: {i} {EFSNameList}")

# Identifica cada Lambda target
LambdaTargetList = []  # Lista para armazenar nomes de funções Lambda
LambdaNameList = []
i = 0
while True:
    FunctionName = os.getenv(f"aws_lambda_function_Target_Name_{i}")
    Region = os.getenv(f"aws_lambda_function_Target_Region_{i}")
    if FunctionName is not None:
        lambda_client = boto3.client('lambda', region_name=Region)
        LambdaTargetList.append((lambda_client, FunctionName))
        LambdaNameList.append(FunctionName)
    else:
        LambdaTargetMaxNumber = i
        break
    i += 1
logger.info(f"Lambda Target Total: {i} {LambdaNameList}")

# Identifica a URL de cada ALB Target
ALBTargetURLs = []  # Lista para armazenar os nomes e URLs dos ALBs
ALBNameList = []
i = 0 
while True:
    URL = os.getenv(f"aws_lb_DNS_Name_{i}")
    ALBName = os.getenv(f"aws_lb_Name_{i}")
    if URL is not None:
        ALBTargetURLs.append([ALBName, URL])
        ALBNameList.append(ALBName)
    else:
        break
    i += 1 
logger.info(f"ALB Target Total: {i} {ALBNameList}")

# Identifica Nomes dos containers target
ContainerTargetList = []  # Lista para armazenar os nomes e URLs dos ALBs
ContainerNameList = []
if ClaudMapNamespaceName != "":
    i = 0 
    while True:
        ContainerName = os.getenv(f"Container_Target_Name_{i}")
        ContainerRegion = os.getenv(f"Container_Target_Region_{i}")
        if ContainerName is not None:
            ContainerTargetList.append([ContainerName,ContainerRegion])
            ContainerNameList.append(ContainerName)
        else:
            break
        i += 1  
logger.info(f"Containers Target Total: {i} {ContainerNameList}")

# Identifica a URL e o cliente de cada SQS Source
SQSSourceList = []
SQSNameList = []  # Lista para armazenar pares de clientes SQS e URLs de fila
i = 0
while True:
    Name = os.getenv(f"aws_sqs_queue_Source_Name_{i}")
    Region = os.getenv(f"aws_sqs_queue_Source_Region_{i}")
    Account = os.getenv(f"aws_sqs_queue_Source_Account_{i}")
    if Name is not None:
        sqs_client = boto3.client('sqs', region_name=Region)
        URL = f"https://sqs.{Region}.amazonaws.com/{Account}/{Name}"
        SQSSourceList.append((sqs_client, URL,Name))
        SQSNameList.append(Name)
    else:
        SQSSourceMaxNumber = i
        break
    i += 1
logger.info(f"SQS Queue Total: {i} {SQSNameList}")



# Lista para armazenar informações de username e password de cada secret
SecretsCredentials = []
SecretNameList = []
i = 0
while True:
    SecretName = os.getenv(f"aws_secretsmanager_secret_version_Source_Name_{i}")
    SecretARN = os.getenv(f"aws_secretsmanager_secret_version_Source_ARN_{i}")
    if SecretName is not None:
        client = boto3.client('secretsmanager', region_name=Region)
        response = client.get_secret_value(SecretId=SecretARN)
        secret = json.loads(response['SecretString'])
        username = secret['username']
        password = secret['password']
        SecretsCredentials.append([SecretName,username, password])
        SecretNameList.append(SecretName)
    else:
        break
    i += 1
logger.info(f"Secrets Target Total: {i} {SecretNameList}")

# inicializa Lista para armazenar as conexões RDS e criação de tabela.
RDSConnections = []
DataBaseList = []
i = 0
while True:
    database = os.getenv(f"aws_db_instance_Target_Name_{i}")
    if database is not None:
        # Inicie um segmento X-Ray para a conexão RDS
        if XRayEnabled:
            xray_recorder.begin_segment(SegmentName)
        EndPoint = os.getenv(f"aws_db_instance_Target_Endpoint_{i}")
        Host = EndPoint.split(":")[0]
        FoundSecret = False
        if len(SecretsCredentials) > 0:
            for j in range(len(SecretsCredentials)):
                if database in SecretsCredentials[j][0]:
                    username = SecretsCredentials[j][1]
                    password = SecretsCredentials[j][2]
                    FoundSecret = True
                    break
            if not FoundSecret:
                username = SecretsCredentials[0][1]
                password = SecretsCredentials[0][2]
        else:
            username = "TypeNewUserName"
            password = "TypeNewPassword"
        # Estabeleça a conexão e crie a tabela
        connection = create_connection(Host, username, password, database)
        if connection is not None:
            RDSConnections.append([connection, database])
            DataBaseList.append(database)
            create_table_query = """
                CREATE TABLE IF NOT EXISTS exemplo (
                    id INT AUTO_INCREMENT, 
                    texto VARCHAR(4000) NOT NULL, 
                    PRIMARY KEY (id)
                )
            """
            execute_query(connection, create_table_query)
            LogMessage(f"Passou aqui A")
        if XRayEnabled:
            xray_recorder.end_segment()
    else:
        break
    i += 1
logger.info(f"RDS Target Total: {i} {DataBaseList}")

#*************Inicia SSM PArameter*************************
SSMParameterTargetName = []
SSMParameterTargetRegion = []
i = 0
while True:
    Name = os.getenv(f"aws_ssm_parameter_Target_Name_{str(i)}")
    Region = os.getenv(f"aws_ssm_parameter_Target_Region_{str(i)}")
    if Name is not None and Region is not None:
        SSMParameterTargetName.append(Name)
        SSMParameterTargetRegion.append(Region)
    else:
        SSMParameterMaxNumber = i
        break
    i += 1
logger.info(f"SSM Parameter Target Total: {i} {SSMParameterTargetName}")



send_to_all_outputs_semaphore = Semaphore(1)
def send_to_all_outputs(message_body, URLPath="", Method="GET", EventSource = ""):
    LogMessage(f"Event Source: {EventSource}")
    Agora = datetime.datetime.now()
    NewMessage = f"Instance: {InstanceName}. Source: {Method}. Date/Time: {str(Agora)}. <- {message_body}"
    LogMessage(f"Message to be sent: {NewMessage}")
    with send_to_all_outputs_semaphore:
        execute_with_xray('send_to_all_outputs', _send_to_all_outputs_helper, NewMessage, URLPath, Method, Agora)

def _send_to_all_outputs_helper(message_body, URLPath, Method, Agora):
    for sqs_client, queue_url, Name in SQSTargetClients:
        execute_with_xray(Name, sqs_client.send_message, QueueUrl=queue_url, MessageBody=message_body)
        LogMessage(f"Send message to SQS: {Name}")
        
    for sns_client, topic_arn, Name in SNSTargetClients:
        execute_with_xray(Name, sns_client.publish, TopicArn=topic_arn, Message=message_body)
        LogMessage(f"Send message to SNS: {Name}")
    
    for dynamodb, Table, TableName in DynamoDBTargetList:
        response = execute_with_xray(TableName, Table.get_item, Key={'ID': "1"})
        if 'Item' in response:
            item = response['Item']
            cont = item['Cont'] + 1
            execute_with_xray(TableName, Table.update_item, Key={'ID': "1"}, UpdateExpression='SET Cont = :val1', ExpressionAttributeValues={':val1': cont})
            ID = InstanceName + ":" + str(Agora)
            execute_with_xray(TableName, Table.put_item, Item={'ID': ID, "Message": message_body})
            LogMessage(f"Put Item: {TableName}")
        else:
            LogMessage(f"Sem Item {TableName}")
    
    for s3_client, bucket_name in S3TargetList:
        folder_name = InstanceName + "/"
        file_name = InstanceName + ":" + str(Agora) + ".txt"
        file_path = folder_name + file_name
        execute_with_xray(bucket_name, s3_client.put_object, Bucket=bucket_name, Key=file_path, Body=message_body)
        LogMessage(f"Put Object: {bucket_name}")

    for EFSName, mount_path in EFSTargetList:
        if not os.path.exists(mount_path):
            os.makedirs(mount_path)
        file_name = f"{EFSName}-{Agora.strftime('%Y%m%d%H%M%S')}.txt"
        file_path = os.path.join(mount_path, file_name)
        with open(file_path, 'w') as file:
            file.write(message_body)
        LogMessage(f"Save Message EFS: {EFSName}: {mount_path} : {file_name}")

    for ALBName, URL in ALBTargetURLs:
        URL = "http://" + URL + "/" + URLPath
        send_request(ALBName, URL, Method, message_body=message_body)
        LogMessage(f"Call ALB : {ALBName}: {URL}")
    
    for ContainerName,RegionName in ContainerTargetList:
        def discover_service_instances(service_name, namespace_name):
            client = boto3.client('servicediscovery', region_name=RegionName)
            response = client.discover_instances(NamespaceName=namespace_name, ServiceName=service_name)
            return response
        response = execute_with_xray("DiscoverInstances", discover_service_instances, ContainerName, ClaudMapNamespaceName)
        if response['Instances'] and len(response['Instances']) > 0:
            instance = response['Instances'][0]
            Host = instance['Attributes']['AWS_INSTANCE_IPV4']
            Port = instance['Attributes']['AWS_INSTANCE_PORT']
            if Host and Port:
                URL = f"http://{Host}:{Port}/{ContainerName}"
                LogMessage(f"Send message to container with URL: {URL}")
                send_request(ContainerName, URL, "POST", message_body=message_body)
        

    for lambda_client, function_name in LambdaTargetList:
        payload = json.dumps({'message': message_body, "source" : "aws:ec2"})
        execute_with_xray(function_name, lambda_client.invoke, FunctionName=function_name, InvocationType='Event', Payload=payload)
        LogMessage(f"Invoke lambda: {function_name}")

    for connection, db_name in RDSConnections:
        # Supondo que a tabela e a coluna que você deseja inserir são 'exemplo' e 'texto'
        insert_query = "INSERT INTO exemplo (texto) VALUES (%s)"
        try:
            Data = json.dumps(message_body)
            execute_query(connection, insert_query, (Data,))
            LogMessage(f"Item inserido na tabela 'exemplo' do banco de dados '{db_name} com msg {message_body}'")
        except Error as e:
            LogMessage(f"Erro ao inserir item no banco de dados '{db_name}': {e}")

    for Name, region in zip(SSMParameterTargetName, SSMParameterTargetRegion):
        ssm_client = boto3.client('ssm', region_name=region)
        try:
            response = execute_with_xray(Name, ssm_client.get_parameter, Name=Name, WithDecryption=True)
            current_value = response['Parameter']['Value']
            new_value = '0'
            int_value = int(current_value)
            new_value = str(int_value + 1)
            execute_with_xray(Name, ssm_client.put_parameter, Name=Name, Value=new_value, Type='String',Overwrite=True)
            LogMessage(f"Parameter {Name} updated with {new_value}'")
        except Exception as e:
            LogMessage(f"Error processing the parameter {Name} in the region {region}: {e}")


    generate_primes(PrimesCount)


#Retorna a rota "/health" para o health check do target group
@app.get("/health")
async def health_check():
    LogMessage("Health Check")
    return {"status": "healthy"}

@app.api_route("/{full_path:path}", methods=["GET"])
async def catch_all_get(full_path: str, request: Request):
    Agora = datetime.datetime.now()
    xray_trace_id = request.headers.get('X-Amzn-Trace-Id')
    if XRayEnabled:
        segment = xray_recorder.begin_segment(SegmentName)
    try:
        Message = f"Source: HTTP GET @{Agora}"
        LogMessage(Message)
        EventSource = "HTTP GET"
        send_to_all_outputs(Message, full_path, "GET", EventSource)
    finally:
        if XRayEnabled:
            xray_recorder.end_segment()
    GetMessage = f"GET received. Instance: {InstanceName} path: /{full_path}"
    return {"message": GetMessage}

@app.api_route("/{full_path:path}", methods=["POST"])
async def catch_all_post(full_path: str, request: Request):
    Agora = datetime.datetime.now()
    try:
        body = await request.json()
        message_body = str(body)
        if XRayEnabled:
            segment = xray_recorder.begin_segment(SegmentName)
        LogMessage(message_body)
        EventSource = "HTTP Post"
        send_to_all_outputs(message_body, full_path, "POST", EventSource)
        if XRayEnabled:
            xray_recorder.end_segment()
    except Exception as e:
        LogMessage(f"Erro ao processar requisição POST: {e}")
        return {"status": "Error", "message": str(e)}, 500
    PostMessage = f"POST received. Instance: {InstanceName} path: /{full_path}"
    return {"status": PostMessage}

# Evento de inicialização da aplicação para iniciar o processamento das mensagens SQS
@app.on_event("startup")
async def startup_event():
    asyncio.create_task(process_sqs_messages())

# Tarefa assíncrona para processar mensagens SQS
# Variável global e um lock para segurança em ambientes multithread
Count = 0
count_lock = Lock()
async def process_sqs_messages():
    if len(SQSSourceList)>0:
        global Count
        with count_lock:  # Garante que apenas uma thread modifique Count por vez
            Count += 1
            LogMessage(f"LoopMain {Count} {InstanceName}")
        with ThreadPoolExecutor(max_workers=len(SQSSourceList)) as executor:
            loop = asyncio.get_event_loop()
            tasks = []
            for sqs_client, queue_url, SQSNAme in SQSSourceList:
                task = loop.run_in_executor(executor, process_messages_from_queue, sqs_client, queue_url, SQSNAme)
                tasks.append(task)
            await asyncio.gather(*tasks)


def process_messages_from_queue(sqs_client, queue_url,SQSName):
    while True:
        # Inicie um segmento do X-Ray no início do processamento
        if XRayEnabled:
            xray_recorder.begin_segment(SegmentName)
        try:
            def receive_messages():
                return sqs_client.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=1, WaitTimeSeconds=20)  # Long polling
            def delete_message(receipt_handle):
                return sqs_client.delete_message(QueueUrl=queue_url,ReceiptHandle=receipt_handle)
            messages = execute_with_xray(SQSName, receive_messages)
            if 'Messages' in messages:
                for message in messages['Messages']:
                    EventSource = f"SQS {SQSName}"
                    send_to_all_outputs(message['Body'],"","SQS", EventSource)
                    execute_with_xray(SQSName, delete_message, message['ReceiptHandle'])
                    LogMessage(f"Mensagem deletada da fila: {SQSName} {message['Body']}")
        except Exception as e:
            LogMessage(f"Erro ao processar mensagem da fila {queue_url}: {e}")
        finally:
            if XRayEnabled:
                xray_recorder.end_segment()




