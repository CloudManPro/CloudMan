import json
import boto3

# Inicializa os clientes Boto3
s3_client = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')
sqs_client = boto3.client('sqs')

# Defina os parâmetros de sua tabela DynamoDB e fila SQS
DYNAMODB_TABLE = 'SuaTabelaDynamoDB'
SQS_QUEUE_URL = 'https://sqs.us-east-1.amazonaws.com/123456789012/SuaFilaSQS'


def lambda_handler(event, context):
    # Obter o nome do bucket e a chave do arquivo do evento S3
    bucket_name = event['Records'][0]['s3']['bucket']['name']
    file_key = event['Records'][0]['s3']['object']['key']

    # Baixar o arquivo do S3
    response = s3_client.get_object(Bucket=bucket_name, Key=file_key)
    file_content = response['Body'].read().decode('utf-8')

    # Contar letras maiúsculas
    uppercase_count = sum(1 for c in file_content if c.isupper())

    # Salvar resultado no DynamoDB
    table = dynamodb.Table(DYNAMODB_TABLE)
    table.put_item(
        Item={
            'FileName': file_key,
            'UppercaseCount': uppercase_count
        }
    )

    # Enviar uma mensagem para o SQS com o resultado
    message = {
        'FileName': file_key,
        'UppercaseCount': uppercase_count
    }
    sqs_client.send_message(
        QueueUrl=SQS_QUEUE_URL,
        MessageBody=json.dumps(message)
    )

    return {
        'statusCode': 200,
        'body': json.dumps(f'Processamento concluído para o arquivo {file_key}.')
    }
