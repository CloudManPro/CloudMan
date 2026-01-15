import traceback
import boto3
import os
import json
import datetime
import http.client
from urllib.parse import unquote

# Configuração do X-Ray
try:
    from aws_xray_sdk.core import xray_recorder
    from aws_xray_sdk.core import patch_all
    patch_all()
    xray_enabled = True
except:
    xray_enabled = False
    print("XRay SDK not found!")

XRay = os.getenv('XRAY_ENABLED', "False")
if XRay == "False":
    xray_enabled = False

# Configuração do PyMySQL
try:
    import pymysql
    from pymysql import MySQLError
    MySQLEnabled = True
except:
    MySQLEnabled = False
    print("Pymysql not found!")

# *************************** Inicialização de Clientes AWS ***********************
Region = os.getenv("REGION")
AccountID = os.getenv("ACCOUNT")
sqs = boto3.client('sqs', region_name=Region)
dynamodb = boto3.resource('dynamodb', region_name=Region)
lambda_client = boto3.client('lambda', region_name=Region)
sns = boto3.client('sns', region_name=Region)
s3 = boto3.client('s3')
LambdaName = os.getenv("LAMBDA_NAME", '')
if not LambdaName:
    LambdaName = os.getenv("NAME", '')

# Variável de Ambiente para definir o tipo de integração da API
# Valores possíveis: "PROXY" ou "AWS" (Padrão: AWS/Service Integration)
API_INTEGRATION_TYPE = os.getenv("API_INTEGRATION_TYPE", "PROXY").upper()

def execute_with_xray(segment_name, function, *args, **kwargs):
    """
    Wrapper para execução com X-Ray
    """
    if function.__name__ == 'send_message':
        if xray_enabled:
            with xray_recorder.in_subsegment(segment_name) as subsegment:
                try:
                    result = function(*args, **kwargs)
                    if "QueueUrl" in kwargs:
                        subsegment.put_annotation("QueueUrl", kwargs["QueueUrl"])
                    return result
                except Exception as e:
                    subsegment.add_exception(e, traceback.format_exc())
                    raise
        else:
            return function(*args, **kwargs)
    else:
        return function(*args, **kwargs)


# *************************** Recursos de Destino (Targets) ***********************

# --- SQS Targets ---
SQSTargetMaxNumber = 0
SQSTargetName = []
QueueTargetUrl = []
i = 0
while True:
    Name = os.getenv(f"AWS_SQS_QUEUE_TARGET_NAME_{str(i)}")
    URL = os.getenv(f"AWS_SQS_QUEUE_TARGET_URL_{str(i)}")
    if Name != None:
        SQSTargetName.append(Name)
        QueueTargetUrl.append(URL)
    else:
        SQSTargetMaxNumber = i
        break
    i += 1
print(f"Total SQS Targets: {i} {SQSTargetName}")

# --- SNS Targets ---
SNSTargetMaxNumber = 0
SNSTargetName = []
TopicTargetARN = []
i = 0
while True:
    Name = os.getenv(f"AWS_SNS_TOPIC_TARGET_NAME_{str(i)}")
    ARN = os.getenv(f"AWS_SNS_TOPIC_TARGET_ARN_{str(i)}")
    if Name != None:
        SNSTargetName.append(Name)
        TopicTargetARN.append(ARN)
    else:
        SNSTargetMaxNumber = i
        break
    i += 1
print(f"Total SNS Targets: {i} {SNSTargetName}")

# --- DynamoDB Targets ---
DynamoDBTargetMaxNumber = 0
TableNameTargetList = []
ListDynamo = []
i = 0
while True:
    TableName = os.getenv(f"AWS_DYNAMODB_TABLE_TARGET_NAME_{str(i)}")
    if TableName != None:
        TableNameTargetList.append([dynamodb.Table(TableName), TableName])
        ListDynamo.append(TableName)
        Table = TableNameTargetList[i][0]
        # Inicialização simples da tabela (Upsert ID 1)
        try:
            response = Table.get_item(Key={'ID': "1"})
            if 'Item' not in response:
                Table.put_item(Item={'ID': "1", "LambdaName": "Created by " + LambdaName, 'Cont': 0})
        except Exception as e:
            print(f"Error checking DynamoDB table {TableName}: {e}")
    else:
        DynamoDBTargetMaxNumber = i
        break
    i += 1
print(f"Total DynamoDB Targets: {i} {ListDynamo}")

# --- Lambda Targets ---
LambdaMaxNumber = 0
LambdaNameList = []
i = 0
while True:
    Name = os.getenv(f"AWS_LAMBDA_FUNCTION_TARGET_NAME_{str(i)}")
    if Name != None:
        LambdaNameList.append(Name)
        LambdaMaxNumber = i
    else:
        break
    i += 1
print(f"Total Lambda Targets: {i} {LambdaNameList}")

# --- CodeBuild Targets ---
CodeBuildMaxNumber = 0
CodeBuildNameList = []
i = 0
while True:
    Name = os.getenv(f"AWS_CODEBUILD_PROJECT_TARGET_NAME_{str(i)}")
    if Name is not None:
        CodeBuildNameList.append(Name)
        CodeBuildMaxNumber = i
    else:
        break
    i += 1
print(f"Total CodeBuild Targets: {i} {CodeBuildNameList}")

# --- S3 Targets ---
S3TargetMaxNumber = 0
S3BucketTarget = []
i = 0
while True:
    Name = os.getenv(f"AWS_S3_BUCKET_TARGET_NAME_{str(i)}")
    TargetRegion = os.getenv(f"AWS_S3_BUCKET_TARGET_REGION_{str(i)}")
    if Name is not None:
        S3BucketTarget.append([Name, TargetRegion])
    else:
        S3TargetMaxNumber = i
        break
    i += 1
print(f"Total S3 Targets: {i}")

# --- EC2 Targets ---
def find_ec2_dns_by_tag(key, value, region):
    ec2 = boto3.client('ec2', region_name=region)
    response = ec2.describe_instances(Filters=[{'Name': f'tag:{key}', 'Values': [value]}])
    for reservation in response['Reservations']:
        for instance in reservation['Instances']:
            return instance.get('PublicDnsName'), instance.get('PrivateDnsName')
    return None, None

EC2TargetDNS = []
EC2TargetName = []
i = 0
while True:
    Name = os.getenv(f"AWS_INSTANCE_TARGET_NAME_{str(i)}")
    TargetRegion = os.getenv(f"AWS_INSTANCE_TARGET_REGION_{str(i)}")
    if Name is not None:
        public_dns, private_dns = find_ec2_dns_by_tag('Name', Name, TargetRegion)
        EC2TargetName.append(Name)
        if public_dns:
            EC2TargetDNS.append(public_dns)
            print(f"Found public DNS for {Name}")
        else:
            EC2TargetDNS.append(private_dns)
            print(f"Found private DNS for {Name}")
    else:
        break
    i += 1
print(f"Total EC2 Targets: {i} {EC2TargetName}")

# --- EFS Targets ---
EFSList = []
EFSNameList = []
i = 0
while True:
    Name = os.getenv(f"AWS_EFS_FILE_SYSTEM_TARGET_NAME_{str(i)}")
    if Name is not None:
        Path = os.getenv(f"AWS_EFS_ACCESS_POINT_TARGET_PATH_{str(i)}")
        EFSList.append(Path)
        EFSNameList.append(Name)
    else:
        break
    i += 1
print(f"Total EFS Targets: {i} {EFSNameList}")

# --- SSM Parameter Targets ---
SSMParameterTargetName = []
SSMParameterTargetRegion = []
i = 0
while True:
    Name = os.getenv(f"AWS_SSM_PARAMETER_TARGET_NAME_{str(i)}")
    TargetRegion = os.getenv(f"AWS_SSM_PARAMETER_TARGET_REGION_{str(i)}")
    if Name is not None and TargetRegion is not None:
        SSMParameterTargetName.append(Name)
        SSMParameterTargetRegion.append(TargetRegion)
    else:
        break
    i += 1
print(f"Total SSM Parameters: {i} {SSMParameterTargetName}")

# *************************** Recursos de Origem (Sources) ***********************
# (Mantendo carregamento de Secrets para RDS)
SecretsCredentials = []
SecretNameList = []
i = 0
while True:
    SecretName = os.getenv(f"AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_{i}")
    SecretARN = os.getenv(f"AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_{i}")
    if SecretName is not None:
        client = boto3.client('secretsmanager', region_name=Region)
        response = client.get_secret_value(SecretId=SecretARN)
        secret = json.loads(response['SecretString'])
        username = secret['username']
        password = secret['password']
        SecretsCredentials.append([SecretName, username, password])
        SecretNameList.append(SecretName)
    else:
        break
    i += 1
print(f"Total Secret Sources: {i} {SecretNameList}")

# --- RDS Connection Helpers ---
def create_connection(host_name, user_name, user_password, db_name):
    connection = None
    try:
        connection = pymysql.connect(
            host=host_name, user=user_name, password=user_password,
            database=db_name, charset='utf8mb4', cursorclass=pymysql.cursors.DictCursor
        )
        print("Connection to MySQL DB successful")
    except MySQLError as e:
        print(f"The error '{e}' occurred")
    return connection

def execute_query(connection, query, values=None):
    with connection.cursor() as cursor:
        try:
            if values:
                cursor.execute(query, values)
            else:
                cursor.execute(query)
            connection.commit()
            print("Query executed successfully")
        except MySQLError as e:
            print(f"The error '{e}' occurred")

RDSConnections = []
i = 0
if MySQLEnabled:
    while True:
        database = os.getenv(f"AWS_DB_INSTANCE_TARGET_NAME_{i}")
        if database is not None:
            EndPoint = os.getenv(f"AWS_DB_INSTANCE_TARGET_ENDPOINT_{i}")
            Host = EndPoint.split(":")[0]
            # Lógica de credenciais (mantida)
            FoundSecret = False
            username = "TypeNewUserName"
            password = "TypeNewPassword"
            if len(SecretsCredentials) > 0:
                for j in range(len(SecretsCredentials)):
                    if database in SecretsCredentials[j][0]:
                        username = SecretsCredentials[j][1]
                        password = SecretsCredentials[j][2]
                        FoundSecret = True
                        break
                if not FoundSecret and len(SecretsCredentials) > 0:
                     username = SecretsCredentials[0][1]
                     password = SecretsCredentials[0][2]

            print(f"Connecting to RDS {i}: {database}, {Host}")
            connection = create_connection(Host, username, password, database)
            if connection is not None:
                RDSConnections.append([connection, database])
                create_table_query = """
                    CREATE TABLE IF NOT EXISTS exemplo (
                        id INT AUTO_INCREMENT, texto VARCHAR(4000) NOT NULL, PRIMARY KEY (id)
                    )
                """
                execute_query(connection, create_table_query)
        else:
            break
        i += 1

# ******************************************************************************
# *                             LAMBDA HANDLER                                 *
# ******************************************************************************

def lambda_handler(event, context):
    print("Event Received:", json.dumps(event))
    
    # 1. Identificar a Origem (EventSource)
    EventSource = "API" # Padrão
    
    try:
        if 'Records' in event and len(event['Records']) > 0:
            record = event['Records'][0]
            if 'Sns' in record:
                EventSource = "aws:sns"
            elif 'eventSource' in record and record['eventSource'] == "aws:sqs":
                EventSource = "aws:sqs"
            elif 's3' in record:
                EventSource = "aws:s3"
            elif 'kinesis' in record:
                EventSource = "aws:kinesis"
        elif 'CodePipeline.job' in event:
            EventSource = "aws:codepipeline"
        elif 'source' in event and event['source'] == "aws.events":
            EventSource = "aws.events"
        elif 'requestContext' in event:
            if 'elb' in event['requestContext']:
                EventSource = "aws:elb"
            elif 'http' in event['requestContext'] or 'apiId' in event['requestContext']:
                EventSource = "API" # Proxy (HTTP API or REST API)
        elif 'AWS:EC2' in str(event): # Simplificação baseada no seu código original
             EventSource = "AWS:EC2"
    except Exception as e:
        print(f"Error determining source: {e}")
        EventSource = "API"

    print(f"Determined Source: {EventSource}")

    # 2. Extração da Mensagem
    Subject = "None"
    Message = ""
    Information = ""

    if EventSource == "aws:sns":
        SNSName = event['Records'][0]['Sns']['TopicArn'].split(":")[-1]
        EventSource += f":{SNSName}"
        Subject = event['Records'][0]['Sns']['Subject']
        Message = event['Records'][0]['Sns']['Message']
        Information = f"Message from SNS {SNSName}"

    elif EventSource == "aws:sqs":
        SQSName = event['Records'][0]['eventSourceARN'].split(":")[-1]
        Message = event['Records'][0]['body']
        Information = f"Message from SQS {SQSName}"

    elif EventSource == "aws.events":
        EBName = event['resources'][0].split("/")[-1]
        Message = f"Event from {EBName}"
        Information = f"Message from EventBridge {EBName}"

    elif EventSource == "aws:s3":
        EventSource += event['Records'][0]['s3']["bucket"]['arn'].split(":")[-1]
        FileSize = str(event['Records'][0]['s3']['object']["size"])
        bucket_name = event['Records'][0]['s3']['bucket']["name"]
        file_path_encoded = event['Records'][0]['s3']['object']["key"]
        file_path = unquote(file_path_encoded).replace('+', ' ')
        Ext = file_path.split(".")[-1]
        
        if Ext == "txt":
            response = execute_with_xray(bucket_name, s3.get_object, Bucket=bucket_name, Key=file_path)
            Message = response['Body'].read().decode('utf-8')
        else:
            Message = f"File {file_path} is not .txt"
        Information = f"File {file_path} from S3 bucket {bucket_name}, size {FileSize}"

    elif EventSource == "aws:elb":
        ALBName = event['requestContext']['elb']['targetGroupArn'].split(":")[-1]
        Message = "HTTP request from ALB"
        Information = f"Request from ALB {ALBName}"

    elif EventSource == "aws:codepipeline":
        job_id = event['CodePipeline.job']['id']
        Message = "Job ID: " + job_id
        Information = "Event from CodePipeline"

    elif EventSource == "AWS:EC2":
        Information = "Event from EC2"
        Message = event.get("message", "No message")

    elif EventSource == "API":
        # *** LÓGICA FLEXÍVEL PARA API ***
        print(f"Processing API Event with mode: {API_INTEGRATION_TYPE}")
        
        if API_INTEGRATION_TYPE == "PROXY":
            # Modo Proxy Integration (Lambda Proxy)
            try:
                body_raw = event.get('body', '{}')
                if body_raw is None: body_raw = '{}'
                
                # Se o body vier como string (o padrão do Proxy), faz parse
                if isinstance(body_raw, str):
                    body_data = json.loads(body_raw)
                else:
                    body_data = body_raw
                
                # Tenta extrair 'message' ou usa o body inteiro
                if isinstance(body_data, dict):
                    Message = str(body_data.get('message', body_data))
                    Source = body_data.get('source', 'API Proxy')
                else:
                    Message = str(body_data)
                    Source = 'API Proxy'
            except Exception as e:
                Message = f"Error parsing Proxy Body: {str(e)}"
                Source = "API Proxy Error"
        else:
            # Modo Service Integration (Non-Proxy / VTL)
            # Assume que o API Gateway já entregou o JSON limpo
            try:
                Message = str(event.get("message", event))
                Source = event.get("source", "API AWS Integration")
            except:
                Message = str(event)
                Source = "API"
        
        Information = f"Event from API (Mode: {API_INTEGRATION_TYPE})"


    # Verificação de Loop Infinito
    if LambdaName in Message:
        print("Loop Found! Stopping execution.")
        return create_response(EventSource, "Loop prevented", 200)

    Agora = datetime.datetime.now()
    NewMessage = f"Lambda: {LambdaName}. Source: {EventSource}. Date/Time: {str(Agora)}. <- {Message}"
    print("Message to be sent: ", NewMessage)

    # ************************* SQS Block **************************************
    for i in range(SQSTargetMaxNumber):
        print(f"Sending to SQS: {SQSTargetName[i]}")
        execute_with_xray(SQSTargetName[i], sqs.send_message, QueueUrl=QueueTargetUrl[i], MessageBody=NewMessage)

    # ************************* DynamoDB Block **********************************
    for i in range(DynamoDBTargetMaxNumber):
        Table = TableNameTargetList[i][0]
        TableName = TableNameTargetList[i][1]
        try:
            # Atomic counter update
            execute_with_xray(TableName, Table.update_item, 
                Key={'ID': "1"},
                UpdateExpression='SET Cont = if_not_exists(Cont, :zero) + :val1',
                ExpressionAttributeValues={':val1': 1, ':zero': 0}
            )
            # Put log item
            ttl_timestamp = int((datetime.datetime.now() + datetime.timedelta(days=1)).timestamp())
            ID = f"{LambdaName}:{str(Agora)}"
            execute_with_xray(TableName, Table.put_item, Item={'ID': ID, "Message": NewMessage, 'TTL': ttl_timestamp})
        except Exception as e:
            print(f"DynamoDB Error: {e}")

    # ************************* SNS Block **********************************
    for i in range(SNSTargetMaxNumber):
        topic_arn = TopicTargetARN[i]
        execute_with_xray(topic_arn, sns.publish, TopicArn=topic_arn,
                          Message=json.dumps({'default': json.dumps(NewMessage)}), MessageStructure='json')

    # ************************* Lambda Block ********************
    lambda_cli = boto3.client('lambda')
    for function_name in LambdaNameList:
        payload = json.dumps({"message": NewMessage, "source": "aws:lambda"})
        execute_with_xray(function_name, lambda_cli.invoke, FunctionName=function_name,
                          InvocationType='Event', Payload=payload)

    # ************************* S3 Block **********************************
    for i in range(S3TargetMaxNumber):
        bucket_name = S3BucketTarget[i][0]
        region_s3 = S3BucketTarget[i][1]
        s3_cli = boto3.client('s3', region_name=region_s3)
        file_path = f"{LambdaName}/{LambdaName}:{str(Agora)}.txt"
        execute_with_xray(bucket_name, s3_cli.put_object, Bucket=bucket_name, Key=file_path, Body=NewMessage)

    # ************************* EFS Block **********************************
    for efs_mount_path in EFSList:
        try:
            file_name = f"{LambdaName}:{str(Agora)}.txt"
            test_file_path = os.path.join(efs_mount_path, file_name)
            with open(test_file_path, "w") as file:
                file.write(NewMessage)
        except Exception as e:
            print(f"EFS Error: {e}")

    # ************************* RDS Block **********************************
    for connection, db_name in RDSConnections:
        try:
            Data = json.dumps(NewMessage)
            execute_query(connection, "INSERT INTO exemplo (texto) VALUES (%s)", (Data,))
        except Exception as e:
            print(f"RDS Error on {db_name}: {e}")

    # ************************* SSM Parameter Block ************************
    for Name, region in zip(SSMParameterTargetName, SSMParameterTargetRegion):
        ssm_client = boto3.client('ssm', region_name=region)
        try:
            # Simples incremento de contador no Parameter Store
            try:
                resp = execute_with_xray(Name, ssm_client.get_parameter, Name=Name, WithDecryption=True)
                val = int(resp['Parameter']['Value']) + 1
            except:
                val = 0
            execute_with_xray(Name, ssm_client.put_parameter, Name=Name, Value=str(val), Type='String', Overwrite=True)
        except Exception as e:
            print(f"SSM Error: {e}")

    # ************************* EC2 HTTP Block *****************************
    MessageJSON = json.dumps(NewMessage).encode('utf-8')
    for DNS, EC2Name in zip(EC2TargetDNS, EC2TargetName):
        try:
            Conn = http.client.HTTPConnection(DNS, timeout=2)
            Headers = {'Content-type': 'application/json'}
            execute_with_xray(EC2Name, Conn.request, "POST", f'/{EC2Name}', body=MessageJSON, headers=Headers)
            Resp = Conn.getresponse()
            Conn.close()
            print(f"EC2 Response: {Resp.status}")
        except Exception as e:
            print(f"EC2 Connection Error: {e}")

    # ************************* CodeBuild Block ****************************
    codebuild = boto3.client('codebuild')
    env_vars = [{'name': 'EVENT', 'value': NewMessage, 'type': 'PLAINTEXT'}]
    for CodeBuildName in CodeBuildNameList:
        execute_with_xray(CodeBuildName, codebuild.start_build, projectName=CodeBuildName, environmentVariablesOverride=env_vars)

    # ************************* PROCESSAMENTO CODEPIPELINE *****************
    if EventSource == "aws:codepipeline":
        return process_codepipeline(event, job_id)

    # ************************* RESPOSTA FINAL (RESPONSE) ******************
    return create_response(EventSource, NewMessage)


def process_codepipeline(event, job_id):
    """Função auxiliar para CodePipeline para manter o handler limpo"""
    try:
        credentials = event['CodePipeline.job']['data']['artifactCredentials']
        s3_pipe = boto3.client('s3',
            aws_access_key_id=credentials['accessKeyId'],
            aws_secret_access_key=credentials['secretAccessKey'],
            aws_session_token=credentials['sessionToken']
        )
        input_artifacts = event['CodePipeline.job']['data']['inputArtifacts']
        output_artifacts = event['CodePipeline.job']['data']['outputArtifacts']
        
        if input_artifacts:
            artifact = input_artifacts[0]
            loc = artifact['location']['s3Location']
            if loc['objectKey'].endswith(".txt"):
                obj = s3_pipe.get_object(Bucket=loc['bucketName'], Key=loc['objectKey'])
                content = obj['Body'].read().decode('utf-8').upper()
                
                if output_artifacts:
                    out = output_artifacts[0]
                    out_loc = out['location']['s3Location']
                    s3_pipe.put_object(Bucket=out_loc['bucketName'], Key=out_loc['objectKey'], Body=content.encode('utf-8'))
        
        codepipeline = boto3.client('codepipeline')
        codepipeline.put_job_success_result(jobId=job_id)
        return {'statusCode': 200, 'body': json.dumps({'status': 'SUCCESS'})}
    except Exception as e:
        codepipeline = boto3.client('codepipeline')
        codepipeline.put_job_failure_result(jobId=job_id, failureDetails={'type': 'JobFailed', 'message': str(e)})
        return {'statusCode': 500, 'body': json.dumps({'status': 'FAILED'})}


def create_response(event_source, message, status_code=200):
    """
    Fábrica de Respostas: Decide o formato do retorno baseando-se na origem
    e na variável de ambiente.
    """
    
    # Se for ALB, o formato é fixo (Proxy)
    if event_source == "aws:elb":
        return {
            'statusCode': status_code,
            'statusDescription': '200 OK',
            'isBase64Encoded': False,
            'headers': {'Content-Type': 'text/html; charset=utf-8'},
            'body': message
        }
    
    # Se for API Gateway
    if event_source == "API":
        if API_INTEGRATION_TYPE == "PROXY":
            # Retorno Proxy Integration (JSON completo)
            return {
                'statusCode': status_code,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'message': 'Message processed',
                    'original_data': message,
                    'timestamp': str(datetime.datetime.now())
                })
            }
        else:
            # Retorno AWS Integration (Non-Proxy - apenas o dado)
            return message

    # Para outras fontes (SNS, SQS, etc), retorno simples geralmente é ignorado
    # ou usado apenas para logs
    return message
