import boto3
import os
import json
import datetime
import http.client
from urllib.parse import unquote

try:
    from aws_xray_sdk.core import xray_recorder
    from aws_xray_sdk.core import patch_all
    # Habilita o rastreamento automático do X-Ray
    patch_all()
    xray_enabled = True
except:
    xray_enabled = False
    print("XRay SDK not found!")
XRay = os.getenv('XRay_Enabled', "False")
if XRay == "False":
    xray_enabled = False


try:
    import pymysql
    from pymysql import MySQLError
    MySQLEnabled = True
except:
    MySQLEnabled = False
    print("Pymysql not found!")

# Cria um clientes para acessar os serviço AWS

Region = os.getenv("Region")
AccountID = os.getenv("Account")
sqs = boto3.client('sqs', region_name=Region)
dynamodb = boto3.resource('dynamodb', region_name=Region)
lambda_client = boto3.client('lambda', region_name=Region)
sns = boto3.client('sns', region_name=Region)
s3 = boto3.client('s3')
LambdaName = os.getenv("LambdaName")


def execute_with_xray(segment_name, function, *args, **kwargs):
    """
    Executa uma função dentro de um subsegmento do X-Ray se ele estiver habilitado.
    :param segment_name: Nome do subsegmento do X-Ray.
    :param function: Função a ser executada.
    :param args: Argumentos posicionais para a função.
    :param kwargs: Argumentos nomeados para a função.
    :return: O resultado da função executada.
    """
    if xray_enabled:
        with xray_recorder.in_subsegment(segment_name):
            return function(*args, **kwargs)
    else:
        return function(*args, **kwargs)


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
    Account = os.getenv(f"aws_sqs_queue_Target_Account_{str(i)}")
    if Name != None:
        SQSTargetName.append(Name)
        URL = f"https://sqs.{Region}.amazonaws.com/{Account}/{Name}"
        QueueTargetUrl.append(URL)
    else:
        SQSTargetMaxNumber = i

        break
    i += 1
print(f"SQS Target Total: {i} {SQSTargetName}")

# **********Identifica a ARN Target de cada SNS Target**************************
SNSTargetMaxNumber = 0
SNSTargetName = []
TopicTargetARN = []

i = 0
while True:
    Name = os.getenv(f"aws_sns_topic_Target_Name_{str(i)}")
    Region = os.getenv(f"aws_sns_topic_Target_Region_{str(i)}")
    Account = os.getenv(f"aws_sns_topic_Target_Account_{str(i)}")
    if Name != None:
        SNSTargetName.append(Name)
        ARN = f"arn:aws:sns:{Region}:{Account}:{Name}"
        TopicTargetARN.append(ARN)
    else:
        SNSTargetMaxNumber = i
        break
    i += 1
print(f"SNS Target Total: {i} {SNSTargetName}")

# **************Inicializa cada tabela Dynamodb*********************************
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
                Item={'ID': "1", "LambdaName": "Criado por " + LambdaName, 'Cont': 0})
    else:
        DynamoDBTargetMaxNumber = i
        break
    i += 1
print(f"Dynamodb Target Total: {i} {ListDynamo}")

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
print(f"Lambda Target Total: {i} {LambdaNameList}")

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
print(f"CodeBuild Target Total: {i} {CodeBuildNameList}")
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
print(f"S3 Target Total: {i} {S3BucketTargetName}")

# **********Identifica EC2 target **************************


def find_ec2_dns_by_tag(tag_key, tag_value, region_name):
    ec2 = boto3.client('ec2', region_name=region_name)
    # client.meta.config.connect_timeout = 5
    # client.meta.config.read_timeout = 5
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
            print("achou dns publico")
        else:
            EC2TargetDNS.append(private_dns)
            print("achou dns privado")
    else:
        break
    i += 1
print(f"EC2 Target Total: {i} {EC2TargetName}")

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
print(f"EFS Target Total: {i} {EFSNameList}")

# **************Inicializa SSM Parameter*********************************
SSMParameterTargetName = []
SSMParameterTargetRegion = []
i = 0

while True:
    # Obtém o nome e a região do parâmetro a partir das variáveis de ambiente
    Name = os.getenv(f"aws_ssm_parameter_Target_Name_{str(i)}")
    Region = os.getenv(f"aws_ssm_parameter_Target_Region_{str(i)}")

    # Verifica se o nome do parâmetro foi encontrado
    if Name is not None and Region is not None:
        SSMParameterTargetName.append(Name)
        SSMParameterTargetRegion.append(Region)
    else:
        # Encerra o loop se não encontrar mais parâmetros
        SSMParameterMaxNumber = i
        break
    i += 1
print(f"SSM Parameter Target Total: {i} {SSMParameterTargetName}")

# ***************************Resources Source***********************************

# *****************Identifica a URL de cada SQS Source*************************
SQSSourceMaxNumber = 4
SQSSourceName = []
i = 0
while True:
    Name = os.getenv(f"aws_sqs_queue_Source_Name_{str(i)}")
    if Name != None:
        SQSSourceName.append(Name)
    else:
        SQSSourceMaxNumber = i
        break
    i += 1
print(f"SQS Source Total: {i} {SQSSourceName}")

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
print(f"SNS Source Total: {i} {SNSSourceName}")

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
print(f"S3 Notification Source Total: {i} {S3BucketSourceName}")

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
print(f"Secret Source Total: {i} {SecretNameList}")

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
        print("Conexão ao MySQL DB bem-sucedida")
    except MySQLError as e:
        print(f"O erro '{e}' ocorreu")
    return connection


def execute_query(connection, query, values=None):
    with connection.cursor() as cursor:
        try:
            if values:
                cursor.execute(query, values)
            else:
                cursor.execute(query)
            connection.commit()
            print("Query executada com sucesso")
        except MySQLError as e:
            print(f"O erro '{e}' ocorreu")


# ******************* inicializa Lista para armazenar as conexões RDS e criação de tabela.
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
            print(f"database e endpoint {i} : {database}, {Host}, {username}")
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
                print(f"Passou aqui A")
        else:
            print(f"Total RDS Targets: {i}")
            break
        i += 1

# ******************************************************************************


def lambda_handler(event, context):
    # print("context", context)
    print("Event:", event)
    Information = "Source unknown!!"
    Message = "No Message!!"
    if 'CodePipeline.job' in event:
        EventSource = "aws:codepipeline"
    elif 'Records' in event:
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
        Information = "Message from SNS "+SNSName
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
        print("bucket_name", bucket_name, file_path)
        # lê o conteúdo do arquivo
        if Ext == "txt":
            response = execute_with_xray(
                bucket_name, s3.get_object, Bucket=bucket_name, Key=file_path)
            Message = response['Body'].read().decode('utf-8')
            # print("File Content: ",file_content)
        else:
            Message = "File is not .txt"
        Information = "File "+file_path+" from S3 bucket " + \
            bucket_name + ", with size of "+FileSize
    elif 'requestContext' in event and 'elb' in event['requestContext']:
        EventSource = "aws:elb"
        ALBName = event['requestContext']['elb']['targetGroupArn'].split(
            ":")[-1]
        Message = "HTTP request from ALB"
        Information = "Request from ALB " + ALBName
    elif 'CodePipeline.job' in event:
        EventSource = "aws:codepipeline"
        job_id = event['CodePipeline.job']['id']
        Message = "Job ID: " + job_id
        Information = "Event from CodePipeline"
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

    print("Source of Event: ", EventSource)
    Agora = datetime.datetime.now()
    NewMessage = f"Lambda: {LambdaName}. Source: {EventSource}. Date/Time: {str(Agora)}. <- {Message}"
    print("Message to be sent: ", NewMessage)

    # *************************Bloco SQS**************************************
    # Define o nome da fila para envio da mensagem
    for i in range(SQSTargetMaxNumber):
        message_body = NewMessage
        response = execute_with_xray(
            SQSTargetName[i], sqs.send_message, QueueUrl=QueueTargetUrl[i], MessageBody=message_body)
        print('Mensagem SQS' + str(i) +
              ' enviada com ID:', response['MessageId'])

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
        ID = LambdaName + ":" + str(Agora)
        put_item_response = execute_with_xray(TableName, Table.put_item, Item={
                                              'ID': ID, "Message": NewMessage})
        print("DynamDB response", put_item_response)

    # *************************Bloco SNS**********************************
    for i in range(SNSTargetMaxNumber):
        topic_arn = TopicTargetARN[i]
        message = NewMessage
        response = execute_with_xray(topic_arn, sns.publish,  TopicArn=topic_arn,
                                     Message=json.dumps({'default': json.dumps(message)}), MessageStructure='json')
        print("Response SNS", response)

    # *************************Bloco Lambda ********************
    lambda_client = boto3.client('lambda')
    for function_name in LambdaNameList:
        response = execute_with_xray(function_name, lambda_client.invoke, FunctionName=function_name,
                                     InvocationType='Event', Payload=json.dumps({"message": NewMessage, "source": "aws:lambda"}))
        if response.get('StatusCode') == 202:
            print(f"Invoke lambda: {function_name}")
        else:
            print(f'Invokation error {function_name}.')

    # *************************Bloco S3**********************************
    for i in range(S3TargetMaxNumber):
        bucket_name = S3BucketTargetName[i]
        folder_name = LambdaName+"/"
        file_name = LambdaName + ":" + str(Agora) + ".txt"
        file_content = NewMessage
        file_path = folder_name + file_name
        response = execute_with_xray(
            bucket_name, s3.put_object, Bucket=bucket_name, Key=file_path, Body=file_content)
        print(f"Objeto inserido na bucket '{bucket_name}'")

    # *************************Bloco EFS **********************************
    for efs_mount_path in EFSList:
        # Escreva um arquivo de teste no EFS
        file_name = LambdaName + ":" + str(Agora) + ".txt"
        test_file_path = os.path.join(efs_mount_path, file_name)
        with open(test_file_path, "w") as file:
            file.write(NewMessage)

    for connection, db_name in RDSConnections:
        insert_query = "INSERT INTO exemplo (texto) VALUES (%s)"
        try:
            Data = json.dumps(NewMessage)
            execute_query(connection, insert_query, (Data,))
            print(
                f"Item inserido na tabela 'exemplo' do banco de dados '{db_name}'")
        except MySQLError as e:
            print(f"Erro ao inserir item no banco de dados '{db_name}': {e}")

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
            print(f"SSM PArameter {Name} updated: {new_value}")
        except Exception as e:
            print(
                f"Erro ao processar o parâmetro {Name} na região {region}: {e}")

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
                print(f'Message sent with Success to {EC2Name}.')
            else:
                print(
                    f'Message sent error to {EC2Name}. Código : {Response.status}')
            Conn.close()
        except Exception as e:
            print(f'Message sent error {EC2Name}: {str(e)}')

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

    # *************************Retorno CodePipeline **********************************
    if EventSource == "aws:codepipeline":
        print("aws:codepipeline")
        # Temporary Credentials and get object from S3
        credentials = event['CodePipeline.job']['data']['artifactCredentials']
        access_key = credentials['accessKeyId']
        secret_key = credentials['secretAccessKey']
        session_token = credentials['sessionToken']
        s3 = boto3.client('s3',
                          aws_access_key_id=access_key,
                          aws_secret_access_key=secret_key,
                          aws_session_token=session_token)
        # Obter os artefatos de entrada e saída
        input_artifacts = event['CodePipeline.job']['data']['inputArtifacts']
        output_artifacts = event['CodePipeline.job']['data']['outputArtifacts']
        print("input_artifacts", input_artifacts, output_artifacts)

        # Processar apenas o primeiro artefato de entrada
        if input_artifacts:
            artifact = input_artifacts[0]
            artifact_location = artifact['location']['s3Location']
            bucket = artifact_location['bucketName']
            key = artifact_location['objectKey']

            # Verificar se o arquivo é um arquivo de texto
            if key.endswith(".txt"):
                # Ler o conteúdo do arquivo
                response = s3.get_object(Bucket=bucket, Key=key)
                file_content = response['Body'].read().decode('utf-8')
                print(f"File content from {key}: {file_content}")

                # Converter o conteúdo do arquivo para maiúsculas
                upper_case_content = file_content.upper()

                # Salvar o arquivo modificado de volta no bucket S3 com o nome do primeiro artefato de saída
                if output_artifacts:
                    output = output_artifacts[0]
                    output_location = output['location']['s3Location']
                    output_bucket = output_location['bucketName']
                    output_key = output_location['objectKey']

                    # Salvar o arquivo modificado de volta no bucket S3 com o nome do artefato de saída
                    s3.put_object(Bucket=output_bucket, Key=output_key,
                                  Body=upper_case_content.encode('utf-8'))
                    print(f"Modified file saved to {output_key}")
        # Send success result to CodePipeline
        codepipeline = boto3.client('codepipeline')
        codepipeline.put_job_success_result(jobId=job_id)
        return {
            'statusCode': 200,
            'body': json.dumps({
                'status': 'SUCCESS',
            })
        }

    # *************************Bloco CodeBuild ********************
    codebuild = boto3.client('codebuild')
    environment_variables = [
        {'name': 'EVENT', 'value': NewMessage, 'type': 'PLAINTEXT'}]
    for CodeBuildName in CodeBuildNameList:
        response = execute_with_xray(CodeBuildName, codebuild.start_build, projectName=CodeBuildName,
                                     environmentVariablesOverride=environment_variables)
