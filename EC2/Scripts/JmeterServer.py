# Nome do arquivo: JmeterServer.py
# Versão: 1.3.13 (Compatível com JMX v5.0.1/v5.0.2 - TestAction para Pausa e CDATA)
# Changelog:
# v1.3.13 (2025-05-29):
#    - Rota /upload_and_start: Removida a lógica de envio das propriedades -JENABLE_TIMER_TYPE.
#      O JMX v5.0.x usa -JTIMER_TYPE diretamente nos IfControllers para ativar o bloco de pausa correto.
# v1.3.12 (2025-05-29):
#    - Rota /upload_and_start: Ajustada para enviar propriedades -JENABLE_TIMER_TYPE
#      para controlar qual timer é ativado no JMX v4.1.
# v1.3.11 (2025-05-12):
#    - Rota /upload_and_start: Adicionados prints de depuração explícitos para
#      verificar valores lidos do formulário e propriedades -J montadas.
# v1.3.10 (2025-05-12):
#    - Rota /upload_and_start: Ajustada a lógica de envio das propriedades
#      para o modo Duração e modo Loops para alinhar com JMX v3.

from flask import Flask, request, jsonify, send_file
from flask_cors import CORS
import subprocess
import os
import signal
import time
import shutil
import errno
import boto3
from botocore.exceptions import NoCredentialsError, PartialCredentialsError, ClientError
import mimetypes
import re

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
    if not JMETER_EXECUTABLE:  # Fallback se o caminho construído não for executável
        JMETER_EXECUTABLE = shutil.which("jmeter")
else: # Se JMETER_HOME_ENV não estiver definido ou não for um diretório
    JMETER_EXECUTABLE = shutil.which("jmeter")

if JMETER_EXECUTABLE:
    print(f"INFO: JMETER_EXECUTABLE encontrado em: {JMETER_EXECUTABLE}")
else:
    print(
        f"ERRO CRÍTICO: JMeter não encontrado. Verifique JMETER_HOME ('{JMETER_HOME_ENV}') ou se 'jmeter' está no PATH do sistema.")

UPLOAD_FOLDER = 'jmeter_uploads'
RESULTS_FOLDER = 'jmeter_results'
LOGS_FOLDER = 'jmeter_logs'
REPORTS_TEMP_FOLDER = 'jmeter_html_reports_temp' 
for folder in [UPLOAD_FOLDER, RESULTS_FOLDER, LOGS_FOLDER, REPORTS_TEMP_FOLDER]:
    os.makedirs(folder, exist_ok=True)

GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS = 30
POLL_INTERVAL_SECONDS = 1
jmeter_process_pid = None
current_log_file_path = None
current_results_file_path = None


def parse_jmeter_log_summary(log_content):
    summary = {"type": None, "samples": None, "time_segment_seconds": None, "throughput_rps": None, "avg_response_time_ms": None, "min_response_time_ms": None, "max_response_time_ms": None,
               "errors_count": None, "errors_percentage": None, "active_threads": None, "started_threads": None, "finished_threads": None, "raw_line": None, "parsed_timestamp": None}
    last_summary_line = next((line for line in reversed(
        log_content.splitlines()) if "INFO o.a.j.r.Summariser: summary " in line), None)
    if not last_summary_line:
        return summary
    summary["raw_line"] = last_summary_line
    try:
        summary["parsed_timestamp"] = last_summary_line.split(" INFO")[0]
    except: 
        pass
    patterns = {
        "final": r"summary\s*=\s*(\d+)\s*in\s*(\d{2}:\d{2}:\d{2})\s*=\s*([\d\.]+)/s\s*Avg:\s*(\d+)\s*Min:\s*(\d+)\s*Max:\s*(\d+)\s*Err:\s*(\d+)\s*\(([\d\.]+)%\)",
        "incremental": r"summary\s*\+\s*(\d+)\s*in\s*(\d{2}:\d{2}:\d{2})\s*=\s*([\d\.]+)/s\s*Avg:\s*(\d+)\s*Min:\s*(\d+)\s*Max:\s*(\d+)\s*Err:\s*(\d+)\s*\(([\d\.]+)%\)\s*Active:\s*(\d+)\s*Started:\s*(\d+)\s*Finished:\s*(\d+)"
    }
    match = None
    if "summary =" in last_summary_line:
        summary["type"] = "final"
        match = re.search(patterns["final"], last_summary_line)
    elif "summary +" in last_summary_line:
        summary["type"] = "incremental"
        match = re.search(patterns["incremental"], last_summary_line)

    if match:
        try:
            groups = match.groups()
            summary.update({"samples": int(groups[0]), "throughput_rps": float(groups[2]), "avg_response_time_ms": int(groups[3]), "min_response_time_ms": int(
                groups[4]), "max_response_time_ms": int(groups[5]), "errors_count": int(groups[6]), "errors_percentage": float(groups[7])})
            h, m, s = map(int, groups[1].split(':'))
            summary["time_segment_seconds"] = h * 3600 + m * 60 + s
            if summary["type"] == "incremental" and len(groups) >= 11:
                summary.update({"active_threads": int(groups[8]), "started_threads": int(
                    groups[9]), "finished_threads": int(groups[10])})
            elif summary["type"] == "final":
                summary["active_threads"] = 0
        except (IndexError, ValueError) as e:
            print(
                f"ERRO parse_jmeter_log_summary: {last_summary_line} - Erro: {e}")
    return summary


def generate_html_report(jtl_file, report_output_folder):
    if not JMETER_EXECUTABLE:
        return False, "JMeter não configurado."
    if not os.path.exists(jtl_file):
        return False, f"JTL '{jtl_file}' não encontrado."
    if os.path.exists(report_output_folder):
        try:
            shutil.rmtree(report_output_folder)
        except Exception as e:
            return False, f"Erro ao remover dir. relatório: {e}"
    try:
        os.makedirs(report_output_folder, exist_ok=True)
    except Exception as e:
        return False, f"Erro ao criar dir. relatório: {e}"
    cmd = [JMETER_EXECUTABLE, '-g', jtl_file, '-o', report_output_folder]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           check=False, encoding='utf-8', errors='replace')
        if p.returncode == 0:
            return True, f"Relatório HTML gerado em '{report_output_folder}'."
        else:
            return False, f"Falha relatório HTML (cód: {p.returncode}):\n{p.stdout}\n{p.stderr}"
    except Exception as e:
        return False, f"Exceção relatório HTML: {e}"


def upload_directory_to_s3(local_dir, bucket, s3_prefix, region):
    if not bucket or not region:
        return False, "Bucket S3 ou região N/D."
    s3 = boto3.client('s3', region_name=region)
    count, errors = 0, []
    if not os.path.isdir(local_dir):
        return False, f"Dir. local '{local_dir}' não encontrado."
    if s3_prefix and not s3_prefix.endswith('/'): 
        s3_prefix += '/'
    for root, _, files in os.walk(local_dir):
        for filename in files:
            local_path = os.path.join(root, filename)
            rel_path = os.path.relpath(local_path, local_dir)
            s3_key = os.path.join(s3_prefix, rel_path).replace("\\", "/") 
            ct, _ = mimetypes.guess_type(local_path)
            ct = ct or 'application/octet-stream' 
            if filename.lower().endswith(('.html', '.htm')):
                ct = 'text/html; charset=utf-8'
            elif filename.lower().endswith('.css'):
                ct = 'text/css; charset=utf-8'
            elif filename.lower().endswith('.js'):
                ct = 'application/javascript; charset=utf-8'
            try:
                with open(local_path, 'rb') as f:
                    s3.put_object(Bucket=bucket, Key=s3_key,
                                  Body=f, ContentType=ct)
                count += 1
            except Exception as e: 
                if isinstance(e, (NoCredentialsError, PartialCredentialsError)):
                    return False, "Credenciais AWS não encontradas."
                errors.append(f"Erro S3/upload '{s3_key}': {str(e)}")
                break 
    if errors:
        return False, f"Upload S3: {len(errors)} erro(s). {count} arquivos. Erros: {'; '.join(errors)}"
    s3_url = f"https://{bucket}.s3.{region}.amazonaws.com/{s3_prefix}index.html"
    return True, f"Upload {count} arquivos S3 OK. Relatório: {s3_url}"

@app.route('/health_check', methods=['GET'])
def health_check():
    j_ok = JMETER_EXECUTABLE and os.path.exists(JMETER_EXECUTABLE)
    j_msg = f"JMeter: {JMETER_EXECUTABLE}" if j_ok else f"JMeter N/D (EXE: {JMETER_EXECUTABLE or 'N/A'}, HOME: {JMETER_HOME_ENV or 'N/A'})"
    s3_ok = S3_BUCKET_NAME and S3_BUCKET_REGION
    s3_msg = f"S3 Relatórios: Bucket {S3_BUCKET_NAME or 'N/D'}, Região {S3_BUCKET_REGION or 'N/D'}"
    status = "ok_with_warning" if not j_ok or not s3_ok else "ok"
    msgs = ["Backend operacional.", j_msg, s3_msg]
    return jsonify({"status": status, "message": "\n".join(msgs), "jmeter_path_status": "ok" if j_ok else "warning", "jmeter_path_detail": j_msg, "s3_configured": s3_ok, "s3_config_detail": s3_msg}), 200

@app.route('/upload_and_start', methods=['POST'])
def upload_and_start():
    global jmeter_process_pid, current_log_file_path, current_results_file_path
    if not JMETER_EXECUTABLE:
        return jsonify({"message": "Erro crítico: JMeter não configurado."}), 500
    if jmeter_process_pid:
        try:
            os.kill(jmeter_process_pid, 0) 
            return jsonify({"message": f"Teste já em execução (PID {jmeter_process_pid})."}), 409
        except OSError: 
            jmeter_process_pid = None 
    if 'jmxFile' not in request.files:
        return jsonify({"message": "Nenhum arquivo .jmx enviado."}), 400
    file = request.files['jmxFile']
    if not file.filename or not file.filename.lower().endswith('.jmx'):
        return jsonify({"message": "Arquivo .jmx inválido ou não é um .jmx."}), 400

    form_data = request.form
    print("\n" + "="*10 + " DEBUG: Dados Recebidos do Formulário " + "="*10)
    for key, value in form_data.items():
        print(f"  Form['{key}']: {value}")
    print("="*50 + "\n")

    target_host = form_data.get('TARGET_HOST')
    target_protocol = form_data.get('TARGET_PROTOCOL', 'https')
    num_threads = form_data.get('NUM_THREADS', '1')
    ramp_up = form_data.get('RAMP_UP', '0')
    control_mode = form_data.get('CONTROL_MODE', 'duration')
    duration_from_form = form_data.get('DURATION')
    test_loops_from_form = form_data.get('TEST_LOOPS')
    summariser_interval = form_data.get('SUMMARISER_INTERVAL', '30')

    timer_type_from_form = form_data.get('TIMER_TYPE', 'constant')
    c_delay = form_data.get('C_DELAY', '1000')
    ur_range = form_data.get('UR_RANGE', '1000')
    ur_offset = form_data.get('UR_OFFSET', '0')
    gr_deviation = form_data.get('GR_DEVIATION', '100')
    gr_offset = form_data.get('GR_OFFSET', '300')

    safe_filename = os.path.basename(file.filename) 
    filepath = os.path.join(UPLOAD_FOLDER, safe_filename)
    file.save(filepath)
    base_name = os.path.splitext(safe_filename)[0]
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    current_log_file_path = os.path.join(
        LOGS_FOLDER, f"{base_name}_{timestamp}.log")
    current_results_file_path = os.path.join(
        RESULTS_FOLDER, f"{base_name}_{timestamp}.jtl")

    jmeter_command = [JMETER_EXECUTABLE, '-Djava.awt.headless=true']
    if summariser_interval and summariser_interval.strip():
        jmeter_command.append(
            f"-Jsummariser.interval={summariser_interval.strip()}")

    print("\n" + "="*10 + " DEBUG: Montando Comando JMeter (-J Props) " + "="*10)

    def add_jmeter_prop(prop_name, prop_value, default_value=None):
        value_to_use = None
        original_value = prop_value
        if prop_value is not None and str(prop_value).strip():
            value_to_use = str(prop_value).strip()
        elif default_value is not None:
            value_to_use = str(default_value).strip()
            original_value = f"{original_value} (Usando Default: {default_value})"

        if value_to_use is not None:
            prop_string = f"-J{prop_name}={value_to_use}"
            jmeter_command.append(prop_string)
            print(
                f"  Adicionando: {prop_string} (Valor Original/Form: {original_value})")
        else:
            print(
                f"  SKIP: Propriedade {prop_name} não adicionada (Valor Original/Form: {original_value}, Default: {default_value})")

    add_jmeter_prop("TARGET_HOST", target_host)
    add_jmeter_prop("TARGET_PROTOCOL", target_protocol, "https")
    add_jmeter_prop("NUM_THREADS", num_threads, "1")
    add_jmeter_prop("RAMP_UP", ramp_up, "0")

    # --- LÓGICA DE TIMER PARA JMX v5.0.x (TestAction) ---
    add_jmeter_prop("TIMER_TYPE", timer_type_from_form, "constant") 

    if timer_type_from_form == 'constant':
        add_jmeter_prop("C_DELAY", c_delay, "1000")
    elif timer_type_from_form == 'uniform_random':
        add_jmeter_prop("UR_RANGE", ur_range, "1000")
        add_jmeter_prop("UR_OFFSET", ur_offset, "0")
    elif timer_type_from_form == 'gaussian_random':
        add_jmeter_prop("GR_DEVIATION", gr_deviation, "100")
        add_jmeter_prop("GR_OFFSET", gr_offset, "300")
    # --- FIM DA LÓGICA DE TIMER ---

    if control_mode == 'duration':
        add_jmeter_prop("USE_SCHEDULER", "true")
        add_jmeter_prop("DURATION", duration_from_form, "60")
        add_jmeter_prop("TEST_LOOPS", "-1") 
    elif control_mode == 'loops':
        add_jmeter_prop("USE_SCHEDULER", "false")
        add_jmeter_prop("TEST_LOOPS", test_loops_from_form, "1")

    print("="*55 + "\n")

    jmeter_command.extend(['-n', '-t', filepath, '-l',
                          current_results_file_path, '-j', current_log_file_path])
    try:
        print("\nINFO: Comando JMeter final a ser executado:")
        print(f"  {' '.join(jmeter_command)}\n")
        process = subprocess.Popen(jmeter_command)
        jmeter_process_pid = process.pid
        print(
            f"INFO: JMeter ('{safe_filename}') iniciado PID {jmeter_process_pid}.")
        return jsonify({"message": f"Teste '{safe_filename}' iniciado.", "pid": jmeter_process_pid, "log_file": current_log_file_path, "results_file": current_results_file_path}), 200
    except Exception as e: 
        print(f"ERRO: Falha ao iniciar JMeter: {e}")
        current_log_file_path = None
        current_results_file_path = None
        return jsonify({"message": f"Erro ao iniciar JMeter: {e}"}), 500

@app.route('/stop_test', methods=['POST'])
def stop_test():
    global jmeter_process_pid, current_results_file_path, current_log_file_path
    pid_to_stop = jmeter_process_pid
    msg_parts = []
    was_jmeter_running = pid_to_stop is not None

    if was_jmeter_running:
        try:
            os.kill(pid_to_stop, signal.SIGTERM) 
            msg_parts.append(f"SIGTERM enviado para PID {pid_to_stop}.")
            stopped_graciously = False
            for _ in range(int(GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS / POLL_INTERVAL_SECONDS)):
                time.sleep(POLL_INTERVAL_SECONDS)
                try:
                    os.kill(pid_to_stop, 0) 
                except OSError as e:
                    if e.errno == errno.ESRCH: 
                        msg_parts.append(
                            f"PID {pid_to_stop} parou graciosamente.")
                        stopped_graciously = True
                        break
                    else: 
                        raise 
            
            if not stopped_graciously:
                msg_parts.append(
                    f"PID {pid_to_stop} não parou com SIGTERM após {GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS}s. Enviando SIGKILL.")
                try:
                    os.kill(pid_to_stop, signal.SIGKILL) 
                    time.sleep(POLL_INTERVAL_SECONDS) 
                    msg_parts.append(
                        f"SIGKILL enviado para PID {pid_to_stop}.")
                except OSError as e: 
                    if e.errno == errno.ESRCH:
                        msg_parts.append(
                            f"PID {pid_to_stop} já parado antes do SIGKILL (ou parou rapidamente).")
                    else: 
                        msg_parts.append(
                            f"Erro ao enviar SIGKILL para PID {pid_to_stop}: {e}")
            jmeter_process_pid = None 
        except Exception as e: 
            msg_parts.append(f"Erro ao tentar parar PID {pid_to_stop}: {e}")
            jmeter_process_pid = None 
    else:
        msg_parts.append(
            "Nenhum processo JMeter ativo para parar. Tentando gerar relatório do último JTL (se existir).")

    report_url = ""
    results_file_that_was_processed = current_results_file_path 

    if current_results_file_path and os.path.exists(current_results_file_path) and os.path.getsize(current_results_file_path) > 0:
        print(
            f"INFO stop_test/generate_report: Processando JTL '{current_results_file_path}' para relatório.")
        ts_report = time.strftime("%Y%m%d-%H%M%S")
        report_base_name = os.path.splitext(
            os.path.basename(current_results_file_path))[0]
        report_dir_temp = os.path.join(
            REPORTS_TEMP_FOLDER, f"{report_base_name}_html_{ts_report}")

        report_ok, report_msg_gen = generate_html_report(
            current_results_file_path, report_dir_temp)
        msg_parts.append(f"Geração do Relatório: {report_msg_gen}")

        if report_ok:
            s3_prefix_report = f"jmeter-reports/{report_base_name}_{ts_report}"
            if S3_BUCKET_NAME and S3_BUCKET_REGION:
                upload_ok, upload_msg_s3 = upload_directory_to_s3(
                    report_dir_temp, S3_BUCKET_NAME, s3_prefix_report, S3_BUCKET_REGION)
                msg_parts.append(f"Upload S3: {upload_msg_s3}")
                if upload_ok and "Relatório: " in upload_msg_s3:
                    report_url = upload_msg_s3.split("Relatório: ")[-1]
            else:
                msg_parts.append(
                    "Upload S3: Não realizado (bucket/região S3 não configurados).")
            
            if os.path.isdir(report_dir_temp):
                try:
                    shutil.rmtree(report_dir_temp)
                    msg_parts.append(
                        f"Diretório temporário do relatório '{report_dir_temp}' removido.")
                except Exception as e_clean:
                    msg_parts.append(
                        f"Aviso: Falha ao limpar diretório temporário do relatório '{report_dir_temp}': {e_clean}")
    elif current_results_file_path:
        msg_parts.append(
            f"Relatório não gerado: Arquivo JTL '{current_results_file_path}' não encontrado, vazio ou inválido.")
    else:
        msg_parts.append(
            "Relatório não gerado: Nenhum arquivo JTL de resultados anterior disponível.")
    
    current_results_file_path = None
    current_log_file_path = None

    return jsonify({"message": "\n".join(msg_parts), "report_details": report_url, "results_file_processed": results_file_that_was_processed}), 200


@app.route('/get_current_log', methods=['GET'])
def get_current_log():
    global current_log_file_path
    if not current_log_file_path or not os.path.exists(current_log_file_path):
        return "Log não encontrado (ou o teste já terminou e foi limpo).", 404, {'Content-Type': 'text/plain; charset=utf-8'}
    try:
        return send_file(current_log_file_path, mimetype='text/plain', as_attachment=False)
    except Exception as e:
        return f"Erro ao ler log: {str(e)}", 500, {'Content-Type': 'text/plain; charset=utf-8'}


@app.route('/get_latest_summary_metrics', methods=['GET'])
def get_latest_summary_metrics_route():
    global current_log_file_path 
    if not current_log_file_path or not os.path.exists(current_log_file_path):
        return jsonify({"error": "Log não encontrado (ou o teste já terminou e foi limpo).", "status_code": 404, "log_exists": False}), 404
    try:
        with open(current_log_file_path, 'r', encoding='utf-8', errors='replace') as f:
            log_content = f.read()
        summary_data = parse_jmeter_log_summary(log_content)
        if summary_data.get("raw_line") is None:
            return jsonify({"message": "Aguardando 1º resumo do JMeter...", "status_code": 202, "log_exists": True, "log_length_lines": len(log_content.splitlines()), "active_threads": None}), 202
        
        if summary_data.get("type") == "incremental" and summary_data.get("active_threads") is None:
            print(
                f"WARN: parse_jmeter_log_summary retornou 'incremental' mas active_threads é None. Linha RAW: {summary_data.get('raw_line')}")
        return jsonify(summary_data), 200
    except Exception as e: 
        print(f"ERRO get_latest_summary_metrics_route: {str(e)}")
        return jsonify({"error": f"Erro ao processar log: {str(e)}", "status_code": 500, "log_exists": True}), 500


if __name__ == '__main__':
    app_version = "1.3.13" 
    print(f"INFO: Iniciando JMeter Backend (JmeterServer.py v{app_version}).")
    print(f"INFO: Script Python para JMeter Backend (versão {app_version})") # Adicionado para clareza no log do serviço
    print(
        f"INFO: JMETER_EXECUTABLE: {JMETER_EXECUTABLE or 'NÃO ENCONTRADO - VERIFICAR CONFIGURAÇÃO!'}")
    print(
        f"INFO: S3 Bucket para Relatórios: {S3_BUCKET_NAME or 'NÃO CONFIGURADO'}")
    print(
        f"INFO: S3 Região para Relatórios: {S3_BUCKET_REGION or 'NÃO CONFIGURADO'}")
    print(f"INFO: Diretório de Uploads: {os.path.abspath(UPLOAD_FOLDER)}")
    print(
        f"INFO: Diretório de Resultados (JTL): {os.path.abspath(RESULTS_FOLDER)}")
    print(f"INFO: Diretório de Logs (JMeter): {os.path.abspath(LOGS_FOLDER)}")
    print(
        f"INFO: Timeout para SIGTERM (parada graciosa): {GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS}s")
    app.run(host='0.0.0.0', port=5001, debug=True)
