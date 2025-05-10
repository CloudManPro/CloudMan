from flask import Flask, request, jsonify
from flask_cors import CORS
import subprocess
import os
import signal
import time
import shutil
import errno
# import zipfile # Não mais necessário para este fluxo
import boto3
from botocore.exceptions import NoCredentialsError, PartialCredentialsError, ClientError
import mimetypes  # Para ajudar a determinar o ContentType

# File JmeterServer.py
app = Flask(__name__)
CORS(app)

# --- Configurações ---
JMETER_HOME_ENV = os.getenv('JMETER_HOME')
JMETER_EXECUTABLE = None

S3_BUCKET_NAME = os.getenv('AWS_S3_BUCKET_TARGET_NAME_REPORT')
S3_BUCKET_REGION = os.getenv('AWS_S3_BUCKET_TARGET_REGION_REPORT')


if JMETER_HOME_ENV and os.path.isdir(JMETER_HOME_ENV):
    temp_executable = os.path.join(JMETER_HOME_ENV, 'bin', 'jmeter')
    if os.path.isfile(temp_executable) and os.access(temp_executable, os.X_OK):
        JMETER_EXECUTABLE = temp_executable
        print(
            f"INFO: Usando JMETER_EXECUTABLE de JMETER_HOME: {JMETER_EXECUTABLE}")
    else:
        print(
            f"AVISO: JMETER_HOME ({JMETER_HOME_ENV}) não é um executável válido. Tentando PATH.")
        JMETER_EXECUTABLE = shutil.which("jmeter")
        if JMETER_EXECUTABLE:
            print(
                f"INFO: JMETER_EXECUTABLE encontrado no PATH: {JMETER_EXECUTABLE}")
        else:
            print("ERRO CRÍTICO: JMeter não encontrado em JMETER_HOME nem no PATH.")
else:
    if JMETER_HOME_ENV:
        print(
            f"AVISO: JMETER_HOME ('{JMETER_HOME_ENV}') não é um diretório válido. Tentando encontrar 'jmeter' no PATH.")
    else:
        print("INFO: JMETER_HOME não está definido. Tentando encontrar 'jmeter' no PATH.")
    JMETER_EXECUTABLE = shutil.which("jmeter")
    if JMETER_EXECUTABLE:
        print(
            f"INFO: JMETER_EXECUTABLE encontrado no PATH: {JMETER_EXECUTABLE}")
    else:
        print("ERRO CRÍTICO: 'jmeter' não encontrado no PATH e JMETER_HOME não definido ou inválido.")

UPLOAD_FOLDER = 'jmeter_uploads'
RESULTS_FOLDER = 'jmeter_results'
LOGS_FOLDER = 'jmeter_logs'
REPORTS_TEMP_FOLDER = 'jmeter_html_reports_temp'

os.makedirs(UPLOAD_FOLDER, exist_ok=True)
os.makedirs(RESULTS_FOLDER, exist_ok=True)
os.makedirs(LOGS_FOLDER, exist_ok=True)
os.makedirs(REPORTS_TEMP_FOLDER, exist_ok=True)

jmeter_process_pid = None
current_log_file_path = None
current_results_file_path = None


def generate_html_report(jtl_file, report_output_folder):
    if not JMETER_EXECUTABLE:
        print("ERRO generate_html_report: JMETER_EXECUTABLE não está definido.")
        return False, "Executável do JMeter não configurado no servidor."
    if not os.path.exists(jtl_file):
        print(
            f"ERRO generate_html_report: Arquivo JTL '{jtl_file}' não encontrado.")
        return False, f"Arquivo de resultados '{jtl_file}' não encontrado."

    if os.path.exists(report_output_folder):
        try:
            shutil.rmtree(report_output_folder)
            print(
                f"INFO generate_html_report: Pasta de relatório existente '{report_output_folder}' removida.")
        except Exception as e:
            msg = f"Erro ao remover pasta de relatório existente '{report_output_folder}': {str(e)}"
            print(f"ERRO generate_html_report: {msg}")
            return False, msg

    report_command = [
        JMETER_EXECUTABLE,
        '-g', jtl_file,
        '-o', report_output_folder
    ]
    print(
        f"INFO generate_html_report: Gerando relatório HTML com comando: {' '.join(report_command)}")
    try:
        completed_process = subprocess.run(
            report_command, capture_output=True, text=True, check=False)
        if completed_process.returncode == 0:
            print(
                f"INFO generate_html_report: Relatório HTML gerado com sucesso em '{report_output_folder}'.")
            return True, f"Relatório HTML gerado em '{report_output_folder}'."
        else:
            error_msg = f"Falha ao gerar relatório HTML. Código de saída: {completed_process.returncode}\nOutput:\n{completed_process.stdout}\nError:\n{completed_process.stderr}"
            print(f"ERRO generate_html_report: {error_msg}")
            return False, error_msg
    except Exception as e:
        error_msg = f"Exceção ao gerar relatório HTML: {str(e)}"
        print(f"ERRO generate_html_report: {error_msg}")
        return False, error_msg

# REMOVIDA: def zip_directory(folder_path, zip_path):


def upload_directory_to_s3(local_directory_path, bucket_name, s3_target_prefix, region_name):
    """
    Faz upload do conteúdo de um diretório local para um prefixo S3.
    """
    if not bucket_name or not region_name:
        return False, "Nome do bucket S3 ou região não configurados nas variáveis de ambiente."

    s3_client = boto3.client('s3', region_name=region_name)
    uploaded_files_count = 0
    errors_encountered = []

    # Garante que o prefixo termine com / para simular uma pasta
    if s3_target_prefix and not s3_target_prefix.endswith('/'):
        s3_target_prefix += '/'

    for root, _, files in os.walk(local_directory_path):
        for filename in files:
            local_file_path = os.path.join(root, filename)
            # Cria o caminho relativo para manter a estrutura de pastas no S3
            relative_path = os.path.relpath(
                local_file_path, local_directory_path)
            s3_file_key = os.path.join(s3_target_prefix, relative_path).replace(
                "\\", "/")  # Garante barras /

            # Tenta adivinhar o ContentType
            content_type, _ = mimetypes.guess_type(local_file_path)
            if content_type is None:
                content_type = 'application/octet-stream'  # Default

            # Define ContentType para HTML especificamente para renderização correta
            if filename.lower().endswith(('.html', '.htm')):
                content_type = 'text/html; charset=utf-8'
            elif filename.lower().endswith('.css'):
                content_type = 'text/css; charset=utf-8'
            elif filename.lower().endswith('.js'):
                content_type = 'application/javascript; charset=utf-8'

            try:
                print(
                    f"INFO upload_directory_to_s3: Uploading '{local_file_path}' to '{bucket_name}/{s3_file_key}' with ContentType: {content_type}")
                with open(local_file_path, 'rb') as f:
                    s3_client.put_object(
                        Bucket=bucket_name, Key=s3_file_key, Body=f, ContentType=content_type)
                uploaded_files_count += 1
            except FileNotFoundError:
                msg = f"Arquivo local '{local_file_path}' não encontrado para upload."
                print(f"ERRO upload_directory_to_s3: {msg}")
                errors_encountered.append(msg)
            except (NoCredentialsError, PartialCredentialsError):
                msg = "Credenciais AWS não encontradas/incompletas."
                print(f"ERRO upload_directory_to_s3: {msg}")
                errors_encountered.append(msg)
                return False, msg  # Erro crítico, interrompe
            except ClientError as e:
                msg = f"Erro do cliente S3 ao fazer upload de '{s3_file_key}': {str(e)}"
                print(f"ERRO upload_directory_to_s3: {msg}")
                errors_encountered.append(msg)
            except Exception as e:
                msg = f"Erro inesperado durante upload de '{s3_file_key}': {str(e)}"
                print(f"ERRO upload_directory_to_s3: {msg}")
                errors_encountered.append(msg)

    if errors_encountered:
        return False, f"Upload para S3 concluído com {len(errors_encountered)} erro(s). {uploaded_files_count} arquivos enviados. Erros: {'; '.join(errors_encountered)}"

    # URL para o index.html principal do relatório
    s3_index_url = f"https://{bucket_name}.s3.{region_name}.amazonaws.com/{s3_target_prefix}index.html"
    # Ou, se o bucket estiver configurado para hospedagem de site estático:
    # s3_index_url = f"http://{bucket_name}.s3-website-{region_name}.amazonaws.com/{s3_target_prefix}index.html"

    msg_success = f"Upload de {uploaded_files_count} arquivos para S3 (prefixo: '{s3_target_prefix}') bem-sucedido. Relatório: {s3_index_url}"
    print(f"INFO upload_directory_to_s3: {msg_success}")
    return True, msg_success


@app.route('/health_check', methods=['GET'])
def health_check():
    # ... (código existente, sem alterações aqui)
    if JMETER_EXECUTABLE and os.path.exists(JMETER_EXECUTABLE):
        jmeter_status = "ok"
        jmeter_msg = JMETER_EXECUTABLE
    elif JMETER_EXECUTABLE and not os.path.isabs(JMETER_EXECUTABLE) and shutil.which(JMETER_EXECUTABLE):
        jmeter_status = "ok"
        jmeter_msg = f"Comando '{JMETER_EXECUTABLE}' encontrado no PATH."
    else:
        jmeter_status = "warning"
        jmeter_msg_detail = "Executável do JMeter não foi encontrado ou não está configurado corretamente. "
        jmeter_msg_detail += f"Verifique a variável de ambiente JMETER_HOME e se 'jmeter' está no PATH do servidor. "
        jmeter_msg_detail += f"Tentativa de usar: '{JMETER_EXECUTABLE if JMETER_EXECUTABLE else 'Não determinado'}'. "
        jmeter_msg_detail += f"JMETER_HOME no ambiente do servidor: '{JMETER_HOME_ENV if JMETER_HOME_ENV else 'Não definido'}'."
        print(f"DEBUG health_check: {jmeter_msg_detail}")
        jmeter_msg = jmeter_msg_detail

    s3_ok = S3_BUCKET_NAME and S3_BUCKET_REGION
    s3_status_msg = f"Bucket: {S3_BUCKET_NAME if S3_BUCKET_NAME else 'NÃO DEFINIDO'}, Região: {S3_BUCKET_REGION if S3_BUCKET_REGION else 'NÃO DEFINIDO'}"

    final_status = "ok"
    messages = ["Servidor backend está operacional."]
    if jmeter_status == "warning":
        final_status = "ok_with_warning"
        messages.append(f"Aviso JMeter: {jmeter_msg}")
    else:
        messages.append(f"JMeter Path: {jmeter_msg}")

    if not s3_ok:
        final_status = "ok_with_warning"
        messages.append(f"Aviso S3: Configuração incompleta. {s3_status_msg}")
    else:
        messages.append(f"Configuração S3: {s3_status_msg}")

    return jsonify({
        "status": final_status,
        "message": "\n".join(messages),
        "jmeter_path_status": jmeter_status,
        "jmeter_path_detail": jmeter_msg,
        "s3_configured": s3_ok,
        "s3_config_detail": s3_status_msg
    }), 200


@app.route('/upload_and_start', methods=['POST'])
def upload_and_start():
    # ... (código existente, sem alterações aqui)
    global jmeter_process_pid, current_log_file_path, current_results_file_path

    if not JMETER_EXECUTABLE:
        print("ERRO upload_and_start: JMETER_EXECUTABLE não está definido.")
        return jsonify({"message": "Configuração do JMeter no servidor está incompleta. Executável não encontrado."}), 500

    if jmeter_process_pid:
        try:
            os.kill(jmeter_process_pid, 0)
            print(
                f"INFO upload_and_start: Teste JMeter já em execução com PID {jmeter_process_pid}.")
            return jsonify({"message": f"Um teste JMeter já está em execução com PID {jmeter_process_pid}. Pare-o primeiro."}), 409
        except OSError:
            jmeter_process_pid = None
            current_log_file_path = None
            current_results_file_path = None

    if 'jmxFile' not in request.files:
        return jsonify({"message": "Nenhum arquivo .jmx enviado"}), 400
    file = request.files['jmxFile']
    if file.filename == '':
        return jsonify({"message": "Nenhum arquivo selecionado"}), 400

    if file and file.filename.endswith('.jmx'):
        safe_filename = os.path.basename(file.filename)
        filepath = os.path.join(UPLOAD_FOLDER, safe_filename)
        file.save(filepath)

        base_name = os.path.splitext(safe_filename)[0]
        timestamp = time.strftime("%Y%m%d-%H%M%S")

        current_log_file_path = os.path.join(
            LOGS_FOLDER, f"{base_name}_{timestamp}.log")
        current_results_file_path = os.path.join(
            RESULTS_FOLDER, f"{base_name}_{timestamp}.jtl")

        jmeter_command = [
            JMETER_EXECUTABLE,
            '-Djava.awt.headless=true',
            '-n',
            '-t', filepath,
            '-l', current_results_file_path,
            '-j', current_log_file_path
        ]
        try:
            print(
                f"INFO upload_and_start: Executando comando JMeter: {' '.join(jmeter_command)}")
            process = subprocess.Popen(jmeter_command)
            jmeter_process_pid = process.pid
            print(
                f"INFO upload_and_start: JMeter iniciado com PID {jmeter_process_pid}.")
            return jsonify({
                "message": f"Plano de teste '{safe_filename}' carregado e JMeter iniciado.",
                "pid": jmeter_process_pid,
                "log_file": current_log_file_path,
                "results_file": current_results_file_path
            }), 200
        except Exception as e:
            jmeter_process_pid = None
            current_log_file_path = None
            current_results_file_path = None
            print(f"ERRO upload_and_start: Erro ao iniciar JMeter: {str(e)}")
            return jsonify({"message": f"Erro ao iniciar JMeter: {str(e)}"}), 500
    else:
        return jsonify({"message": "Arquivo inválido. Por favor, envie um arquivo .jmx"}), 400


@app.route('/stop_test', methods=['POST'])
def stop_test():
    global jmeter_process_pid, current_log_file_path, current_results_file_path

    jmeter_process_pid_original_value = jmeter_process_pid
    final_message = []

    if jmeter_process_pid is None:
        final_message.append("Nenhum teste JMeter em execução para parar.")
    else:
        try:
            print(
                f"INFO stop_test: Tentando parar o processo JMeter com PID: {jmeter_process_pid}")
            os.kill(jmeter_process_pid, signal.SIGTERM)
            time.sleep(2)
            try:
                os.kill(jmeter_process_pid, 0)
                print(
                    f"AVISO stop_test: Processo {jmeter_process_pid} ainda existe após SIGTERM. Enviando SIGKILL.")
                os.kill(jmeter_process_pid, signal.SIGKILL)
                final_message.append(
                    f"Sinal SIGKILL enviado para forçar parada do JMeter PID {jmeter_process_pid}.")
            except OSError as ex:
                if ex.errno == errno.ESRCH:
                    final_message.append(
                        f"Processo JMeter PID {jmeter_process_pid} parado com sucesso (após SIGTERM).")
                else:
                    raise
            except Exception as e_inner:
                err_msg = f"Erro inesperado ao tentar SIGKILL no processo {jmeter_process_pid}: {str(e_inner)}"
                print(f"ERRO stop_test: {err_msg}")
                final_message.append(
                    f"Processo JMeter PID {jmeter_process_pid} pode não ter sido parado corretamente após SIGTERM ({err_msg}).")
            jmeter_process_pid = None
        except OSError as e:
            if e.errno == errno.ESRCH:
                final_message.append(
                    f"Processo JMeter com PID {jmeter_process_pid_original_value} não encontrado. Pode já ter sido parado ou terminado.")
                jmeter_process_pid = None
            else:
                err_msg = f"Erro OSError ao parar o processo JMeter: {str(e)}"
                print(f"ERRO stop_test: {err_msg}")
                final_message.append(err_msg)
                return jsonify({"message": "\n".join(final_message)}), 500
        except Exception as e:
            err_msg = f"Erro inesperado ao parar JMeter: {str(e)}"
            print(f"ERRO stop_test: {err_msg}")
            final_message.append(err_msg)
            return jsonify({"message": "\n".join(final_message)}), 500

    # --- Geração de Relatório e Upload para S3 ---
    report_details_msg = ""
    if current_results_file_path and os.path.exists(current_results_file_path):
        print(
            f"INFO stop_test: Tentando gerar relatório para {current_results_file_path}")
        timestamp_report = time.strftime("%Y%m%d-%H%M%S")
        report_base_name = os.path.splitext(
            os.path.basename(current_results_file_path))[0]

        report_output_dir_temp = os.path.join(
            REPORTS_TEMP_FOLDER, f"{report_base_name}_html_{timestamp_report}")

        report_success, report_msg = generate_html_report(
            current_results_file_path, report_output_dir_temp)
        final_message.append(f"Geração de Relatório: {report_msg}")

        if report_success:
            # Não vamos mais zipar. Vamos fazer upload do diretório.
            # Prefixo no S3
            s3_report_prefix = f"jmeter-reports/{report_base_name}_{timestamp_report}"

            if S3_BUCKET_NAME and S3_BUCKET_REGION:
                upload_ok, upload_msg = upload_directory_to_s3(
                    report_output_dir_temp, S3_BUCKET_NAME, s3_report_prefix, S3_BUCKET_REGION)
                final_message.append(f"Upload S3: {upload_msg}")
                if upload_ok:
                    report_details_msg = upload_msg  # A mensagem de sucesso do upload já contém o link
            else:
                final_message.append(
                    "Upload S3: Não realizado. Nome do bucket ou região não configurados.")

            # Limpeza da pasta temporária do relatório HTML
            try:
                shutil.rmtree(report_output_dir_temp)
                print(
                    f"INFO stop_test: Pasta temporária do relatório '{report_output_dir_temp}' removida.")
            except Exception as e_clean_dir:
                final_message.append(
                    f"Aviso: Falha ao remover pasta temporária do relatório '{report_output_dir_temp}': {str(e_clean_dir)}")
    elif current_results_file_path:
        final_message.append(
            f"Geração de Relatório: Arquivo de resultados '{current_results_file_path}' não encontrado. Relatório não gerado.")
    else:
        final_message.append(
            "Geração de Relatório: Nenhum arquivo de resultados JTL associado ao teste atual.")

    current_log_file_path = None
    current_results_file_path = None

    final_response_status = 200
    if any("erro" in msg.lower() or "falha" in msg.lower() for msg in final_message if isinstance(msg, str)):
        final_response_status = 200

    return jsonify({"message": "\n".join(final_message), "report_details": report_details_msg}), final_response_status


@app.route('/get_current_log', methods=['GET'])
def get_current_log():
    # ... (código existente, sem alterações aqui)
    global jmeter_process_pid, current_log_file_path

    if not jmeter_process_pid or not current_log_file_path:
        return jsonify({"message": "Nenhum teste JMeter em execução ou caminho do log não definido."}), 404

    if not os.path.exists(current_log_file_path):
        return jsonify({"message": f"Arquivo de log esperado ({current_log_file_path}) não encontrado no servidor."}), 404

    try:
        with open(current_log_file_path, 'r', encoding='utf-8', errors='replace') as f:
            log_content = f.read()
        return log_content, 200, {'Content-Type': 'text/plain; charset=utf-8'}
    except Exception as e:
        print(
            f"ERRO get_current_log: Erro ao ler o arquivo de log '{current_log_file_path}': {str(e)}")
        return jsonify({"message": f"Erro ao ler o arquivo de log: {str(e)}"}), 500


if __name__ == '__main__':
    print("INFO: Iniciando servidor Flask para JMeter Backend.")
    # Mantenha debug=True para desenvolvimento
    app.run(host='0.0.0.0', port=5001, debug=True)
