import traceback
import boto3
import os
import json
import datetime
import http.client
from urllib.parse import unquote

try:
    from aws_xray_sdk.core import xray_recorder
    from aws_xray_sdk.core import patch_all
    # Enable automatic X-Ray tracing
    patch_all()
    xray_enabled = True
except:
    xray_enabled = False
    print("XRay SDK not found!")
XRay = os.getenv('XRAY_ENABLED', "False")
if XRay == "False":
    xray_enabled = False

try:
    import pymysql
    from pymysql import MySQLError
    MySQLEnabled = True
except:
    MySQLEnabled = False
    print("Pymysql not found!")

# Create clients to access AWS services

Region = os.getenv("REGION")
AccountID = os.getenv("ACCOUNT")
sqs = boto3.client('sqs', region_name=Region)
dynamodb = boto3.resource('dynamodb', region_name=Region)
lambda_client = boto3.client('lambda', region_name=Region)
sns = boto3.client('sns', region_name=Region)
s3 = boto3.client('s3')
LambdaName = os.getenv("LAMBDA_NAME")


# Assuming that xray_enabled is a previously defined boolean variable
# and that you have already configured X-Ray (for example, with xray_recorder.configure(...))

def execute_with_xray(segment_name, function, *args, **kwargs):
    """
    Executes a function. If the function is for SQS (send_message), it executes within an X-Ray subsegment;
    for other services, it executes the function normally, as they already have X-Ray integration.

    :param segment_name: Name of the subsegment (used only for SQS).
    :param function: Function to be executed.
    :param args: Positional arguments for the function.
    :param kwargs: Keyword arguments for the function.
    :return: Result of the executed function.
    """
    # If the function is SQS send_message, wrap it with a subsegment
    if function.__name__ == 'send_message':
        if xray_enabled:
            with xray_recorder.in_subsegment(segment_name) as subsegment:
                try:
                    result = function(*args, **kwargs)
                    # Add annotation with the queue URL, if available
                    if "QueueUrl" in kwargs:
                        subsegment.put_annotation(
                            "QueueUrl", kwargs["QueueUrl"])
                    return result
                except Exception as e:
                    subsegment.add_exception(e, traceback.format_exc())
                    raise
        else:
            return function(*args, **kwargs)
    else:
        # For other services, simply execute the function normally
        return function(*args, **kwargs)


# *************************** Target Resources ***********************************

# **************** Identify the URL of each SQS Target ***************************
SQSTargetMaxNumber = 0
SQSTargetName = []
QueueTargetUrl = []
Name = ""
i = 0
while True:
    Name = os.getenv(f"AWS_SQS_QUEUE_TARGET_NAME_{str(i)}")
    Region = os.getenv(f"AWS_SQS_QUEUE_TARGET_REGION_{str(i)}")
    URL = os.getenv(f"AWS_SQS_QUEUE_TARGET_URL_{str(i)}")
    if Name != None:
        SQSTargetName.append(Name)
        QueueTargetUrl.append(URL)
    else:
        SQSTargetMaxNumber = i
        break
    i += 1
print(f"Total SQS Targets: {i} {SQSTargetName}")

# ********** Identify the ARN of each SNS Target **************************
SNSTargetMaxNumber = 0
SNSTargetName = []
TopicTargetARN = []

i = 0
while True:
    Name = os.getenv(f"AWS_SNS_TOPIC_TARGET_NAME_{str(i)}")
    Region = os.getenv(f"AWS_SNS_TOPIC_TARGET_REGION_{str(i)}")
    ARN = os.getenv(f"AWS_SNS_TOPIC_TARGET_ARN_{str(i)}")
    if Name != None:
        SNSTargetName.append(Name)
        TopicTargetARN.append(ARN)
    else:
        SNSTargetMaxNumber = i
        break
    i += 1
print(f"Total SNS Targets: {i} {SNSTargetName}")

# ************** Initialize each DynamoDB table *********************************
DynamoDBTargetMaxNumber = 0
TableNameTargetList = []
ListDynamo = []
i = 0
while True:
    TableName = os.getenv(f"AWS_DYNAMODB_TABLE_TARGET_NAME_{str(i)}")
    Region = os.getenv(f"AWS_DYNAMODB_TABLE_TARGET_REGION_{str(i)}")
    Account = os.getenv(f"AWS_DYNAMODB_TABLE_TARGET_ACCOUNT_{str(i)}")
    if TableName != None:
        TableNameTargetList.append([dynamodb.Table(TableName), TableName])
        ListDynamo.append(TableName)
        Table = TableNameTargetList[i][0]
        response = Table.get_item(Key={'ID': "1"})
        if 'Item' not in response:
            Table.put_item(
                Item={'ID': "1", "LambdaName": "Created by " + LambdaName, 'Cont': 0})
    else:
        DynamoDBTargetMaxNumber = i
        break
    i += 1
print(f"Total DynamoDB Targets: {i} {ListDynamo}")

# ************* Initialize each Lambda to be invoked ***************************
LambdaMaxNumber = 0
LambdaNameList = []
i = 0
while True:
    Name = os.getenv(f"AWS_LAMBDA_FUNCTION_TARGET_NAME_{str(i)}")
    Region = os.getenv(f"AWS_LAMBDA_FUNCTION_TARGET_REGION_{str(i)}")
    Account = os.getenv(f"AWS_LAMBDA_FUNCTION_TARGET_ACCOUNT_{str(i)}")
    if Name != None:
        LambdaNameList.append(Name)
        LambdaMaxNumber = i
    else:
        break
    i += 1
print(f"Total Lambda Targets: {i} {LambdaNameList}")

# ************* Initialize each CodeBuild target ***************************
CodeBuildMaxNumber = 0
CodeBuildNameList = []
i = 0
while True:
    Name = os.getenv(f"AWS_CODEBUILD_PROJECT_TARGET_NAME_{str(i)}")
    Region = os.getenv(f"AWS_CODEBUILD_PROJECT_TARGET_REGION_{str(i)}")
    Account = os.getenv(f"AWS_CODEBUILD_PROJECT_TARGET_ACCOUNT_{str(i)}")
    if Name is not None:
        CodeBuildNameList.append(Name)
        CodeBuildMaxNumber = i
    else:
        break
    i += 1
print(f"Total CodeBuild Targets: {i} {CodeBuildNameList}")

# ********** Identify each S3 target **************************
S3TargetMaxNumber = 0
S3BucketTarget = []
i = 0
while True:
    Name = os.getenv(f"AWS_S3_BUCKET_TARGET_NAME_{str(i)}")
    Region = os.getenv(f"AWS_S3_BUCKET_TARGET_REGION_{str(i)}")
    Account = os.getenv(f"AWS_S3_BUCKET_TARGET_ACCOUNT_{str(i)}")
    if Name is not None:
        S3BucketTarget.append([Name, Region])
    else:
        S3TargetMaxNumber = i
        break
    i += 1
print(f"Total S3 Targets: {i} ")

# ********** Identify EC2 targets **************************
EC2TargetDNS = []
EC2TargetName = []
i = 0
while True:
    Name = os.getenv(f"AWS_INSTANCE_TARGET_NAME_{str(i)}")
    Region = os.getenv(f"AWS_INSTANCE_TARGET_REGION_{str(i)}")
    if Name is not None:
        public_dns, private_dns = find_ec2_dns_by_tag('Name', Name, Region)
        EC2TargetName.append(Name)
        if public_dns is not None:
            EC2TargetDNS.append(public_dns)
            print("Found public DNS")
        else:
            EC2TargetDNS.append(private_dns)
            print("Found private DNS")
    else:
        break
    i += 1
print(f"Total EC2 Targets: {i} {EC2TargetName}")

# ************** Initialize EFS *********************************
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
        EFSMaxNumber = i
        break
    i += 1
print(f"Total EFS Targets: {i} {EFSNameList}")

# ************** Initialize SSM Parameter *********************************
SSMParameterTargetName = []
SSMParameterTargetRegion = []
i = 0
while True:
    Name = os.getenv(f"AWS_SSM_PARAMETER_TARGET_NAME_{str(i)}")
    Region = os.getenv(f"AWS_SSM_PARAMETER_TARGET_REGION_{str(i)}")

    if Name is not None and Region is not None:
        SSMParameterTargetName.append(Name)
        SSMParameterTargetRegion.append(Region)
    else:
        SSMParameterMaxNumber = i
        break
    i += 1
print(f"Total SSM Parameters: {i} {SSMParameterTargetName}")

# *************************** Source Resources ***********************************

# ***************** Identify the URL of each SQS Source *************************
SQSSourceMaxNumber = 4
SQSSourceName = []
i = 0
while True:
    Name = os.getenv(f"AWS_SQS_QUEUE_SOURCE_NAME_{str(i)}")
    if Name is not None:
        SQSSourceName.append(Name)
    else:
        SQSSourceMaxNumber = i
        break
    i += 1
print(f"Total SQS Sources: {i} {SQSSourceName}")

# ********** Identify the ARN of each SNS Source **************************
SNSSourceMaxNumber = 4
SNSSourceName = []
i = 0
while True:
    Name = os.getenv(f"AWS_SNS_TOPIC_SOURCE_NAME_{str(i)}")
    Region = os.getenv(f"AWS_SNS_TOPIC_SOURCE_REGION_{str(i)}")
    Account = os.getenv(f"AWS_SNS_TOPIC_SOURCE_ACCOUNT_{str(i)}")
    if Name is not None:
        SNSTargetName.append(Name)
    else:
        SNSSourceMaxNumber = i
        break
    i += 1
print(f"Total SNS Sources: {i} {SNSSourceName}")

# ********** Identify each S3 Source **************************
S3SourceMaxNumber = 4
S3BucketSourceName = []
i = 0
while True:
    Name = os.getenv(f"AWS_S3_BUCKET_SOURCE_NAME_{str(i)}")
    if Name is not None:
        S3BucketSourceName.append(Name)
    else:
        S3SourceMaxNumber = i
        break
    i += 1
print(f"Total S3 Notification Sources: {i} {S3BucketSourceName}")

# ********* List to store username and password information for each secret
SecretsCredentials = []
SecretNameList = []
i = 0
while True:
    SecretName = os.getenv(
        f"AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_{i}")
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


# ******************* Initialize list to store RDS connections and create table. *******************
RDSConnections = []
i = 0
if MySQLEnabled:
    while True:
        database = os.getenv(f"AWS_DB_INSTANCE_TARGET_NAME_{i}")
        if database is not None:
            EndPoint = os.getenv(f"AWS_DB_INSTANCE_TARGET_ENDPOINT_{i}")
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
            print(
                f"Database and endpoint {i} : {database}, {Host}, {username}")
            # Establish the connection and create the table
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
                print(f"Checkpoint A passed")
        else:
            print(f"Total RDS Targets: {i}")
            break
        i += 1

# ******************************************************************************


def lambda_handler(event, context):
    print("event", event)
    # print("context", context)
    try:
        EventSource = event['Records'][0]['source']
    except Exception as e:
        EventSource = "API"
    if 'CodePipeline.job' in event:
        EventSource = "aws:codepipeline"
    elif 'source' in event:
        EventSource = event['source']
    Subject = "None"
    Message = ""
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
    elif EventSource == "aws.events":
        EBName = event['resources'][0].split("/")[-1]
        Message = f"Event from {EBName}"
        Information = f"Message from EventBridge {EBName}"
    elif EventSource == "aws:lambda":
        SourceLambdaName = "Lambda"
        Information = "Event from Lambda"
        Message = event["message"]
        print("Message", Message)
    elif EventSource == "aws:s3":
        s3 = boto3.client('s3')
        EventSource += event['Records'][0]['s3']["bucket"]['arn'].split(":")[-1]
        FileSize = str(event['Records'][0]['s3']['object']["size"])
        bucket_name = event['Records'][0]['s3']['bucket']["name"]
        file_path_encoded = event['Records'][0]['s3']['object']["key"]
        # Decode the file name
        file_path = unquote(file_path_encoded).replace('+', ' ')
        Ext = file_path.split(".")[-1]
        print("bucket_name", bucket_name, file_path)
        # Read the file content
        if Ext == "txt":
            response = execute_with_xray(
                bucket_name, s3.get_object, Bucket=bucket_name, Key=file_path)
            Message = response['Body'].read().decode('utf-8')
            # print("File Content: ",file_content)
        else:
            Message = "File is not .txt"
        Information = "File " + file_path + " from S3 bucket " + \
            bucket_name + ", with size of " + FileSize
    elif 'requestContext' in event and 'elb' in event['requestContext']:
        EventSource = "aws:elb"
        ALBName = event['requestContext']['elb']['targetGroupArn'].split(":")[-1]
        Message = "HTTP request from ALB"
        Information = "Request from ALB " + ALBName
    elif 'CodePipeline.job' in event:
        EventSource = "aws:codepipeline"
        job_id = event['CodePipeline.job']['id']
        Message = "Job ID: " + job_id
        Information = "Event from CodePipeline"
    elif EventSource == "AWS:EC2":
        Information = "Event from EC2"
        EventSource = "EC2"
        Message = event["message"]
        print("Message XXX", Message)
    elif EventSource == "API":
        Subject = "None"
        try:
            Source = event["source"]
            Message = str(event["message"])
        except:
            Source = "API"
            Message = str(event)
        else:
            Information = "Event from API"

    print("Source of Event: ", EventSource)
    if LambdaName in Message:
        print("Loop Found!")
        return
    Agora = datetime.datetime.now()
    NewMessage = f"Lambda: {LambdaName}. Source: {EventSource}. Date/Time: {str(Agora)}. <- {Message}"
    print("Message to be sent: ", NewMessage)

    # ************************* SQS Block **************************************
    # Define the queue name for sending the message
    for i in range(SQSTargetMaxNumber):
        message_body = NewMessage
        print("Sending message to queue:",
              SQSTargetName[i], "with QueueUrl:", QueueTargetUrl[i])
        response = execute_with_xray(
            # Subsegment name (can be the queue name)
            SQSTargetName[i],
            # Function to be executed (sending the message)
            sqs.send_message,
            QueueUrl=QueueTargetUrl[i],  # Named parameter for the queue URL
            MessageBody=message_body    # Message body
        )
        print('SQS message ' + str(i) +
              ' sent with ID:', response['MessageId'])
    # ************************* DynamoDB Block **********************************
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
        print("DynamoDB response", put_item_response)

    # ************************* SNS Block **********************************
    for i in range(SNSTargetMaxNumber):
        topic_arn = TopicTargetARN[i]
        message = NewMessage
        response = execute_with_xray(topic_arn, sns.publish, TopicArn=topic_arn,
                                     Message=json.dumps({'default': json.dumps(message)}), MessageStructure='json')
        print("SNS response", response)

    # ************************* Lambda Block ********************
    lambda_client = boto3.client('lambda')
    for function_name in LambdaNameList:
        response = execute_with_xray(function_name, lambda_client.invoke, FunctionName=function_name,
                                     InvocationType='Event', Payload=json.dumps({"message": NewMessage, "source": "aws:lambda"}))
        if response.get('StatusCode') == 202:
            print(f"Invoked lambda: {function_name}")
        else:
            print(f"Invocation error for {function_name}.")
    # ************************* S3 Block **********************************
    for i in range(S3TargetMaxNumber):
        bucket_name = S3BucketTarget[i][0]
        S3Region = S3BucketTarget[i][1]
        s3 = boto3.client('s3', region_name=S3Region)
        folder_name = LambdaName + "/"
        file_name = LambdaName + ":" + str(Agora) + ".txt"
        file_content = NewMessage
        file_path = folder_name + file_name
        response = execute_with_xray(
            bucket_name, s3.put_object, Bucket=bucket_name, Key=file_path, Body=file_content)
        print(f"Object inserted in bucket '{bucket_name}'")

    # ************************* EFS Block **********************************
    for efs_mount_path in EFSList:
        # Write a test file to EFS
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
                f"Item inserted into table 'exemplo' of database '{db_name}'")
        except MySQLError as e:
            print(f"Error inserting item into database '{db_name}': {e}")

    # ************************* SSM Parameter Block **********************************
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
            print(f"SSM Parameter {Name} updated: {new_value}")
        except Exception as e:
            print(f"Error processing parameter {Name} in region {region}: {e}")

    # ************************* EC2 Block **********************************
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
                print(f'Message sent with success to {EC2Name}.')
            else:
                print(
                    f'Error sending message to {EC2Name}. Code: {Response.status}')
            Conn.close()
        except Exception as e:
            print(f'Error sending message {EC2Name}: {str(e)}')

    # ************************* ALB Response **********************************
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

    # ************************* API Response **********************************
    if EventSource == "API":
        return NewMessage

    # ************************* CodePipeline Response **********************************
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
        # Get input and output artifacts
        input_artifacts = event['CodePipeline.job']['data']['inputArtifacts']
        output_artifacts = event['CodePipeline.job']['data']['outputArtifacts']
        print("input_artifacts", input_artifacts, output_artifacts)

        # Process only the first input artifact
        if input_artifacts:
            artifact = input_artifacts[0]
            artifact_location = artifact['location']['s3Location']
            bucket = artifact_location['bucketName']
            key = artifact_location['objectKey']

            # Check if the file is a text file
            if key.endswith(".txt"):
                # Read the file content
                response = s3.get_object(Bucket=bucket, Key=key)
                file_content = response['Body'].read().decode('utf-8')
                print(f"File content from {key}: {file_content}")

                # Convert the file content to uppercase
                upper_case_content = file_content.upper()

                # Save the modified file back to the S3 bucket with the name of the first output artifact
                if output_artifacts:
                    output = output_artifacts[0]
                    output_location = output['location']['s3Location']
                    output_bucket = output_location['bucketName']
                    output_key = output_location['objectKey']

                    # Save the modified file back to the S3 bucket with the output artifact name
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

    # ************************* CodeBuild Block ********************
    codebuild = boto3.client('codebuild')
    environment_variables = [
        {'name': 'EVENT', 'value': NewMessage, 'type': 'PLAINTEXT'}]
    for CodeBuildName in CodeBuildNameList:
        response = execute_with_xray(CodeBuildName, codebuild.start_build, projectName=CodeBuildName,environmentVariablesOverride=environment_variables)
