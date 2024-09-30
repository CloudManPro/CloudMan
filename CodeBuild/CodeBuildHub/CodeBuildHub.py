import boto3
import os
import json
import datetime
import http.client
import logging
from urllib.parse import unquote

# Configurar logging para enviar logs para console e arquivo
log_filename = '/tmp/codebuild_log.txt'
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(message)s')

# Adicionar handler de arquivo
file_handler = logging.FileHandler(log_filename)
file_handler.setLevel(logging.INFO)
file_handler.setFormatter(logging.Formatter('%(asctime)s - %(message)s'))
logging.getLogger().addHandler(file_handler)


try:
    from aws_xray_sdk.core import xray_recorder
    from aws_xray_sdk.core import patch_all
    # Habilita o rastreamento automático do X-Ray
    patch_all()
    xray_enabled = True
except:
    xray_enabled = False
    logging.info("XRay SDK not found!")

XRay = os.getenv('XRay_Enabled', "False")
if XRay == "False":
    xray_enabled = False

try:
    import pymysql
    from pymysql import MySQLError
    MySQLEnabled = True
except:
    MySQLEnabled = False
    logging.info("Pymysql not found!")

# Cria um cliente para acessar os serviços AWS
Region = os.getenv("Region")
AccountID = os.getenv("Account")
sqs = boto3.client('sqs', region_name=Region)
dynamodb = boto3.resource('dynamodb', region_name=Region)
lambda_client = boto3.client('lambda', region_name=Region)
sns = boto3.client('sns', region_name=Region)
s3 = boto3.client('s3')
CodeBuildName = os.getenv("Name")


def execute_with_xray(segment_name, function, *args, **kwargs):
    """
    Executa uma função dentro de um subsegmento do X-Ray se ele estiver habilitado.
    :param segment_name: Nome do subsegmento do X-Ray.
    :param function: Função a ser executada.
    :param args: Argumentos posicionais para a função.
    :param kwargs: Argumentos nomeados para a função.
    :return: O resultado da função executada.
    """
    '''if xray_enabled:
        with xray_recorder.in_subsegment(segment_name):
            return function(*args, **kwargs)
    else:
        return function(*args, **kwargs)'''
    return function(*args, **kwargs)


def main(event):
    logging.info("Event: %s", event)
    Information = "Source unknown!!"
    Message = "No Message!!"
    try:
        EventSource = event['Records'][0]['eventSource']
    except:
        EventSource = "API"
    Subject = "None"
    if EventSource == "aws:sns":
        SNSName = event['Records'][0]['Sns']['TopicArn'].split(":")[-1]
        EventSource += SNSName
        Subject = event['Records'][0]['Sns']['Subject']
        Message = event['Records'][0]['Sns']['Message']
        Information = "Message from SNS " + SNSName
    elif EventSource == "aws:sqs":
        SQSName = event['Records'][0]['eventSourceARN'].split(":")[-1]
        Message = event['Records'][0]['body']
        Information = "Message from SQS " + SQSName
    elif EventSource == "aws:s3":
        EventSource += event['Records'][0]['s3']["bucket"]['arn'].split(
            ":")[-1]
        FileSize = str(event['Records'][0]['s3']['object']["size"])
        bucket_name = event['Records'][0]['s3']['bucket']["name"]
        file_path_encoded = event['Records'][0]['s3']['object']["key"]
        # Decodifica o nome do arquivo
        file_path = unquote(file_path_encoded).replace('+', ' ')
        Ext = file_path.split(".")[-1]
        logging.info("bucket_name: %s, file_path: %s", bucket_name, file_path)
        # lê o conteúdo do arquivo
        if Ext == "txt":
            response = execute_with_xray(
                bucket_name, s3.get_object, Bucket=bucket_name, Key=file_path)
            Message = response['Body'].read().decode('utf-8')
        else:
            Message = "File is not .txt"
        Information = "File " + file_path + " from S3 bucket " + \
            bucket_name + ", with size of " + FileSize
    elif 'requestContext' in event and 'elb' in event['requestContext']:
        EventSource = "aws:elb"
        ALBName = event['requestContext']['elb']['targetGroupArn'].split(
            ":")[-1]
        Message = "HTTP request from ALB"
        Information = "Request from ALB " + ALBName
    elif EventSource == "API":
        Subject = "None"
        try:
            Source = event["source"]
            Message = str(event["message"])
        except:
            Source = "API"
            Message = str(event)
        if Source == "aws:lambda":
            EventSource = "Lambda"
            Information = "Event from Lambda"
        if Source == "aws:ec2":
            Information = "Event from EC2"
            EventSource = "EC2"
        else:
            Information = "Event from API"

    logging.info("Source of Event: %s", EventSource)
    Agora = datetime.datetime.now()
    CodeBuildName = os.getenv("Name")
    NewMessage = f"CodeBuild: {CodeBuildName}. Source: {EventSource}. Date/Time: {str(Agora)}. <- {Message}"
    logging.info("Message to be sent: %s", NewMessage)

    # *************************Bloco SQS**************************************
    for i in range(SQSTargetMaxNumber):
        message_body = NewMessage
        logging.info("QueueTargetUrl[%d]: %s", i, QueueTargetUrl[i])
        response = execute_with_xray(
            SQSTargetName[i], sqs.send_message, QueueUrl=QueueTargetUrl[i], MessageBody=message_body)
        logging.info('Mensagem SQS %d enviada com ID: %s',
                     i, response['MessageId'])

    # *************************Bloco DynamoDB**********************************
    for i in range(DynamoDBTargetMaxNumber):
        Table = TableNameTargetList[i][0]
        TableName = TableNameTargetList[i][1]
        get_item_response = execute_with_xray(
            TableName, Table.get_item, Key={'ID': "1"})
        item = get_item_response['Item']
        cont = item['Cont'] + 1
        execute_with_xray(TableName, Table.update_item, Key={'ID': "1"},
                          UpdateExpression='SET Cont = :val1', ExpressionAttributeValues={':val1': cont})
        ID = CodeBuildName + ":" + str(Agora)
        put_item_response = execute_with_xray(TableName, Table.put_item, Item={
                                              'ID': ID, "Message": NewMessage})
        logging.info("DynamoDB response: %s", put_item_response)

    # *************************Bloco SNS**********************************
    for i in range(SNSTargetMaxNumber):
        topic_arn = TopicTargetARN[i]
        message = NewMessage
        response = execute_with_xray(topic_arn, sns.publish, TopicArn=topic_arn,
                                     Message=json.dumps({'default': json.dumps(message)}), MessageStructure='json')
        logging.info("Response SNS: %s", response)

    # *************************Bloco Lambda ********************
    lambda_client = boto3.client('lambda')
    for function_name in LambdaNameList:
        response = execute_with_xray(function_name, lambda_client.invoke, FunctionName=function_name,
                                     InvocationType='Event', Payload=json.dumps({"message": NewMessage, "source": "aws:lambda"}))
        if response.get('StatusCode') == 202:
            logging.info("Invoke lambda: %s", function_name)
        else:
            logging.error('Invocation error %s.', function_name)

    # *************************Bloco S3**********************************
    for i in range(S3TargetMaxNumber):
        bucket_name = S3BucketTargetName[i]
        folder_name = CodeBuildName + "/"
        file_name = CodeBuildName + ":" + str(Agora) + ".txt"
        file_content = NewMessage
        file_path = folder_name + file_name
        response = execute_with_xray(
            bucket_name, s3.put_object, Bucket=bucket_name, Key=file_path, Body=file_content)
        logging.info("Objeto inserido na bucket '%s'", bucket_name)

    # *************************Bloco EFS **********************************
    for efs_mount_path in EFSList:
        # Escreva um arquivo de teste no EFS
        file_name = CodeBuildName + ":" + str(Agora) + ".txt"
        test_file_path = os.path.join(efs_mount_path, file_name)
        with open(test_file_path, "w") as file:
            file.write(NewMessage)

    for connection, db_name in RDSConnections:
        insert_query = "INSERT INTO exemplo (texto) VALUES (%s)"
        try:
            Data = json.dumps(NewMessage)
            execute_query(connection, insert_query, (Data,))
            logging.info(
                "Item inserido na tabela 'exemplo' do banco de dados '%s'", db_name)
        except MySQLError as e:
            logging.error(
                "Erro ao inserir item no banco de dados '%s': %s", db_name, e)

    # *************************Bloco SSM Parameter **********************************
    for Name, region in zip(SSMParameterTargetName, SSMParameterTargetRegion):
        ssm_client = boto3.client('ssm', region_name=region)
        try:
            response = execute_with_xray(
                Name, ssm_client.get_parameter, Name=Name, WithDecryption=True)
            current_value = response['Parameter']['Value']
            try:
                int_value = int(current_value)
                new_value = str(int_value + 1)
            except ValueError:
                new_value = '0'
            execute_with_xray(Name, ssm_client.put_parameter, Name=Name,
                              Value=new_value, Type='String', Overwrite=True)
            logging.info("SSM Parameter %s updated: %s", Name, new_value)
        except Exception as e:
            logging.error(
                "Erro ao processar o parâmetro %s na região %s: %s", Name, region, e)

    # *************************Bloco EC2 **********************************
    MessageJSON = json.dumps(NewMessage).encode('utf-8')
    for DNS, EC2Name in zip(EC2TargetDNS, EC2TargetName):
        try:
            Path = f'/{EC2Name}'
            Conn = http.client.HTTPConnection(DNS)
            Headers = {'Content-type': 'application/json'}
            Response = execute_with_xray(
                EC2Name, Conn.request, "POST", Path, body=MessageJSON, headers=Headers)
            Response = Conn.getresponse()
            if Response.status == 200:
                logging.info("Message sent with Success to %s.", EC2Name)
            else:
                logging.error("Message sent error to %s. Código: %d",
                              EC2Name, Response.status)
            Conn.close()
        except Exception as e:
            logging.error("Message sent error %s: %s", EC2Name, e)

    # *************************Bloco CodeBuild ********************
    codebuild = boto3.client('codebuild')
    environment_variables = [
        {'name': 'EVENT', 'value': NewMessage, 'type': 'PLAINTEXT'}]
    for CodeBuildName in CodeBuildNameList:
        response = execute_with_xray(CodeBuildName, codebuild.start_build, projectName=CodeBuildName,
                                     environmentVariablesOverride=environment_variables)

    # *************************Retorno ALB **********************************
    if EventSource == "aws:elb":
        response = {
            'statusCode': 200,
            'statusDescription': '200 OK',
            'isBase64Encoded': False,
            'headers': {
                'Content-Type': 'text/html; charset=utf-8'
            },
            'body': NewMessage
        }
        return response

    # *************************Retorno API **********************************
    if EventSource == "API":
        return NewMessage


# ***************************Resources Target***********************************

# ****************Identifica a URL de cada SQS Target***************************
SQSTargetMaxNumber = 0
SQSTargetName = []
QueueTargetUrl = []
Name = ""
i = 0
while True:
    Name = os.getenv(f"aws_sqs_queue_Target_Name_{str(i)}")
    Region = os.getenv(f"aws_sqs_queue_Target_Region_{str(i)}")
    SQSURL = os.getenv(f"aws_sqs_queue_Target_URL_{str(i)}")
    if Name != None:
        SQSTargetName.append(Name)
        QueueTargetUrl.append(SQSURL)
    else:
        SQSTargetMaxNumber = i
        break
    i += 1
logging.info("SQS Target Total: %d %s", i, SQSTargetName)

# **********Identifica a ARN Target de cada SNS Target**************************
SNSTargetMaxNumber = 0
SNSTargetName = []
TopicTargetARN = []
i = 0
while True:
    Name = os.getenv(f"aws_sns_topic_Target_Name_{str(i)}")
    Region = os.getenv(f"aws_sns_topic_Target_Region_{str(i)}")
    Account = os.getenv(f"aws_sns_topic_Target_Account_{str(i)}")
    if (Account):
        pass
    else:
        Account = AccountID
    if Name != None:
        SNSTargetName.append(Name)
        ARN = f"arn:aws:sns:{Region}:{Account}:{Name}"
        TopicTargetARN.append(ARN)
    else:
        SNSTargetMaxNumber = i
        break
    i += 1
logging.info("SNS Target Total: %d %s", i, SNSTargetName)

# **************Inicializa cada tabela DynamoDB*********************************
DynamoDBTargetMaxNumber = 0
TableNameTargetList = []
ListDynamo = []
i = 0
while True:
    TableName = os.getenv(f"aws_dynamodb_table_Target_Name_{str(i)}")
    Region = os.getenv(f"aws_dynamodb_table_Target_Region_{str(i)}")
    Account = os.getenv(f"aws_dynamodb_table_Target_Account_{str(i)}")
    if TableName != None:
        TableNameTargetList.append([dynamodb.Table(TableName), TableName])
        ListDynamo.append(TableName)
        Table = TableNameTargetList[i][0]
        response = Table.get_item(Key={'ID': "1"})
        if 'Item' not in response:
            Table.put_item(
                Item={'ID': "1", "CodeBuildName": "Criado por " + CodeBuildName, 'Cont': 0})
    else:
        DynamoDBTargetMaxNumber = i
        break
    i += 1
logging.info("DynamoDB Target Total: %d %s", i, ListDynamo)

# *************Inicializa cada Lambda a ser invocada***************************
LambdaMaxNumber = 0
LambdaNameList = []
i = 0
while True:
    Name = os.getenv(f"aws_lambda_function_Target_Name_{str(i)}")
    Region = os.getenv(f"aws_lambda_function_Target_Region_{str(i)}")
    Account = os.getenv(f"aws_lambda_function_Target_Account_{str(i)}")
    if Name != None:
        LambdaNameList.append(Name)
        LambdaMaxNumber = i
    else:
        break
    i += 1
logging.info("Lambda Target Total: %d %s", i, LambdaNameList)

# *************Inicializa cada CodeBuid target***************************
CodeBuildMaxNumber = 0
CodeBuildNameList = []
i = 0
while True:
    Name = os.getenv(f"aws_codebuild_project_Target_Name_{str(i)}")
    Region = os.getenv(f"aws_codebuild_project_Target_Region_{str(i)}")
    Account = os.getenv(f"aws_codebuild_project_Target_Name_Account_{str(i)}")
    if Name != None:
        CodeBuildNameList.append(Name)
        CodeBuildMaxNumber = i
    else:
        break
    i += 1
logging.info("CodeBuild Target Total: %d %s", i, CodeBuildNameList)

# **********Identifica cada S3 target **************************
S3TargetMaxNumber = 0
S3BucketTargetName = []
i = 0
while True:
    Name = os.getenv(f"aws_s3_bucket_Target_Name_{str(i)}")
    Region = os.getenv(f"aws_s3_bucket_Target_Region_{str(i)}")
    Account = os.getenv(f"aws_s3_bucket_Target_Account_{str(i)}")
    if Name != None:
        S3BucketTargetName.append(Name)
    else:
        S3TargetMaxNumber = i
        break
    i += 1
logging.info("S3 Target Total: %d %s", i, S3BucketTargetName)

# **********Identifica EC2 target **************************


def find_ec2_dns_by_tag(tag_key, tag_value, region_name):
    ec2 = boto3.client('ec2', region_name=region_name)
    response = ec2.describe_instances(
        Filters=[{'Name': f'tag:{tag_key}', 'Values': [tag_value]}])
    public_dns = None
    private_dns = None
    for reservation in response['Reservations']:
        for instance in reservation['Instances']:
            if instance.get('PublicDnsName'):
                public_dns = instance['PublicDnsName']
            if instance.get('PrivateDnsName'):
                private_dns = instance['PrivateDnsName']
    return public_dns, private_dns


EC2TargetDNS = []
EC2TargetName = []
i = 0
while True:
    Name = os.getenv(f"aws_instance_Target_Name_{str(i)}")
    Region = os.getenv(f"aws_instance_Target_Region_{str(i)}")
    if Name != None:
        public_dns, private_dns = find_ec2_dns_by_tag('Name', Name, Region)
        EC2TargetName.append(Name)
        if public_dns != None:
            EC2TargetDNS.append(public_dns)
            logging.info("Achou DNS público")
        else:
            EC2TargetDNS.append(private_dns)
            logging.info("Achou DNS privado")
    else:
        break
    i += 1
logging.info("EC2 Target Total: %d %s", i, EC2TargetName)

# **************Inicializa EFS*********************************
EFSList = []
EFSNameList = []
i = 0
while True:
    Name = os.getenv(f"aws_efs_file_system_Target_Name_{str(i)}")
    if Name != None:
        Path = os.getenv(f"aws_efs_access_point_Target_Path_{str(i)}")
        EFSList.append(Path)
        EFSNameList.append(Name)
    else:
        EFSMaxNumber = i
        break
    i += 1
logging.info("EFS Target Total: %d %s", i, EFSNameList)

# **************Inicializa SSM Parameter*********************************
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
logging.info("SSM Parameter Target Total: %d %s", i, SSMParameterTargetName)

# ***************************Resources Source***********************************

# *****************Identifica a URL de cada SQS Source*************************
SQSSourceMaxNumber = 4
SQSSourceName = []
i = 0
while True:
    Name = os.getenv(f"aws_sqs_queue_Source_Name_{str(i)}")
    Region = os.getenv(f"aws_sqs_queue_Source_Region_{str(i)}")
    SQSURL = os.getenv(f"aws_sqs_queue_Source_URL_0{str(i)}")
    if Name != None:
        SQSSourceName.append(Name)
    else:
        SQSSourceMaxNumber = i
        break
    i += 1
logging.info("SQS Source Total: %d %s", i, SQSSourceName)

# **********Identifica a ARN Source de cada SNS Source**************************
SNSSourceMaxNumber = 4
SNSSourceName = []
i = 0
while True:
    Name = os.getenv(f"aws_sns_topic_Source_Name_{str(i)}")
    Region = os.getenv(f"aws_sns_topic_Source_Region_{str(i)}")
    Account = os.getenv(f"aws_sns_topic_Source_Account_{str(i)}")
    if Name != None:
        SNSTargetName.append(Name)
    else:
        SNSSourceMaxNumber = i
        break
    i += 1
logging.info("SNS Source Total: %d %s", i, SNSSourceName)

# **********Identifica cada S3 source **************************
S3SourceMaxNumber = 4
S3BucketSourceName = []
i = 0
while True:
    Name = os.getenv(f"aws_s3_bucket_Source_Name_{str(i)}")
    if Name != None:
        S3BucketSourceName.append(Name)
    else:
        S3SourceMaxNumber = i
        break
    i += 1
logging.info("S3 Notification Source Total: %d %s", i, S3BucketSourceName)

# ********* Lista para armazenar informações de username e password de cada secret
SecretsCredentials = []
SecretNameList = []
i = 0
while True:
    SecretName = os.getenv(
        f"aws_secretsmanager_secret_version_Source_Name_{i}")
    SecretARN = os.getenv(f"aws_secretsmanager_secret_version_Source_ARN_{i}")
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
logging.info("Secret Source Total: %d %s", i, SecretNameList)

# Funções para conectar e executar queries no MySQL


def create_connection(host_name, user_name, user_password, db_name):
    connection = None
    try:
        connection = pymysql.connect(
            host=host_name,
            user=user_name,
            password=user_password,
            database=db_name,
            charset='utf8mb4',
            cursorclass=pymysql.cursors.DictCursor
        )
        logging.info("Conexão ao MySQL DB bem-sucedida")
    except MySQLError as e:
        logging.error("O erro '%s' ocorreu", e)
    return connection


def execute_query(connection, query, values=None):
    with connection.cursor() as cursor:
        try:
            if values:
                cursor.execute(query, values)
            else:
                cursor.execute(query)
            connection.commit()
            logging.info("Query executada com sucesso")
        except MySQLError as e:
            logging.error("O erro '%s' ocorreu", e)


# ******************* Inicializa lista para armazenar as conexões RDS e criação de tabela.
RDSConnections = []
i = 0
if MySQLEnabled:
    while True:
        database = os.getenv(f"aws_db_instance_Target_Name_{i}")
        if database is not None:
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
            logging.info("Database e endpoint %d : %s, %s, %s",
                         i, database, Host, username)
            # Estabeleça a conexão e crie a tabela
            connection = create_connection(Host, username, password, database)
            if connection is not None:
                RDSConnections.append([connection, database])
                create_table_query = """
                    CREATE TABLE IF NOT EXISTS exemplo (
                        id INT AUTO_INCREMENT, 
                        texto VARCHAR(4000) NOT NULL, 
                        PRIMARY KEY (id)
                    )
                """
                execute_query(connection, create_table_query)
                logging.info("Tabela 'exemplo' criada")
        else:
            logging.info("Total RDS Targets: %d", i)
            break
        i += 1

# ******************************************************************************

if __name__ == "__main__":
    # Ler o evento da variável de ambiente
    event = os.getenv('EVENT')
    if event:
        # Converter o evento de string JSON para dicionário
        try:
            event = json.loads(event)
        except:
            pass
    else:
        event = {}

    main(event)
    logging.info("Fim")
