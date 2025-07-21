# Importações
from fastapi import FastAPI, Request
import boto3
import json
import os
import logging
import datetime
import time
from dotenv import load_dotenv
import asyncio
from concurrent.futures import ThreadPoolExecutor
from threading import Semaphore, Lock
import requests
import random

# Importações condicionais
database = os.getenv(f"AWS_DB_INSTANCE_TARGET_NAME_0")
if database is not None:
    try:
        import mysql.connector
        from mysql.connector import Error
        import pymysql
    except ImportError:
        # Lidar com o caso em que os módulos não estão instalados
        pass

# Carregar as variáveis de ambiente do arquivo .env
load_dotenv()

ClaudMapNamespaceName = os.environ.get('AWS_SERVICE_DISCOVERY_SERVICE_TARGET_NAME_0', '')
ClaudMapServiceRegion = os.environ.get('AWS_SERVICE_DISCOVERY_SERVICE_TARGET_REGION_0')
if ClaudMapNamespaceName:
    try:
        import dns.resolver
    except ImportError:
        pass

# Lendo as variáveis de ambiente para configuração
Region = os.getenv("REGION")
AccountID = os.getenv("ACCOUNT")
InstanceName = os.getenv("NAME", "DefaultInstanceName")
SegmentName = InstanceName # Usado pelo X-Ray se ativado
InstanceID = os.environ.get('EC2_INSTANCE_ID', InstanceName)
PrimesFloor = int(os.environ.get('PRIMES_FLOOR', 0))
PrimesCeil = int(os.environ.get('PRIMES_CEIL', 10)) # Adicionado valor padrão para evitar erro de range

# Controle de logging baseado em variável de ambiente.
StatusLogsEnabled = os.environ.get('ENABLESTATUSLOGS', 'True').lower() == 'true'

# Configurar a sessão do Boto3 com a região correta
if Region:
    boto3.setup_default_session(region_name=Region)

# Configuração de Logging Simplificada para stdout/stderr
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# Instancia a aplicação FastAPI
app = FastAPI()

def LogMessage(Msg):
    if StatusLogsEnabled:
        logger.info(Msg)

LogMessage(f"Logging configurado. Instância '{InstanceName}' na região '{Region}' iniciando.")

XRay = os.getenv('XRAY_ENABLED', "False")
if XRay == "True":
    XRayEnabled = True
    from aws_xray_sdk.core import xray_recorder, patch_all
    patch_all()
    LogMessage(f"Enable XRay")
else:
    XRayEnabled = False

# --- Funções Auxiliares ---

def execute_with_xray(segment_name, function, *args, **kwargs):
    if XRayEnabled:
        with xray_recorder.in_subsegment(segment_name): return function(*args, **kwargs)
    else: return function(*args, **kwargs)

def generate_primes(floor, ceil):
    def is_prime(num):
        if num < 2: return False
        for i in range(2, int(num**0.5) + 1):
            if num % i == 0: return False
        return True
    # Garante que ceil seja maior ou igual a floor
    if ceil < floor: ceil = floor
    n = random.randint(floor, ceil)
    primes = []
    num = 2
    while len(primes) < n:
        if is_prime(num): primes.append(num)
        num += 1
    return f" Primes Generated: {len(primes)}"

def send_request(Name, URL, Method, message_body=None):
    try:
        headers = {'Content-Type': 'application/json'}
        def post_request(): return requests.post(URL, data=json.dumps({"MSG Data": message_body}), headers=headers)
        def get_request(): return requests.get(URL, headers=headers)
        if Method == "POST": response = execute_with_xray(Name, post_request)
        elif Method == "GET": response = execute_with_xray(Name, get_request)
        else: LogMessage("Unknown Method"); return
        if response.status_code != 200: LogMessage(f"Erro ao enviar para {Name} em {URL}: Status Code {response.status_code}")
    except requests.exceptions.RequestException as e: LogMessage(f"Exceção ao enviar para {Name} em {URL}: {e}")

# --- Descoberta de Recursos na Inicialização ---

# Identifica a URL e o cliente de cada SQS Source
SQSSourceList = []
i = 0
while True:
    # CORRIGIDO: Nomes de variáveis EXATOS do user_data
    Name = os.getenv(f"AWS_SQS_QUEUE_SOURCE_NAME_{i}")
    QueueRegion = os.getenv(f"AWS_SQS_QUEUE_SOURCE_REGION_{i}")
    URL = os.getenv(f"AWS_SQS_QUEUE_SOURCE_URL_{i}")
    if Name and QueueRegion and URL:
        sqs_client = boto3.client('sqs', region_name=QueueRegion)
        SQSSourceList.append((sqs_client, URL, Name))
    else: break
    i += 1
LogMessage(f"Found {len(SQSSourceList)} SQS source queue(s).")

# Identifica cada DynamoDB Target
DynamoDBTargetList = []
i = 0
while True:
    # CORRIGIDO: Nomes de variáveis EXATOS do user_data
    TableName = os.getenv(f"AWS_DYNAMODB_TABLE_TARGET_NAME_{i}")
    TableRegion = os.getenv(f"AWS_DYNAMODB_TABLE_TARGET_REGION_{i}")
    if TableName and TableRegion:
        dynamodb = boto3.resource('dynamodb', region_name=TableRegion)
        table_resource = dynamodb.Table(TableName)
        DynamoDBTargetList.append((dynamodb, table_resource, TableName))
    else: break
    i += 1
LogMessage(f"Found {len(DynamoDBTargetList)} DynamoDB target table(s).")

# --- Lógica Principal da Aplicação ---

send_to_all_outputs_semaphore = Semaphore(1)

def _send_to_all_outputs_helper(message_body, URLPath, Method, Agora):
    for dynamodb, Table, TableName in DynamoDBTargetList:
        try:
            ID = f"{InstanceName}:{Agora.isoformat()}"
            execute_with_xray(TableName, Table.put_item, Item={'ID': ID, "Message": message_body})
            LogMessage(f"Put Item to DynamoDB table: {TableName}")
        except Exception as e:
            LogMessage(f"Error writing to DynamoDB table {TableName}: {e}")
    # Adicione aqui a lógica para outros targets (S3, SNS, etc.)

def send_to_all_outputs(message_body, URLPath="", Method="GET", EventSource=""):
    LogMessage(f"Processing event from: {EventSource}")
    # CORRIGIDO: Chamada a generate_primes com variáveis existentes
    PrimesResult = generate_primes(PrimesFloor, PrimesCeil)
    full_message_body = message_body + PrimesResult
    
    Agora = datetime.datetime.now()
    NewMessage = f"Instance: {InstanceName}. Source: {Method}. Time: {Agora.isoformat()}. <- {full_message_body}"
    LogMessage(f"Message to be sent: {NewMessage}")
    with send_to_all_outputs_semaphore:
        execute_with_xray('send_to_all_outputs', _send_to_all_outputs_helper, NewMessage, URLPath, Method, Agora)


# --- Endpoints FastAPI ---

@app.get("/health", tags=["Monitoring"])
async def health_check():
    return {"status": "healthy"}

@app.api_route("/{full_path:path}", methods=["GET", "POST"], tags=["Ingestion"])
async def catch_all_requests(full_path: str, request: Request):
    message_content = f"Received raw {request.method} request."
    if request.method == "POST":
        try:
            body = await request.json()
            message_content = str(body)
        except Exception:
            try:
                # Tenta ler como texto se não for JSON
                body_bytes = await request.body()
                message_content = body_bytes.decode('utf-8', errors='ignore')
            except Exception as e:
                message_content = f"Could not parse POST body: {e}"

    send_to_all_outputs(message_content, full_path, request.method, f"HTTP {request.method}")
    return {"message": f"{request.method} received successfully on path: /{full_path}"}


# --- Processamento SQS em Background ---

def process_messages_from_queue(sqs_client, queue_url, SQSName):
    LogMessage(f"Worker started for SQS queue: {SQSName}")
    while True:
        try:
            response = sqs_client.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=1, WaitTimeSeconds=20)
            if 'Messages' in response:
                for message in response['Messages']:
                    LogMessage(f"Received message from SQS queue: {SQSName}")
                    send_to_all_outputs(message['Body'], "", "SQS", f"SQS {SQSName}")
                    sqs_client.delete_message(QueueUrl=queue_url, ReceiptHandle=message['ReceiptHandle'])
                    LogMessage(f"Message deleted from queue: {SQSName}")
        except Exception as e:
            LogMessage(f"Error processing SQS queue {queue_url}: {e}")
            time.sleep(10) # Pausa para evitar spam de logs em caso de erro persistente

async def process_sqs_messages():
    LogMessage("Starting SQS message processing pool...")
    with ThreadPoolExecutor(max_workers=len(SQSSourceList)) as executor:
        loop = asyncio.get_event_loop()
        tasks = [
            loop.run_in_executor(executor, process_messages_from_queue, sqs_client, queue_url, SQSName)
            for sqs_client, queue_url, SQSName in SQSSourceList
        ]
        await asyncio.gather(*tasks)

@app.on_event("startup")
async def startup_event():
    if SQSSourceList:
        asyncio.create_task(process_sqs_messages())
    else:
        LogMessage("No SQS source queues configured. SQS processing will not start.")
