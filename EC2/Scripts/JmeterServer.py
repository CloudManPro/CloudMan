from flask import Flask, request, jsonify
import subprocess
import os
import signal
import time
import shutil # Para shutil.which

app = Flask(__name__)

# --- Configurações ---
JMETER_HOME = os.getenv('JMETER_HOME') # Ex: /opt/apache-jmeter-5.5
if not JMETER_HOME:
    print("AVISO: JMETER_HOME não está definido. Tentando encontrar 'jmeter' no PATH.")
    # Tenta encontrar 'jmeter' no PATH se JMETER_HOME não estiver configurado.
    # Isso assume que jmeter/bin está no PATH do usuário que executa o script.
    JMETER_EXECUTABLE = shutil.which("jmeter")
    if not JMETER_EXECUTABLE:
        print("ERRO CRÍTICO: 'jmeter' não encontrado no PATH e JMETER_HOME não definido.")
        # Você pode querer sair do script aqui ou lidar com isso de outra forma
        # exit(1)
else:
    JMETER_EXECUTABLE = os.path.join(JMETER_HOME, 'bin', 'jmeter')

UPLOAD_FOLDER = 'jmeter_uploads'
RESULTS_FOLDER = 'jmeter_results'
LOGS_FOLDER = 'jmeter_logs'

# Cria as pastas se não existirem
os.makedirs(UPLOAD_FOLDER, exist_ok=True)
os.makedirs(RESULTS_FOLDER, exist_ok=True)
os.makedirs(LOGS_FOLDER, exist_ok=True)

# Variável global para armazenar o PID do processo JMeter
jmeter_process_pid = None

@app.route('/health_check', methods=['GET'])
def health_check():
    global JMETER_EXECUTABLE
    jmeter_path_to_report = JMETER_EXECUTABLE # Pode ser o path completo ou apenas 'jmeter'
    
    # Se JMETER_EXECUTABLE é um path completo e existe
    if os.path.isabs(jmeter_path_to_report) and os.path.exists(jmeter_path_to_report):
        return jsonify({
            "status": "ok",
            "message": "Servidor backend está operacional.",
            "jmeter_path": jmeter_path_to_report
        }), 200
    # Se JMETER_EXECUTABLE é apenas 'jmeter' (veio de shutil.which) e foi encontrado
    elif not os.path.isabs(jmeter_path_to_report) and shutil.which(jmeter_path_to_report):
         return jsonify({
            "status": "ok",
            "message": "Servidor backend está operacional.",
            "jmeter_path": f"Comando '{jmeter_path_to_report}' encontrado no PATH."
        }), 200
    else:
        # Se JMETER_HOME foi definido mas o executável não existe
        if JMETER_HOME and not os.path.exists(JMETER_EXECUTABLE):
             msg = f"Servidor backend operacional, mas JMeter não encontrado em {JMETER_EXECUTABLE} (definido por JMETER_HOME). Verifique a instalação."
        # Se JMETER_HOME não foi definido E jmeter não está no PATH
        else:
            msg = "Servidor backend operacional, mas o comando 'jmeter' não foi encontrado no PATH do servidor e JMETER_HOME não está definido. Verifique a instalação do JMeter na EC2 e se o PATH está configurado para o usuário que executa este script."
        return jsonify({
            "status": "ok_with_warning", # Ou poderia ser um status diferente se preferir
            "message": msg,
            "jmeter_path": None
        }), 200 # Ainda retorna 200 OK, pois o servidor Flask está rodando. O frontend interpretará a mensagem.


@app.route('/upload_and_start', methods=['POST'])
def upload_and_start():
    global jmeter_process_pid, JMETER_EXECUTABLE

    if jmeter_process_pid:
        try:
            os.kill(jmeter_process_pid, 0) # Checa se o processo ainda existe
            return jsonify({"message": f"Um teste JMeter já está em execução com PID {jmeter_process_pid}. Pare-o primeiro."}), 409 # Conflict
        except OSError:
            jmeter_process_pid = None # Processo não existe mais, limpa o PID

    if 'jmxFile' not in request.files:
        return jsonify({"message": "Nenhum arquivo .jmx enviado"}), 400
    
    file = request.files['jmxFile']
    if file.filename == '':
        return jsonify({"message": "Nenhum arquivo selecionado"}), 400

    if file and file.filename.endswith('.jmx'):
        # Sanitizar o nome do arquivo pode ser uma boa ideia
        filename = os.path.join(UPLOAD_FOLDER, file.filename)
        file.save(filename)

        # Define nomes para arquivos de log e resultados
        base_name = os.path.splitext(file.filename)[0]
        timestamp = time.strftime("%Y%m%d-%H%M%S")
        log_file = os.path.join(LOGS_FOLDER, f"{base_name}_{timestamp}.log")
        results_file = os.path.join(RESULTS_FOLDER, f"{base_name}_{timestamp}.jtl")

        # Comando para executar o JMeter em modo non-GUI
        # -n: non-GUI mode
        # -t: test plan file
        # -l: log/results file (JTL)
        # -j: jmeter log file
        if not JMETER_EXECUTABLE or (os.path.isabs(JMETER_EXECUTABLE) and not os.path.exists(JMETER_EXECUTABLE)) or \
           (not os.path.isabs(JMETER_EXECUTABLE) and not shutil.which(JMETER_EXECUTABLE)):
            return jsonify({"message": "Executável do JMeter não configurado ou não encontrado no servidor."}), 500

        # JMeter pode precisar de X11 mesmo em non-GUI em alguns casos, se plugins usarem.
        # Rodar com `xvfb-run` pode ajudar, mas é mais complexo de configurar.
        # Para scripts simples, -Djava.awt.headless=true é suficiente.
        jmeter_command = [
            JMETER_EXECUTABLE,
            '-Djava.awt.headless=true',
            '-n',
            '-t', filename,
            '-l', results_file,
            '-j', log_file
        ]
        
        try:
            print(f"Executando comando: {' '.join(jmeter_command)}")
            # Inicia o JMeter em background
            process = subprocess.Popen(jmeter_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            jmeter_process_pid = process.pid
            
            return jsonify({
                "message": f"Plano de teste '{file.filename}' carregado e JMeter iniciado.",
                "pid": jmeter_process_pid,
                "log_file": log_file,
                "results_file": results_file
            }), 200
        except Exception as e:
            jmeter_process_pid = None
            return jsonify({"message": f"Erro ao iniciar JMeter: {str(e)}"}), 500
    else:
        return jsonify({"message": "Arquivo inválido. Por favor, envie um arquivo .jmx"}), 400


@app.route('/stop_test', methods=['POST'])
def stop_test():
    global jmeter_process_pid

    if jmeter_process_pid is None:
        return jsonify({"message": "Nenhum teste JMeter em execução para parar."}), 404

    try:
        print(f"Tentando parar o processo JMeter com PID: {jmeter_process_pid}")
        
        # Tenta uma parada "graciosa" primeiro (se JMeter suportar SIGINT/SIGTERM para shutdown.sh)
        # Para parar JMeter de forma mais robusta, o ideal seria chamar o script `shutdown.sh` ou `stoptest.sh`
        # que vem com o JMeter, se eles estiverem configurados para funcionar remotamente ou via PID.
        # A forma mais simples é enviar um SIGTERM (ou SIGKILL se necessário).
        
        # JMeter tem scripts bin/stoptest.sh e bin/shutdown.sh.
        # stoptest.sh é para um shutdown gracioso (termina threads atuais).
        # shutdown.sh é um shutdown abrupto.
        # Eles geralmente funcionam por porta, não por PID direto, a menos que se configure JMeter para tal.
        # Por simplicidade, vamos matar o processo pelo PID. Isso é um SIGTERM.
        # Para um shutdown mais gracioso via script JMeter:
        # stop_command = os.path.join(JMETER_HOME, 'bin', 'stoptest.sh') if JMETER_HOME else shutil.which('stoptest.sh')
        # shutdown_command = os.path.join(JMETER_HOME, 'bin', 'shutdown.sh') if JMETER_HOME else shutil.which('shutdown.sh')
        # if stop_command and os.path.exists(stop_command):
        #    subprocess.run([stop_command], check=True)
        #    message = "Comando stoptest.sh enviado."
        # else: # Fallback para matar o processo
        #    os.kill(jmeter_process_pid, signal.SIGTERM) # Ou signal.SIGKILL para forçar
        #    message = f"Sinal SIGTERM enviado para o processo JMeter PID {jmeter_process_pid}."
        
        # Matar pelo PID é mais direto aqui, mas pode não ser o mais "limpo" para JMeter.
        os.kill(jmeter_process_pid, signal.SIGTERM) # Envia SIGTERM
        
        # Aguarda um pouco para o processo terminar
        time.sleep(2) 
        
        try:
            os.kill(jmeter_process_pid, 0) # Checa se ainda existe
            # Se ainda existe, pode ser necessário um SIGKILL
            print(f"Processo {jmeter_process_pid} ainda existe após SIGTERM. Enviando SIGKILL.")
            os.kill(jmeter_process_pid, signal.SIGKILL)
            message = f"Sinal SIGKILL enviado para forçar parada do JMeter PID {jmeter_process_pid}."
        except OSError:
            message = f"Processo JMeter PID {jmeter_process_pid} parado com sucesso."
        
        jmeter_process_pid = None
        return jsonify({"message": message}), 200
        
    except OSError as e:
        # Se o processo já não existe (ex: já terminou ou foi parado manualmente)
        if e.errno == errno.ESRCH: # No such process
             jmeter_process_pid = None
             return jsonify({"message": f"Processo JMeter com PID {jmeter_process_pid} não encontrado. Pode já ter sido parado."}), 404
        return jsonify({"message": f"Erro ao parar o processo JMeter: {str(e)}"}), 500
    except Exception as e:
        return jsonify({"message": f"Erro inesperado ao parar JMeter: {str(e)}"}), 500


if __name__ == '__main__':
    # Rodar em 0.0.0.0 para ser acessível externamente na EC2
    # Certifique-se que a porta 5001 está aberta no Security Group da EC2
    app.run(host='0.0.0.0', port=5001, debug=True) 
