import boto3
import os
import json
import urllib.request
import urllib.error
from datetime import datetime, timezone

# --- Funções Auxiliares (sem alterações) ---
# ... (todas as suas funções auxiliares `get_pipeline_status`, `format_pipeline_report`, etc., permanecem as mesmas) ...
def get_pipeline_status(codepipeline_client, pipeline_name):
    """Busca o estado mais recente de um AWS CodePipeline."""
    try:
        pipeline_state = codepipeline_client.get_pipeline_state(name=pipeline_name)
        return pipeline_state
    except Exception as e:
        print(f"Erro ao buscar estado do CodePipeline: {e}")
        raise

def format_pipeline_report(state):
    """Formata os dados do pipeline em um relatório de texto legível."""
    report_lines = []
    pipeline_name = state.get('pipelineName', 'N/A')
    pipeline_version = state.get('pipelineVersion', 'N/A')
    
    overall_status = "N/A"
    if state.get('stageStates'):
        for stage in reversed(state['stageStates']):
            if stage.get('latestExecution'):
                overall_status = stage['latestExecution'].get('status', 'N/A')
                break

    report_lines.append("="*60)
    report_lines.append("        Relatório de Execução do AWS CodePipeline")
    report_lines.append("="*60)
    report_lines.append(f"\nPipeline: {pipeline_name} (Versão: {pipeline_version})")
    report_lines.append(f"Status Geral: {overall_status}")

    created_time = state.get('created')
    updated_time = state.get('updated')
    if created_time and updated_time:
        duration = updated_time - created_time
        total_seconds = duration.total_seconds()
        minutes, seconds = divmod(total_seconds, 60)
        report_lines.append(f"Início da Execução: {created_time.astimezone(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')} (UTC)")
        report_lines.append(f"Última Atualização: {updated_time.astimezone(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')} (UTC)")
        report_lines.append(f"Duração Total: {int(minutes)} minutos e {int(seconds)} segundos\n")

    for stage in state.get('stageStates', []):
        stage_name = stage.get('stageName', 'Estágio Desconhecido')
        report_lines.append("-" * 60)
        report_lines.append(f"▶ Estágio: {stage_name}")
        report_lines.append("-" * 60)

        for action in stage.get('actionStates', []):
            action_name = action.get('actionName', 'Ação Desconhecida')
            report_lines.append(f"  - Ação: {action_name}")
            latest_exec = action.get('latestExecution')
            if latest_exec:
                report_lines.append(f"    - Status: {latest_exec.get('status', 'N/A')}")
                report_lines.append(f"    - Sumário: {latest_exec.get('summary', 'Sem sumário.')}")
                if latest_exec.get('lastStatusChange'):
                    report_lines.append(f"    - Horário: {latest_exec.get('lastStatusChange').astimezone(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')} (UTC)")
                if latest_exec.get('externalExecutionUrl'):
                    report_lines.append(f"    - Link para Detalhes: {latest_exec.get('externalExecutionUrl')}")
            else:
                report_lines.append("    - Status: Informação não disponível nesta execução.")
            report_lines.append("")
            
    return "\n".join(report_lines), overall_status, pipeline_name

def get_url_from_ssm(ssm_client, parameter_name):
    """Obtém um valor de domínio de um parâmetro JSON no AWS SSM."""
    try:
        response = ssm_client.get_parameter(Name=parameter_name, WithDecryption=True)
        parameter_value_str = response['Parameter']['Value']
        resources_data = json.loads(parameter_value_str)
        for resource in resources_data:
            if resource.get("ResourceType") == "aws_route53_zone":
                domain = resource.get("Domain")
                if domain: return domain
        raise ValueError("Recurso 'aws_route53_zone' com 'Domain' não encontrado no SSM.")
    except Exception as e:
        print(f"Erro ao buscar parâmetro do SSM: {e}")
        raise

def fetch_url_content(url):
    """Acessa uma URL e retorna seu conteúdo como string."""
    full_url = f"https://{url}"
    print(f"Acessando a URL: {full_url}")
    try:
        with urllib.request.urlopen(full_url, timeout=10) as response:
            return response.read().decode('utf-8')
    except Exception as e:
        error_message = f"Falha ao acessar a URL {full_url}. Erro: {str(e)}"
        print(error_message)
        return error_message

def upload_to_s3(s3_client, bucket_name, file_name, content_string):
    """Faz upload de uma string de texto para um bucket S3."""
    try:
        s3_client.put_object(
            Bucket=bucket_name,
            Key=file_name,
            Body=content_string,
            ContentType='text/plain; charset=utf-8'
        )
        print(f"Relatório '{file_name}' salvo com sucesso no bucket '{bucket_name}'.")
    except Exception as e:
        print(f"Erro ao salvar no S3: {e}")
        raise

def publish_to_sns(sns_client, topic_arn, subject, message):
    """Publica uma mensagem em um tópico SNS."""
    try:
        sns_client.publish(
            TopicArn=topic_arn,
            Subject=subject,
            Message=message
        )
        print(f"Notificação enviada com sucesso para o tópico SNS: {topic_arn}")
    except Exception as e:
        print(f"Erro ao enviar notificação para o SNS: {e}")

def put_job_success(codepipeline_client, job_id, message):
    """Notifica o CodePipeline que o job foi concluído com sucesso."""
    print("Notificando o CodePipeline sobre o sucesso do job.")
    codepipeline_client.put_job_success_result(jobId=job_id)

def put_job_failure(codepipeline_client, job_id, message):
    """Notifica o CodePipeline que o job falhou."""
    print(f"Notificando o CodePipeline sobre a falha do job: {message}")
    codepipeline_client.put_job_failure_result(
        jobId=job_id,
        failureDetails={'message': message, 'type': 'JobFailed'}
    )


def lambda_handler(event, context):
    # ADICIONADO: Verificação robusta para garantir que a invocação é válida.
    if 'CodePipeline.job' not in event:
        error_message = ("ERRO: Invocação inválida. O evento recebido não contém a chave 'CodePipeline.job'. "
                         "Esta função deve ser acionada por uma ação 'Invoke' do AWS CodePipeline. "
                         "Se estiver testando manualmente, configure um evento de teste com o formato do CodePipeline.")
        print(error_message)
        # É importante falhar aqui para que o problema seja óbvio.
        raise ValueError(error_message)

    job_id = None
    codepipeline_client = None
    
    try:
        # 1. Obter o Job ID do evento do CodePipeline
        job_id = event['CodePipeline.job']['id']
        
        # 2. Obter variáveis de ambiente
        region = os.environ['REGION']
        pipeline_name_var = os.environ['AWS_CODEPIPELINE_TARGET_NAME_0']
        s3_bucket_name = os.environ['AWS_S3_BUCKET_TARGET_NAME_0']
        ssm_parameter_name = os.environ['AWS_SSM_PARAMETER_SOURCE_ARN_0']
        sns_topic_name = os.environ['AWS_SNS_TOPIC_TARGET_NAME_0']
        
        # 3. Inicializar clientes Boto3
        codepipeline_client = boto3.client('codepipeline', region_name=region)
        ssm_client = boto3.client('ssm', region_name=region)
        s3_client = boto3.client('s3', region_name=region)
        sns_client = boto3.client('sns', region_name=region)
        sts_client = boto3.client('sts', region_name=region)

        # 4. Coletar e formatar dados do pipeline
        print("--- Coletando e formatando dados do Pipeline ---")
        pipeline_data = get_pipeline_status(codepipeline_client, pipeline_name_var)
        formatted_pipeline_report, overall_status, pipeline_name = format_pipeline_report(pipeline_data)
        
        # 5. Coletar dados da aplicação web
        print("--- Coletando dados da aplicação web ---")
        web_server_domain = get_url_from_ssm(ssm_client, ssm_parameter_name)
        web_page_content = fetch_url_content(web_server_domain)
        
        # 6. Montar relatório final
        page_status = "Acesso com sucesso." if "<html>" in web_page_content.lower() else "Conteúdo inesperado ou erro."
        final_report_string = (
            f"{formatted_pipeline_report}\n"
            f"{'='*60}\n"
            f"        Status da Aplicação em Produção\n"
            f"{'='*60}\n\n"
            f"URL Acessada: https://{web_server_domain}\n"
            f"Status: {page_status}\n"
            f"Conteúdo da Página (Prévia):\n"
            f"{web_page_content[:1000] + ('...' if len(web_page_content) > 1000 else '')}"
        )
        
        # 7. Salvar relatório no S3
        timestamp_str = datetime.now(timezone.utc).strftime('%Y-%m-%d_%H-%M-%S')
        file_name = f"deploy-report-{timestamp_str}.txt"
        upload_to_s3(s3_client, s3_bucket_name, file_name, final_report_string)

        # 8. Enviar notificação para o SNS
        account_id = sts_client.get_caller_identity()['Account']
        sns_topic_arn = f"arn:aws:sns:{region}:{account_id}:{sns_topic_name}"
        email_subject = f"Relatório de Deploy: Pipeline {pipeline_name} - Status: {overall_status}"
        publish_to_sns(sns_client, sns_topic_arn, email_subject, final_report_string)
        
        # 9. Notificar o CodePipeline sobre o SUCESSO
        put_job_success(codepipeline_client, job_id, "Relatório gerado e enviado com sucesso.")

    except Exception as e:
        # A verificação inicial já deve ter capturado o erro de invocação, mas este 'except'
        # ainda é crucial para todos os outros erros de lógica ou permissão.
        error_msg = f"Ocorreu um erro inesperado durante a execução do job: {str(e)}"
        print(error_msg)
        
        if job_id:
            if not codepipeline_client:
                region = os.environ.get('REGION', 'us-east-1')
                codepipeline_client = boto3.client('codepipeline', region_name=region)
            put_job_failure(codepipeline_client, job_id, error_msg)
        
        return {'statusCode': 500, 'body': json.dumps(error_msg)}

    return {'statusCode': 200, 'body': json.dumps("Processo concluído com sucesso.")}
