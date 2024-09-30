import os

# Configurar logging
if CloudWatchName != "":
    logging.basicConfig(level=logging.INFO)
    logger = logging.getLogger(__name__)
    cw_handler = watchtower.CloudWatchLogHandler(
        log_group=CloudWatchName,
        stream_name=SegmentName
    )
    logger.addHandler(cw_handler)
    logger.info(f"EC2 Host: {InstanceName} Region {Region}")

def LogMessage(Msg):
    if StatusLogsEnabled:
        logger.info(Msg)

#Identificação dos dos recursos conectados
    
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
        LogMessage(f"SQS Target {i} {Name}")
        LogMessage(f"Queue Target Url: {URL}")
    else:
        LogMessage(f"Total SQS Targets: {i}")
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
        LogMessage(f"SNS Target: {i} {Name}")
        LogMessage(f"SNS Topic ARN: {ARN}")
    else:
        LogMessage(f"Total SNS Targets: {i}")
        break
    i += 1

def init_table(table_resource, TableName):
    # Chamada ao wrapper para obter o item
    response = execute_with_xray(f"get_item_dynamodb_table_{TableName}", table_resource.get_item, Key={'ID': "1"})
    if 'Item' not in response:
        ItemData = f"Criado por {InstanceName}"
        execute_with_xray(f"put_item_dynamodb_table_{TableName}", table_resource.put_item, Item={'ID': "1", "InstanceName": ItemData, 'Cont': 0})
        LogMessage(f"Initialized DynamoDB table: {TableName}")


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
        LogMessage(f"S3 Target: {i} {Name}")
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
        LogMessage(f"EFS Target: {i} {Name}")
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
        LogMessage(f"Lambda Target: {i} {FunctionName}")
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
        LogMessage(f"ALB Target {i}: {ALBName}, URL: {URL}")
    else:
        LogMessage(f"Total ALBs Targets: {i}")
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
        LogMessage(f"SQS Source: {i} {Name}")
    else:
        SQSSourceMaxNumber = i
        break
    i += 1