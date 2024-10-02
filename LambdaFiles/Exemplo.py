import json
import boto3
import logging

# Inicializa os clientes Boto3
S3_CLIENT = boto3.client('s3')
DYNAMODB = boto3.resource('dynamodb')
SQS_CLIENT = boto3.client('sqs')

# Defina os parâmetros de sua tabela DynamoDB e fila SQS
DYNAMODB_TABLE = 'SUA_TABELA_DYNAMODB'
SQS_QUEUE_URL = 'https://sqs.us-east-1.amazonaws.com/123456789012/SUA_FILA_SQS'

# Configuração de logging
LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)


def lambda_handler(event, context):
    try:
        # Obter o nome do bucket e a chave do arquivo do evento S3
        BUCKET_NAME = event['Records'][0]['s3']['bucket']['name']
        FILE_KEY = event['Records'][0]['s3']['object']['key']

        LOGGER.info(f"Processando arquivo {FILE_KEY} do bucket {BUCKET_NAME}")

        # Baixar o arquivo do S3
        response = S3_CLIENT.get_object(Bucket=BUCKET_NAME, Key=FILE_KEY)
        file_content = response['Body'].read().decode('utf-8')

        # Contar letras maiúsculas
        UPPERCASE_COUNT = sum(1 for c in file_content if c.isupper())

        # Salvar resultado no DynamoDB
        table = DYNAMODB.Table(DYNAMODB_TABLE)
        table.put_item(
            Item={
                'FileName': FILE_KEY,
                'UppercaseCount': UPPERCASE_COUNT
            }
        )

        LOGGER.info(
            f"Resultado salvo no DynamoDB para o arquivo {FILE_KEY}: {UPPERCASE_COUNT} letras maiúsculas.")

        # Enviar uma mensagem para o SQS com o resultado
        MESSAGE = {
            'FileName': FILE_KEY,
            'UppercaseCount': UPPERCASE_COUNT
        }
        SQS_CLIENT.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=json.dumps(MESSAGE)
        )

        LOGGER.info(f"Mensagem enviada para o SQS para o arquivo {FILE_KEY}.")

        return {
            'statusCode': 200,
            'body': json.dumps(f'Processamento concluído para o arquivo {FILE_KEY}.')
        }

    except Exception as e:
        LOGGER.error(f"Erro ao processar o arquivo {FILE_KEY}: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps(f'Erro ao processar o arquivo {FILE_KEY}.')
        }
