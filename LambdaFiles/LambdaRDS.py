import os
import boto3
from botocore.exceptions import ClientError


def lambda_handler(event, context):
    # Lê as variáveis de ambiente
    LAMBDA_NAME = os.environ.get('LAMBDA_NAME')
    REGION = os.environ.get('REGION')
    ACCOUNT = os.environ.get('ACCOUNT')
    SSM_PARAMETER_SOURCE_NAME = os.environ.get(
        'AWS_SSM_PARAMETER_SOURCE_NAME_')
    SSM_PARAMETER_SOURCE_REGION = os.environ.get(
        'AWS_SSM_PARAMETER_SOURCE_REGION_')
    SECRET_ARN = os.environ.get(
        'AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_')

    print("SSM_PARAMETER_SOURCE_NAME:",
          SSM_PARAMETER_SOURCE_NAME, SSM_PARAMETER_SOURCE_REGION)
    print("SECRET_ARN:", SECRET_ARN)

    # Cria um cliente do Secrets Manager
    client = boto3.client('secretsmanager', region_name=REGION)

    try:
        # Obtém o valor do segredo
        response = client.get_secret_value(SecretId=SECRET_ARN)
        print("response:", response)
        secret = response['SecretString']

        return {
            'statusCode': 200,
            'body': secret
        }
    except ClientError as e:
        print(f"Erro ao acessar o segredo: {e}")
        return {
            'statusCode': 500,
            'body': 'Erro ao acessar o segredo'
        }
