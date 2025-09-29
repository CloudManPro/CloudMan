# Importações
from fastapi import FastAPI, Request
import boto3
from botocore.exceptions import ClientError
import json
import os
import logging
import datetime
from dotenv import load_dotenv
import asyncio
from contextlib import asynccontextmanager
from concurrent.futures import ThreadPoolExecutor
from threading import Semaphore
from threading import Lock
import requests
import random
import uuid
import time # Importar time para a lógica de espera

# (O restante das importações e configurações iniciais permanecem as mesmas)
# ...
try:
    import watchtower
except ImportError:
    watchtower = None

database = os.getenv(f"AWS_DB_INSTANCE_TARGET_NAME_0")
if database is not None:
    try:
        import mysql.connector
        from mysql.connector import Error
        import pymysql
    except ImportError:
        mysql = None
load_dotenv()

ClaudMapNamespaceName = os.environ.get(
    'AWS_SERVICE_DISCOVERY_NAMESPACE_NAME_0', '')
ClaudMapServiceRegion = os.environ.get(
    'AWS_SERVICE_DISCOVERY_NAMESPACE_REGION_0')
if ClaudMapNamespaceName != "":
    try:
        import dns.resolver
    except ImportError:
        dns = None

Region = os.getenv("REGION")
AccountID = os.getenv("ACCOUNT")
InstanceName = os.getenv("NAME", "DefaultInstanceName")
SegmentName = InstanceName
EC2_INSTANCE_ID = os.environ.get('EC2_INSTANCE_ID')
EC2_INSTANCE_IPV4 = os.environ.get('EC2_INSTANCE_IPV4')
PrimesFloor = int(os.environ.get('PRIMES_FLOOR', 0))
PrimesCeil = int(os.environ.get('PRIMES_CEIL', 10))
VarLogs = os.environ.get('ENABLESTATUSLOGS', "True")
CloudWatchName = os.environ.get('AWS_CLOUDWATCH_LOG_GROUP_TARGET_NAME_0', "")
StatusLogsEnabled = VarLogs == "True" and CloudWatchName != ""

# --- NOVA ALTERAÇÃO: Leitura da variável de ambiente para o health check ---
# Lê a variável de ambiente. O .lower() torna a verificação insensível a maiúsculas/minúsculas.
# Se a variável não estiver definida, os.getenv retorna 'false', resultando em False.
enable_custom_health_check = os.getenv('CLOUDMAP_CUSTOM_HEALTHCHECK', 'false').lower() == 'true'


if Region:
    boto3.setup_default_session(region_name=Region)

APP_LOG_PATH = "/var/log/ec2hub/EC2Hub.log"

# Configura o logging para escrever no arquivo
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    filename=APP_LOG_PATH,   # <-- Direciona a saída para o arquivo
    filemode='a',            # <-- 'a' para adicionar (append), não sobrescrever
    force=True               # <-- Garante que esta configuração se sobreponha a qualquer outra (ex: do uvicorn)
)

logger = logging.getLogger(__name__)

if watchtower and CloudWatchName and StatusLogsEnabled:
    try:
        cw_handler = watchtower.CloudWatchLogHandler(
            log_group=CloudWatchName,
            stream_name=SegmentName
        )
        logger.addHandler(cw_handler)
        logger.info(
            f"EC2 Host: {InstanceName} - Logging para CloudWatch ativado no grupo '{CloudWatchName}'.")
    except Exception as e:
        logger.error(
            f"Falha ao configurar o handler do CloudWatch (Watchtower): {e}")

def LogMessage(Msg):
    if StatusLogsEnabled:
        logger.info(Msg)

LogMessage(f"Módulo Python carregado. Inicio {PrimesFloor}, {PrimesCeil}")
# Loga o status do health check customizado
LogMessage(f"Cloud Map Custom Health Check ativado: {enable_custom_health_check}")
XRay = os.getenv('XRAY_ENABLED', "False")
if XRay == "True":
    try:
        from aws_xray_sdk.core import xray_recorder, patch_all
        patch_all()
        XRayEnabled = True
        LogMessage(f"Enable XRay")
    except ImportError:
        XRayEnabled = False
        LogMessage("AVISO: XRay SDK não encontrado. XRay desabilitado.")
else:
    XRayEnabled = False

# ==============================================================================
# ---> INÍCIO DA SEÇÃO COM A SOLUÇÃO FINAL (LÓGICA DE REPETIÇÃO) <---
#
CLOUD_MAP_REGISTRATIONS = []
health_check_task = None


def register_instance_in_cloud_map():
    """Registra a instância nos serviços Cloud Map configurados."""
    servicediscovery_client = boto3.client('servicediscovery')
    for i in range(10):
        service_arn_var = f"AWS_SERVICE_DISCOVERY_SERVICE_TARGET_ARN_REG_{i}"
        service_arn = os.getenv(service_arn_var)
        if not service_arn:
            continue
        try:
            service_id = service_arn.split('/')[-1]
            registration_id = f"{InstanceName}-{str(uuid.uuid4())}"
            
            LogMessage(f"Cloud Map [Registro]: Registrando com estado de saúde inicial HEALTHY.")

            servicediscovery_client.register_instance(
                ServiceId=service_id,
                InstanceId=registration_id,
                Attributes={
                    'AWS_INSTANCE_IPV4': EC2_INSTANCE_IPV4,
                    'AWS_INSTANCE_PORT': '80',
                    'EC2_INSTANCE_ID': EC2_INSTANCE_ID,
                    'AWS_INIT_HEALTH_STATUS': 'HEALTHY' 
                }
            )

            registration_info = {
                "service_id": service_id,
                "instance_id": registration_id
            }
            CLOUD_MAP_REGISTRATIONS.append(registration_info)
            LogMessage(f"Cloud Map [Registro]: Instância registrada com sucesso com o ID '{registration_id}'.")
        except Exception as e:
            LogMessage(f"Cloud Map [Registro]: ERRO CRÍTICO ao registrar. Erro: {e}")

def deregister_instance_from_cloud_map():
    """Desregistra a instância dos serviços Cloud Map durante o shutdown."""
    if not CLOUD_MAP_REGISTRATIONS:
        return
    LogMessage("Cloud Map [Desregistro]: Iniciando desregistro...")
    servicediscovery_client = boto3.client('servicediscovery')
    for reg in CLOUD_MAP_REGISTRATIONS:
        try:
            servicediscovery_client.deregister_instance(
                ServiceId=reg["service_id"], InstanceId=reg["instance_id"]
            )
            LogMessage(f"Cloud Map [Desregistro]: Instância '{reg['instance_id']}' desregistrada com sucesso.")
        except Exception as e:
            LogMessage(f"Cloud Map [Desregistro]: Falha ao desregistrar. Erro: {e}")


async def update_custom_health_status_task():
    """Tarefa em background que envia atualizações de status 'HEALTHY' com lógica de repetição."""
    LogMessage("Cloud Map [Health Check]: Iniciando tarefa de health check customizado com lógica de repetição.")
    servicediscovery_client = boto3.client('servicediscovery')
    
    # Aguarda um pouco antes da primeira tentativa para dar tempo de propagação
    await asyncio.sleep(5) 

    while True:
        try:
            for reg in CLOUD_MAP_REGISTRATIONS:
                max_retries = 5
                retry_delay = 3  # segundos

                for attempt in range(max_retries):
                    try:
                        servicediscovery_client.update_instance_custom_health_status(
                            ServiceId=reg["service_id"],
                            InstanceId=reg["instance_id"],
                            Status='HEALTHY'
                        )
                        # Se chegou aqui, a chamada foi bem-sucedida, pode sair do loop de retry
                        LogMessage(f"Cloud Map [Health Check]: Status para '{reg['instance_id']}' atualizado com sucesso.")
                        break # Sai do loop for de tentativas
                    
                    except ClientError as e:
                        if e.response['Error']['Code'] in ['ServiceNotFound', 'InstanceNotFound']:
                            LogMessage(f"Cloud Map [Health Check]: Erro de consistência ({e.response['Error']['Code']}) na tentativa {attempt + 1}/{max_retries}. Tentando novamente em {retry_delay}s...")
                            if attempt < max_retries - 1:
                                await asyncio.sleep(retry_delay)
                                retry_delay *= 2 # Aumenta o tempo de espera (exponential backoff)
                            else:
                                LogMessage(f"Cloud Map [Health Check]: ERRO FINAL. Máximo de tentativas atingido para '{reg['instance_id']}'.")
                                # Re-lança a exceção se todas as tentativas falharem
                                raise
                        else:
                            # Se for outro erro, lança imediatamente
                            raise
                
            # Após atualizar todas as instâncias, espera o intervalo normal de 20s
            await asyncio.sleep(20)

        except asyncio.CancelledError:
            LogMessage("Cloud Map [Health Check]: Tarefa de health check cancelada.")
            break
        except Exception as e:
            LogMessage(f"Cloud Map [Health Check]: Falha no loop principal. Erro: {e}. Tentando novamente em 20s.")
            await asyncio.sleep(20)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # --- LÓGICA DE STARTUP ---
    global health_check_task
    LogMessage("Iniciando ciclo de vida da aplicação (lifespan)...")
    if SQSSourceList:
        asyncio.create_task(process_sqs_messages())
    if EC2_INSTANCE_ID and EC2_INSTANCE_IPV4:
        register_instance_in_cloud_map()
        # --- ALTERAÇÃO: Verificação da variável para iniciar o health check ---
        if CLOUD_MAP_REGISTRATIONS and enable_custom_health_check:
            LogMessage("Cloud Map: Iniciando a tarefa de health check customizado.")
            health_check_task = asyncio.create_task(
                update_custom_health_status_task())
        elif not enable_custom_health_check:
            LogMessage("Cloud Map: Health check customizado desativado pela variável de ambiente.")
    else:
        LogMessage("Ambiente não-EC2 ou metadados faltando. Pulando registro no Cloud Map.")

    yield

    # --- LÓGICA DE SHUTDOWN ---
    LogMessage("Iniciando encerramento da aplicação (lifespan)...")
    if health_check_task:
        health_check_task.cancel()
        await asyncio.sleep(1)
    deregister_instance_from_cloud_map()
    LogMessage("Encerramento da aplicação concluído.")
#
# ---> FIM DA SEÇÃO COM A SOLUÇÃO FINAL <---
# ==============================================================================


# Instancia a aplicação FastAPI usando o novo lifespan
app = FastAPI(lifespan=lifespan)

# (O restante do seu código permanece exatamente o mesmo)
def list_services_in_namespace(client, namespace_id):
    services = []
    paginator = client.get_paginator('list_services')
    for page in paginator.paginate(Filters=[{'Name': 'NAMESPACE_ID', 'Values': [namespace_id]}]):
        services.extend(page['Services'])
    return services


def find_namespace_id_by_name(client, namespace_name):
    paginator = client.get_paginator('list_namespaces')
    for page in paginator.paginate():
        for ns in page['Namespaces']:
            if ns['Name'] == namespace_name:
                return ns['Id']
    return None


def list_instances_of_service(client, service_id):
    instances = []
    paginator = client.get_paginator('list_instances')
    for page in paginator.paginate(ServiceId=service_id):
        instances.extend(page['Instances'])
    return instances


if ClaudMapNamespaceName != "" and dns:
    try:
        ClientService = boto3.client(
            'servicediscovery', region_name=ClaudMapServiceRegion)
        if XRayEnabled:
            xray_recorder.begin_segment(SegmentName)
        ClaudMapNamespaceID = find_namespace_id_by_name(
            ClientService, ClaudMapNamespaceName)
        if ClaudMapNamespaceID:
            LogMessage(
                f"Cloud Map [Descoberta]: Namespace ID encontrado: {ClaudMapNamespaceID}")
            services = list_services_in_namespace(
                ClientService, ClaudMapNamespaceID)
            for service in services:
                service_id = service['Id']
                service_name = service['Name']
                LogMessage(
                    f"Cloud Map [Descoberta]: Serviço: {service_name} (ID: {service_id})")
                instances = list_instances_of_service(
                    ClientService, service_id)
                for instance in instances:
                    LogMessage(f"  -> Instância: {instance['Id']}")
                    for key, value in instance['Attributes'].items():
                        LogMessage(f"     {key}: {value}")
        else:
            LogMessage("Cloud Map [Descoberta]: Namespace não encontrado.")
        if XRayEnabled:
            xray_recorder.end_segment()
    except Exception as e:
        LogMessage(
            f"Cloud Map [Descoberta]: Erro durante a descoberta inicial: {e}")


def generate_primes(floor, ceil):
    def is_prime(num):
        if num < 2:
            return False
        for i in range(2, int(num ** 0.5) + 1):
            if num % i == 0:
                return False
        return True
    if ceil < floor:
        ceil = floor
    n = random.randint(floor, ceil)
    primes = []
    num = 2
    while len(primes) < n:
        if is_prime(num):
            primes.append(num)
        num += 1
    return f" Primes Generated: {len(primes)}"


def execute_with_xray(segment_name, function, *args, **kwargs):
    if XRayEnabled:
        with xray_recorder.in_subsegment(segment_name):
            return function(*args, **kwargs)
    return function(*args, **kwargs)


def send_request(Name, URL, Method, message_body=None):
    try:
        headers = {'Content-Type': 'application/json'}
        def post_request(): return requests.post(
            URL, data=json.dumps({"MSG Data": message_body}), headers=headers)

        def get_request(): return requests.get(URL, headers=headers)
        if Method == "POST":
            response = execute_with_xray(Name, post_request)
        elif Method == "GET":
            response = execute_with_xray(Name, get_request)
        else:
            LogMessage("Unknown Method")
            return
        if response.status_code != 200:
            LogMessage(
                f"Erro ao enviar para {Name} em {URL}: Status Code {response.status_code}")
    except requests.exceptions.RequestException as e:
        LogMessage(f"Exceção ao enviar para {Name} em {URL}: {e}")


def create_connection(host_name, user_name, user_password, db_name):
    if not mysql:
        LogMessage(
            "AVISO: Módulo MySQL não está instalado. Pulando conexão com RDS.")
        return None
    connection = None
    try:
        connection = mysql.connector.connect(
            host=host_name, user=user_name, passwd=user_password, database=db_name)
        LogMessage(f"Conexão ao MySQL DB '{db_name}' bem-sucedida")
    except Error as e:
        LogMessage(f"O erro '{e}' ocorreu ao conectar no MySQL '{db_name}'")
    return connection


def execute_query(connection, query, values=None):
    if not connection:
        return
    cursor = connection.cursor()
    try:
        if values:
            cursor.execute(query, values)
        else:
            cursor.execute(query)
        connection.commit()
    except Error as e:
        LogMessage(f"O erro '{e}' ocorreu ao executar query")


def init_table(table_resource, TableName):
    if XRayEnabled:
        xray_recorder.begin_segment(SegmentName)
    try:
        response = execute_with_xray(
            TableName, table_resource.get_item, Key={'ID': "1"})
        if 'Item' not in response:
            ItemData = f"Criado por {InstanceName}"
            execute_with_xray(TableName, table_resource.put_item, Item={
                              'ID': "1", "InstanceName": ItemData, 'Cont': 0})
    except Exception as e:
        LogMessage(f"Erro ao iniciar a tabela {TableName}: {e}")
    finally:
        if XRayEnabled:
            xray_recorder.end_segment()


SQSTargetClients, SQSNameList = [], []
i = 0
while True:
    Name, R, URL = (os.getenv(f"AWS_SQS_QUEUE_TARGET_NAME_{i}"), os.getenv(
        f"AWS_SQS_QUEUE_TARGET_REGION_{i}"), os.getenv(f"AWS_SQS_QUEUE_TARGET_URL_{str(i)}"))
    if Name:
        SQSTargetClients.append(
            (boto3.client('sqs', region_name=R), URL, Name))
        SQSNameList.append(Name)
    else:
        break
    i += 1
LogMessage(f"SQS Target Total: {i} {SQSNameList}")

SNSTargetClients, SNSNameList = [], []
i = 0
while True:
    Name, R, ARN = (os.getenv(f"AWS_SNS_TOPIC_TARGET_NAME_{i}"), os.getenv(
        f"AWS_SNS_TOPIC_TARGET_REGION_{i}"), os.getenv(f"AWS_SNS_TOPIC_TARGET_ARN_{str(i)}"))
    if Name:
        SNSTargetClients.append(
            (boto3.client('sns', region_name=R), ARN, Name))
        SNSNameList.append(Name)
    else:
        break
    i += 1
LogMessage(f"SNS Target Total: {i} {SNSNameList}")

DynamoDBTargetList, DynamoNameList = [], []
i = 0
while True:
    TableName, R = (os.getenv(f"AWS_DYNAMODB_TABLE_TARGET_NAME_{i}"), os.getenv(
        f"AWS_DYNAMODB_TABLE_TARGET_REGION_{i}"))
    if TableName:
        dynamodb = boto3.resource('dynamodb', region_name=R)
        table_resource = dynamodb.Table(TableName)
        DynamoDBTargetList.append((dynamodb, table_resource, TableName))
        DynamoNameList.append(TableName)
        init_table(table_resource, TableName)
    else:
        break
    i += 1
LogMessage(f"DynamoDB Target Total: {i} {DynamoNameList}")

S3TargetList, S3NameList = [], []
i = 0
while True:
    Name, R = (os.getenv(f"AWS_S3_BUCKET_TARGET_NAME_{i}"), os.getenv(
        f"AWS_S3_BUCKET_TARGET_REGION_{i}"))
    if Name:
        S3TargetList.append((boto3.client('s3', region_name=R), Name))
        S3NameList.append(Name)
    else:
        break
    i += 1
LogMessage(f"S3 Target Total: {i} {S3NameList}")

EFSTargetList, EFSNameList = [], []
i = 0
while True:
    Name, Path = (os.getenv(f"AWS_EFS_FILE_SYSTEM_TARGET_NAME_{i}"), os.getenv(
        f"AWS_EFS_ACCESS_POINT_TARGET_PATH_{i}"))
    if Name:
        EFSTargetList.append([Name, Path])
        EFSNameList.append(Name)
    else:
        break
    i += 1
LogMessage(f"EFS Target Total: {i} {EFSNameList}")

LambdaTargetList, LambdaNameList = [], []
i = 0
while True:
    FunctionName, R = (os.getenv(f"AWS_LAMBDA_FUNCTION_TARGET_NAME_{i}"), os.getenv(
        f"AWS_LAMBDA_FUNCTION_TARGET_REGION_{i}"))
    if FunctionName:
        LambdaTargetList.append(
            (boto3.client('lambda', region_name=R), FunctionName))
        LambdaNameList.append(FunctionName)
    else:
        break
    i += 1
LogMessage(f"Lambda Target Total: {i} {LambdaNameList}")

ALBTargetURLs, ALBNameList = [], []
i = 0
while True:
    URL, ALBName = (
        os.getenv(f"AWS_LB_DNS_NAME_{i}"), os.getenv(f"AWS_LB_NAME_{i}"))
    if URL:
        ALBTargetURLs.append([ALBName, URL])
        ALBNameList.append(ALBName)
    else:
        break
    i += 1
LogMessage(f"ALB Target Total: {i} {ALBNameList}")

ContainerTargetList, ContainerNameList = [], []
if ClaudMapNamespaceName:
    i = 0
    while True:
        ContainerName, R = (os.getenv(f"CONTAINER_TARGET_NAME_{i}"), os.getenv(
            f"CONTAINER_TARGET_REGION_{i}"))
        if ContainerName:
            ContainerTargetList.append([ContainerName, R])
            ContainerNameList.append(ContainerName)
        else:
            break
        i += 1
    LogMessage(f"Containers Target Total: {i} {ContainerNameList}")

SQSSourceList, SQSNameList_Source = [], []
i = 0
while True:
    Name, R, URL = (os.getenv(f"AWS_SQS_QUEUE_SOURCE_NAME_{i}"), os.getenv(
        f"AWS_SQS_QUEUE_SOURCE_REGION_{i}"), os.getenv(f"AWS_SQS_QUEUE_SOURCE_URL_{str(i)}"))
    if Name:
        SQSSourceList.append((boto3.client('sqs', region_name=R), URL, Name))
        SQSNameList_Source.append(Name)
    else:
        break
    i += 1
LogMessage(f"SQS Queue Source Total: {i} {SQSNameList_Source}")

SecretsCredentials, SecretNameList = [], []
i = 0
while True:
    SecretName, SecretARN = (os.getenv(f"AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_{i}"), os.getenv(
        f"AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_{i}"))
    if SecretName:
        try:
            client = boto3.client('secretsmanager', region_name=Region)
            response = client.get_secret_value(SecretId=SecretARN)
            secret = json.loads(response['SecretString'])
            SecretsCredentials.append(
                [SecretName, secret['username'], secret['password']])
            SecretNameList.append(SecretName)
        except Exception as e:
            LogMessage(f"Erro ao obter o segredo '{SecretName}': {e}")
    else:
        break
    i += 1
LogMessage(f"Secrets Target Total: {i} {SecretNameList}")

RDSConnections, DataBaseList = [], []
i = 0
while True:
    database_name = os.getenv(f"AWS_DB_INSTANCE_TARGET_NAME_{i}")
    if database_name:
        if XRayEnabled:
            xray_recorder.begin_segment(SegmentName)
        EndPoint = os.getenv(f"AWS_DB_INSTANCE_TARGET_ENDPOINT_{i}")
        Host = EndPoint.split(":")[0]
        username, password = "default_user", "default_pass"
        for secret_info in SecretsCredentials:
            if database_name in secret_info[0]:
                username, password = secret_info[1], secret_info[2]
                break
        connection = create_connection(Host, username, password, database_name)
        if connection:
            RDSConnections.append([connection, database_name])
            DataBaseList.append(database_name)
            create_table_query = "CREATE TABLE IF NOT EXISTS exemplo (id INT AUTO_INCREMENT, texto VARCHAR(4000) NOT NULL, PRIMARY KEY (id))"
            execute_query(connection, create_table_query)
        if XRayEnabled:
            xray_recorder.end_segment()
    else:
        break
    i += 1
LogMessage(f"RDS Target Total: {i} {DataBaseList}")

SSMParameterTargetName, SSMParameterTargetRegion = [], []
i = 0
while True:
    Name, R = (os.getenv(f"AWS_SSM_PARAMETER_TARGET_NAME_{str(i)}"), os.getenv(
        f"AWS_SSM_PARAMETER_TARGET_REGION_{str(i)}"))
    if Name and R:
        SSMParameterTargetName.append(Name)
        SSMParameterTargetRegion.append(R)
    else:
        break
    i += 1
LogMessage(f"SSM Parameter Target Total: {i} {SSMParameterTargetName}")

send_to_all_outputs_semaphore = Semaphore(1)


def _send_to_all_outputs_helper(message_body, URLPath, Method, Agora):
    for sqs_client, queue_url, Name in SQSTargetClients:
        execute_with_xray(Name, sqs_client.send_message,
                          QueueUrl=queue_url, MessageBody=message_body)
        LogMessage(f"Send message to SQS: {Name}")
    for sns_client, topic_arn, Name in SNSTargetClients:
        execute_with_xray(Name, sns_client.publish,
                          TopicArn=topic_arn, Message=message_body)
        LogMessage(f"Send message to SNS: {Name}")
    for dynamodb, Table, TableName in DynamoDBTargetList:
        response = execute_with_xray(
            TableName, Table.get_item, Key={'ID': "1"})
        if 'Item' in response:
            item = response['Item']
            cont = item.get('Cont', 0) + 1
            execute_with_xray(TableName, Table.update_item, Key={
                              'ID': "1"}, UpdateExpression='SET Cont = :val1', ExpressionAttributeValues={':val1': cont})
            ID = f"{InstanceName}:{Agora.isoformat()}"
            execute_with_xray(TableName, Table.put_item, Item={
                              'ID': ID, "Message": message_body})
            LogMessage(f"Put Item: {TableName}")
    for s3_client, bucket_name in S3TargetList:
        file_path = f"{InstanceName}/{InstanceName}:{Agora.isoformat()}.txt"
        execute_with_xray(bucket_name, s3_client.put_object,
                          Bucket=bucket_name, Key=file_path, Body=message_body)
        LogMessage(f"Put Object: {bucket_name}")
    for EFSName, mount_path in EFSTargetList:
        try:
            if not os.path.exists(mount_path):
                os.makedirs(mount_path)
            file_path = os.path.join(
                mount_path, f"{EFSName}-{Agora.strftime('%Y%m%d%H%M%S')}.txt")
            with open(file_path, 'w') as file:
                file.write(message_body)
            LogMessage(f"Save Message EFS: {EFSName}: {mount_path}")
        except Exception as e:
            LogMessage(f"Erro ao escrever no EFS {EFSName}: {e}")
    for ALBName, URL in ALBTargetURLs:
        send_request(ALBName, f"http://{URL}/{URLPath}",
                     Method, message_body=message_body)
        LogMessage(f"Call ALB : {ALBName}")
    for ContainerName, RegionName in ContainerTargetList:
        def discover_service_instances(service_name, namespace_name): return boto3.client(
            'servicediscovery', region_name=RegionName).discover_instances(NamespaceName=namespace_name, ServiceName=service_name)
        response = execute_with_xray(
            "DiscoverInstances", discover_service_instances, ContainerName, ClaudMapNamespaceName)
        if response.get('Instances'):
            instance = random.choice(response['Instances'])
            Host = instance['Attributes'].get('AWS_INSTANCE_IPV4')
            Port = instance['Attributes'].get('AWS_INSTANCE_PORT')
            if Host and Port:
                URL = f"http://{Host}:{Port}/{ContainerName}"
                send_request(ContainerName, URL, "POST",
                             message_body=message_body)
    for lambda_client, function_name in LambdaTargetList:
        payload = json.dumps({'message': message_body, "source": "AWS:EC2"})
        execute_with_xray(function_name, lambda_client.invoke,
                          FunctionName=function_name, InvocationType='Event', Payload=payload)
        LogMessage(f"Invoke lambda: {function_name}")
    for connection, db_name in RDSConnections:
        insert_query = "INSERT INTO exemplo (texto) VALUES (%s)"
        execute_query(connection, insert_query, (json.dumps(message_body),))
        LogMessage(f"Item inserido no banco de dados '{db_name}'")
    for Name, region in zip(SSMParameterTargetName, SSMParameterTargetRegion):
        ssm_client = boto3.client('ssm', region_name=region)
        try:
            response = execute_with_xray(
                Name, ssm_client.get_parameter, Name=Name, WithDecryption=True)
            new_value = str(int(response['Parameter']['Value']) + 1)
            execute_with_xray(Name, ssm_client.put_parameter, Name=Name,
                              Value=new_value, Type='String', Overwrite=True)
            LogMessage(f"Parameter {Name} updated with {new_value}")
        except Exception as e:
            LogMessage(f"Error processing SSM parameter {Name}: {e}")


def send_to_all_outputs(message_body, URLPath="", Method="GET", EventSource=""):
    Primes = generate_primes(PrimesFloor, PrimesCeil)
    full_message_body = message_body + " " + Primes
    LogMessage(f"Event Source: {EventSource}")
    Agora = datetime.datetime.now()
    NewMessage = f"Instance: {InstanceName}. Source: {Method}. Date/Time: {str(Agora)}. <- {full_message_body}"
    LogMessage(f"Message to be sent: {NewMessage}")
    with send_to_all_outputs_semaphore:
        _send_to_all_outputs_helper(NewMessage, URLPath, Method, Agora)


@app.get("/health")
async def health_check():
    return {"status": "healthy"}


@app.api_route("/{full_path:path}", methods=["GET", "POST"])
async def catch_all_requests(full_path: str, request: Request):
    Agora = datetime.datetime.now()
    message_content = f"Received raw {request.method} request at {Agora}."
    if XRayEnabled:
        xray_recorder.begin_segment(SegmentName)
    try:
        if request.method == "POST":
            try:
                message_content = str(await request.json())
            except Exception:
                message_content = (await request.body()).decode('utf-8', errors='ignore')
        send_to_all_outputs(message_content, full_path,
                            request.method, f"HTTP {request.method}")
        return {"message": f"{request.method} received. Instance: {InstanceName} path: /{full_path}"}
    except Exception as e:
        LogMessage(f"Erro ao processar requisição {request.method}: {e}")
        return {"status": "Error", "message": str(e)}, 500
    finally:
        if XRayEnabled:
            xray_recorder.end_segment()


Count = 0
count_lock = Lock()


async def process_sqs_messages():
    global Count
    with count_lock:
        Count += 1
        LogMessage(f"LoopMain {Count} {InstanceName}")
    with ThreadPoolExecutor(max_workers=len(SQSSourceList)) as executor:
        loop = asyncio.get_event_loop()
        tasks = [loop.run_in_executor(executor, process_messages_from_queue, sqs_client,
                                      queue_url, SQSName) for sqs_client, queue_url, SQSName in SQSSourceList]
        await asyncio.gather(*tasks)


def process_messages_from_queue(sqs_client, queue_url, SQSName):
    while True:
        if XRayEnabled:
            xray_recorder.begin_segment(SegmentName)
        try:
            def receive_messages(): return sqs_client.receive_message(
                QueueUrl=queue_url, MaxNumberOfMessages=1, WaitTimeSeconds=20)

            def delete_message(receipt_handle): return sqs_client.delete_message(
                QueueUrl=queue_url, ReceiptHandle=receipt_handle)
            messages = execute_with_xray(SQSName, receive_messages)
            if 'Messages' in messages:
                for message in messages['Messages']:
                    send_to_all_outputs(
                        message['Body'], "", "SQS", f"SQS {SQSName}")
                    execute_with_xray(SQSName, delete_message,
                                      message['ReceiptHandle'])
                    LogMessage(f"Mensagem deletada da fila: {SQSName}")
        except Exception as e:
            LogMessage(f"Erro ao processar mensagem da fila {queue_url}: {e}")
        finally:
            if XRayEnabled:
                xray_recorder.end_segment()
