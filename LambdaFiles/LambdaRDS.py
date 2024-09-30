import os
import boto3
from botocore.exceptions import ClientError

def lambda_handler(event, context):
    # Lê as variáveis de ambiente
    lambda_name = os.environ.get('LambdaName')
    region = os.environ.get('Region')
    account = os.environ.get('Account')
    aws_ssm_parameter_Source_Name = os.environ.get('aws_ssm_parameter_Source_Name_')
    aws_ssm_parameter_Source_Region = os.environ.get('aws_ssm_parameter_Source_Region_')
    secret_arn = os.environ.get('aws_secretsmanager_secret_version_Source_ARN_')
    print("aws_ssm_parameter_Source_Name: ",aws_ssm_parameter_Source_Name, aws_ssm_parameter_Source_Region)
    print("secret_arn",secret_arn)
    # Cria um cliente do Secrets Manager
    client = boto3.client('secretsmanager', region_name=region)

    try:
        # Obtém o valor do segredo
        response = client.get_secret_value(SecretId=secret_arn)
        print("response",response)
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
