# Nome do arquivo: JmeterServer.py
# Versão: 1.5.1 (Robustez no Reset Forçado)
# Changelog:
# v1.5.1 (Data Sugerida: 2025-06-01):
#    - ## CORREÇÃO ##: Adicionado tratamento de erro `FileNotFoundError` no endpoint '/force_reset'.
#      Se o comando 'pgrep' não for encontrado no sistema, a aplicação não irá mais quebrar na inicialização.
#      Em vez disso, a função de reset retornará uma mensagem de erro apropriada.
# v1.5.0: Adicionado endpoint '/force_reset'.
# v1.4.0: Adicionado gerenciamento de estado via `state.json` e `threading.Lock`.
# ... (Changelog anterior)

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
import json
import threading
from werkzeug.utils import secure_filename

app = Flask(__name__)
CORS(app)

# --- Configurações, Gerenciamento de Estado, Funções Auxiliares (sem alterações) ---
# ... (Todo o código de setup, load_state, clear_state, parse_summary, etc., permanece o mesmo da v1.5.0) ...
JMETER_HOME_ENV = os.getenv('JMETER_HOME')
JMETER_EXECUTABLE = None
S3_BUCKET_NAME = os.getenv('AWS_S3_BUCKET_TARGET_NAME_REPORT')
S3_BUCKET_REGION = os.getenv('AWS_S3_BUCKET_TARGET_REGION_REPORT')

if JMETER_HOME_ENV and os.path.isdir(JMETER_HOME_ENV):
    temp_executable = os.path.join(JMETER_HOME_ENV, 'bin', 'jmeter')
    if os.path.isfile(temp_executable) and os.access(temp_executable, os.X_OK):
        JMETER_EXECUTABLE = temp_executable
    if not JMETER_EXECUTABLE:
        JMETER_EXECUTABLE = shutil.which("jmeter")
else:
    JMETER_EXECUTABLE = shutil.which("jmeter")

if JMETER_EXECUTABLE:
    print(f"INFO: JMETER_EXECUTABLE encontrado em: {JMETER_EXECUTABLE}")
else:
    print(f"ERRO CRÍTICO: JMeter não encontrado. Verifique JMETER_HOME ('{JMETER_HOME_ENV}') ou se 'jmeter' está no PATH do sistema.")

UPLOAD_FOLDER = 'jmeter_uploads'
RESULTS_FOLDER = 'jmeter_results'
LOGS_FOLDER = 'jmeter_logs'
REPORTS_TEMP_FOLDER = 'jmeter_html_reports_temp'
STATE_FILE = 'jmeter_state.json'
for folder in [UPLOAD_FOLDER, RESULTS_FOLDER, LOGS_FOLDER, REPORTS_TEMP_FOLDER]:
    os.makedirs(folder, exist_ok=True)

GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS = 30
POLL_INTERVAL_SECONDS = 1
jmeter_process_lock = threading.Lock()

def save_state(pid, log_file, results_file):
    state = {"jmeter_process_pid": pid, "current_log_file_path": log_file, "current_results_file_path": results_file, "timestamp": time.time()}
    try:
        with open(STATE_FILE, 'w') as f: json.dump(state, f)
    except IOError as e: print(f"ERRO CRÍTICO: Não foi possível salvar o estado em {STATE_FILE}: {e}")

def load_state():
    if not os.path.exists(STATE_FILE): return None, None, None
    try:
        with open(STATE_FILE, 'r') as f: state = json.load(f)
        pid = state.get("jmeter_process_pid")
        if pid:
            try:
                os.kill(pid, 0)
                print(f"INFO: Estado recuperado. Processo JMeter (PID {pid}) do estado anterior ainda está ativo.")
                return pid, state.get("current_log_file_path"), state.get("current_results_file_path")
            except OSError:
                print(f"INFO: Estado recuperado, mas o processo JMeter (PID {pid}) não está mais rodando. Limpando estado.")
                clear_state()
                return None, None, None
        return None, None, None
    except (IOError, json.JSONDecodeError) as e:
        print(f"ERRO: Não foi possível carregar ou parsear o arquivo de estado {STATE_FILE}: {e}")
        return None, None, None

def clear_state():
    global jmeter_process_pid, current_log_file_path, current_results_file_path
    jmeter_process_pid = None
    current_log_file_path = None
    current_results_file_path = None
    if os.path.exists(STATE_FILE):
        try: os.remove(STATE_FILE)
        except OSError as e: print(f"AVISO: Falha ao remover arquivo de estado {STATE_FILE}: {e}")
    save_state(None, None, None)

jmeter_process_pid, current_log_file_path, current_results_file_path = load_state()

def parse_jmeter_log_summary(log_content):
    summary = {"type": None, "samples": None, "time_segment_seconds": None, "throughput_rps": None, "avg_response_time_ms": None, "min_response_time_ms": None, "max_response_time_ms": None, "errors_count": None, "errors_percentage": None, "active_threads": None, "started_threads": None, "finished_threads": None, "raw_line": None, "parsed_timestamp": None}
    last_summary_line = next((line for line in reversed(log_content.splitlines()) if "INFO o.a.j.r.Summariser: summary " in line), None)
    if not last_summary_line: return summary
    summary["raw_line"] = last_summary_line
    try: summary["parsed_timestamp"] = last_summary_line.split(" INFO")[0]
    except: pass
    patterns = {"final": r"summary\s*=\s*(\d+)\s*in\s*(\d{2}:\d{2}:\d{2})\s*=\s*([\d\.]+)/s\s*Avg:\s*(\d+)\s*Min:\s*(\d+)\s*Max:\s*(\d+)\s*Err:\s*(\d+)\s*\(([\d\.]+)%\)", "incremental": r"summary\s*\+\s*(\d+)\s*in\s*(\d{2}:\d{2}:\d{2})\s*=\s*([\d\.]+)/s\s*Avg:\s*(\d+)\s*Min:\s*(\d+)\s*Max:\s*(\d+)\s*Err:\s*(\d+)\s*\(([\d\.]+)%\)\s*Active:\s*(\d+)\s*Started:\s*(\d+)\s*Finished:\s*(\d+)"}
    match = None
    if "summary =" in last_summary_line: summary["type"] = "final"; match = re.search(patterns["final"], last_summary_line)
    elif "summary +" in last_summary_line: summary["type"] = "incremental"; match = re.search(patterns["incremental"], last_summary_line)
    if match:
        try:
            groups = match.groups()
            summary.update({"samples": int(groups[0]), "throughput_rps": float(groups[2]), "avg_response_time_ms": int(groups[3]), "min_response_time_ms": int(groups[4]), "max_response_time_ms": int(groups[5]), "errors_count": int(groups[6]), "errors_percentage": float(groups[7])})
            h, m, s = map(int, groups[1].split(':')); summary["time_segment_seconds"] = h * 3600 + m * 60 + s
            if summary["type"] == "incremental" and len(groups) >= 11: summary.update({"active_threads": int(groups[8]), "started_threads": int(groups[9]), "finished_threads": int(groups[10])})
            elif summary["type"] == "final": summary["active_threads"] = 0
        except (IndexError, ValueError) as e: print(f"ERRO parse_jmeter_log_summary: {last_summary_line} - Erro: {e}")
    return summary

# ... (outras funções auxiliares como generate_html_report e upload_directory_to_s3) ...
def generate_html_report(jtl_file, report_output_folder):
    if not JMETER_EXECUTABLE: return False, "JMeter não configurado."
    if not os.path.exists(jtl_file): return False, f"JTL '{jtl_file}' não encontrado."
    if os.path.exists(report_output_folder):
        try: shutil.rmtree(report_output_folder)
        except Exception as e: return False, f"Erro ao remover dir. relatório: {e}"
    try: os.makedirs(report_output_folder, exist_ok=True)
    except Exception as e: return False, f"Erro ao criar dir. relatório: {e}"
    cmd = [JMETER_EXECUTABLE, '-g', jtl_file, '-o', report_output_folder]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, check=False, encoding='utf-8', errors='replace')
        if p.returncode == 0: return True, f"Relatório HTML gerado em '{report_output_folder}'."
        else: return False, f"Falha relatório HTML (cód: {p.returncode}):\n{p.stdout}\n{p.stderr}"
    except Exception as e: return False, f"Exceção relatório HTML: {e}"

def upload_directory_to_s3(local_dir, bucket, s3_prefix, region):
    if not bucket or not region: return False, "Bucket S3 ou região N/D."
    s3 = boto3.client('s3', region_name=region)
    count, errors = 0, []
    if not os.path.isdir(local_dir): return False, f"Dir. local '{local_dir}' não encontrado."
    if s3_prefix and not s3_prefix.endswith('/'): s3_prefix += '/'
    for root, _, files in os.walk(local_dir):
        for filename in files:
            local_path = os.path.join(root, filename)
            rel_path = os.path.relpath(local_path, local_dir)
            s3_key = os.path.join(s3_prefix, rel_path).replace("\\", "/") 
            ct, _ = mimetypes.guess_type(local_path); ct = ct or 'application/octet-stream'
            if filename.lower().endswith('.html'): ct = 'text/html; charset=utf-8'
            elif filename.lower().endswith('.css'): ct = 'text/css; charset=utf-8'
            elif filename.lower().endswith('.js'): ct = 'application/javascript; charset=utf-8'
            try:
                with open(local_path, 'rb') as f: s3.put_object(Bucket=bucket, Key=s3_key, Body=f, ContentType=ct)
                count += 1
            except Exception as e: 
                if isinstance(e, (NoCredentialsError, PartialCredentialsError)): return False, "Credenciais AWS não encontradas."
                errors.append(f"Erro S3/upload '{s3_key}': {str(e)}"); break 
    if errors: return False, f"Upload S3: {len(errors)} erro(s). {count} arquivos. Erros: {'; '.join(errors)}"
    s3_url = f"https://{bucket}.s3.{region}.amazonaws.com/{s3_prefix}index.html"
    return True, f"Upload {count} arquivos S3 OK. Relatório: {s3_url}"

# --- Endpoints ---

@app.route('/health_check', methods=['GET'])
def health_check():
    # ... (sem alterações) ...
    j_ok = JMETER_EXECUTABLE and os.path.exists(JMETER_EXECUTABLE)
    j_msg = f"JMeter: {JMETER_EXECUTABLE}" if j_ok else f"JMeter N/D (EXE: {JMETER_EXECUTABLE or 'N/A'}, HOME: {JMETER_HOME_ENV or 'N/A'})"
    s3_ok = S3_BUCKET_NAME and S3_BUCKET_REGION
    s3_msg = f"S3 Relatórios: Bucket {S3_BUCKET_NAME or 'N/D'}, Região {S3_BUCKET_REGION or 'N/D'}"
    status = "ok_with_warning" if not j_ok or not s3_ok else "ok"
    msgs = ["Backend operacional.", j_msg, s3_msg]
    if jmeter_process_pid: msgs.append(f"INFO: Um teste está atualmente em execução (PID: {jmeter_process_pid}).")
    return jsonify({"status": status, "message": "\n".join(msgs), "jmeter_path_status": "ok" if j_ok else "warning", "jmeter_path_detail": j_msg, "s3_configured": s3_ok, "s3_config_detail": s3_msg}), 200

@app.route('/upload_and_start', methods=['POST'])
def upload_and_start():
    # ... (sem alterações) ...
    global jmeter_process_pid, current_log_file_path, current_results_file_path
    with jmeter_process_lock:
        if not JMETER_EXECUTABLE: return jsonify({"message": "Erro crítico: JMeter não configurado."}), 500
        if jmeter_process_pid:
            try:
                os.kill(jmeter_process_pid, 0)
                return jsonify({"message": f"Teste já em execução (PID {jmeter_process_pid})."}), 409
            except OSError:
                clear_state()
        if 'jmxFile' not in request.files: return jsonify({"message": "Nenhum arquivo .jmx enviado."}), 400
        file = request.files['jmxFile']
        if not file.filename or not file.filename.lower().endswith('.jmx'): return jsonify({"message": "Arquivo .jmx inválido."}), 400
        
        form_data = request.form
        safe_filename = secure_filename(file.filename)
        filepath = os.path.join(UPLOAD_FOLDER, safe_filename)
        file.save(filepath)
        base_name = os.path.splitext(safe_filename)[0]
        timestamp = time.strftime("%Y%m%d-%H%M%S")
        log_file = os.path.join(LOGS_FOLDER, f"{base_name}_{timestamp}.log")
        results_file = os.path.join(RESULTS_FOLDER, f"{base_name}_{timestamp}.jtl")

        jmeter_command = [JMETER_EXECUTABLE, '-Djava.awt.headless=true', f"-Jsummariser.interval={form_data.get('SUMMARISER_INTERVAL', '30')}"]
        
        # ... (montagem do comando jmeter continua igual) ...
        def add_jmeter_prop(prop_name, prop_value, default_value=None):
            value_to_use = str(prop_value).strip() if prop_value is not None and str(prop_value).strip() else str(default_value).strip() if default_value is not None else None
            if value_to_use is not None: jmeter_command.append(f"-J{prop_name}={value_to_use}")
        add_jmeter_prop("TARGET_HOST", form_data.get('TARGET_HOST'))
        add_jmeter_prop("TARGET_PROTOCOL", form_data.get('TARGET_PROTOCOL'), "https")
        add_jmeter_prop("NUM_THREADS", form_data.get('NUM_THREADS'), "1")
        # ...
        
        jmeter_command.extend(['-n', '-t', filepath, '-l', results_file, '-j', log_file])
        
        try:
            process = subprocess.Popen(jmeter_command)
            jmeter_process_pid = process.pid
            current_log_file_path = log_file
            current_results_file_path = results_file
            save_state(jmeter_process_pid, current_log_file_path, current_results_file_path)
            return jsonify({"message": f"Teste '{safe_filename}' iniciado.", "pid": jmeter_process_pid, "log_file": log_file, "results_file": results_file}), 200
        except Exception as e:
            clear_state()
            return jsonify({"message": f"Erro ao iniciar JMeter: {e}"}), 500

@app.route('/stop_test', methods=['POST'])
def stop_test():
    # ... (sem alterações) ...
    # ... Lógica de parada graciosa, geração de relatório e upload S3 ...
    pid_to_stop = jmeter_process_pid
    # ...
    clear_state()
    # ...
    return jsonify({"message": "Operação de parada concluída.", "report_details": "...", "results_file_processed": "..."}), 200


@app.route('/force_reset', methods=['POST'])
def force_reset():
    """
    Endpoint para um reset forçado e completo do sistema.
    1. Limpa o estado interno e persistido da aplicação.
    2. Procura por qualquer processo 'apache-jmeter' em execução no sistema.
    3. Encerra à força (SIGKILL) todos os processos JMeter encontrados.
    """
    print("INFO: Recebido pedido de RESET FORÇADO.")
    msg_parts = []
    
    with jmeter_process_lock:
        clear_state()
        msg_parts.append("Estado do servidor (PID, caminhos de log/JTL) foi limpo.")

        killed_pids = []
        try:
            # ## CORREÇÃO ##: Adicionado tratamento para o caso de 'pgrep' não existir.
            cmd = ['pgrep', '-f', 'apache-jmeter']
            result = subprocess.run(cmd, capture_output=True, text=True)
            
            if result.returncode == 0:
                pids_found = [int(p) for p in result.stdout.strip().splitlines()]
                msg_parts.append(f"Encontrados processos JMeter para encerrar: {pids_found}.")
                
                for pid in pids_found:
                    try:
                        os.kill(pid, signal.SIGKILL)
                        killed_pids.append(pid)
                        print(f"INFO: SIGKILL enviado para o processo JMeter PID {pid}.")
                    except OSError:
                        pass # Processo pode já ter morrido, ignorar.
                
                if killed_pids:
                     msg_parts.append(f"Processos JMeter encerrados com sucesso: {killed_pids}.")

            else:
                msg_parts.append("Nenhum processo JMeter em execução foi encontrado.")

        except FileNotFoundError:
            err_msg = "ERRO CRÍTICO: Comando 'pgrep' não encontrado no sistema. Não foi possível procurar por processos JMeter órfãos. Instale o pacote 'procps-ng' no servidor."
            print(err_msg)
            msg_parts.append(err_msg)
            return jsonify({"message": "\n".join(msg_parts), "killed_pids": []}), 500
        
        except Exception as e:
            error_msg = f"ERRO inesperado durante o reset forçado: {e}"
            print(error_msg)
            msg_parts.append(error_msg)

    final_message = "\n".join(msg_parts)
    print(f"INFO: Reset forçado concluído.")
    return jsonify({"message": final_message, "killed_pids": killed_pids}), 200


@app.route('/get_current_log', methods=['GET'])
def get_current_log():
    # ... (sem alterações) ...
    if not current_log_file_path or not os.path.exists(current_log_file_path):
        return "Log não encontrado.", 404, {'Content-Type': 'text/plain; charset=utf-8'}
    return send_file(current_log_file_path, mimetype='text/plain')

@app.route('/get_latest_summary_metrics', methods=['GET'])
def get_latest_summary_metrics_route():
    # ... (sem alterações) ...
    if not current_log_file_path or not os.path.exists(current_log_file_path):
        return jsonify({"error": "Log não encontrado."}), 404
    with open(current_log_file_path, 'r', encoding='utf-8', errors='replace') as f:
        log_content = f.read()
    summary_data = parse_jmeter_log_summary(log_content)
    if summary_data.get("raw_line") is None:
        return jsonify({"message": "Aguardando 1º resumo do JMeter..."}), 202
    return jsonify(summary_data), 200

if __name__ == '__main__':
    app_version = "1.5.1" 
    print(f"INFO: Iniciando JMeter Backend (JmeterServer.py v{app_version}).")
    # ... (o resto do __main__ permanece o mesmo) ...
    print(f"INFO: JMETER_EXECUTABLE: {JMETER_EXECUTABLE or 'NÃO ENCONTRADO!'}")
    app.run(host='0.0.0.0', port=5001, debug=True)
