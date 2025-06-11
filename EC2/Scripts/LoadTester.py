import threading
import time
import requests
import logging
from flask import Flask, jsonify, request, redirect, url_for

# --- 1. Configuração do Logging Detalhado ---
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - [%(threadName)s] - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)

# --- 2. Conteúdo HTML da Interface (embutido no código Python) ---
HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Ferramenta de Teste de Carga</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; line-height: 1.6; margin: 20px; background-color: #f4f7f9; color: #333; }
        .container { max-width: 650px; margin: auto; background: #fff; padding: 25px 30px; border-radius: 8px; box-shadow: 0 4px 10px rgba(0,0,0,0.05); }
        h1, h2 { color: #2c3e50; border-bottom: 2px solid #e0e0e0; padding-bottom: 10px; }
        .form-group { margin-bottom: 15px; }
        .form-group label { display: block; margin-bottom: 5px; font-weight: bold; }
        .form-group input { width: 95%; padding: 12px; border: 1px solid #ccc; border-radius: 4px; transition: border-color 0.3s; }
        .form-group input:focus { border-color: #3498db; outline: none; }
        .button-group { display: flex; gap: 10px; margin-top: 20px; }
        .btn { flex-grow: 1; padding: 12px 15px; border: none; border-radius: 4px; color: #fff; cursor: pointer; font-size: 16px; font-weight: bold; transition: background-color 0.3s, transform 0.1s; }
        .btn:active { transform: scale(0.98); }
        .btn-start { background-color: #27ae60; }
        .btn-start:hover { background-color: #229954; }
        .btn-stop { background-color: #c0392b; }
        .btn-stop:hover { background-color: #a93226; }
        .results { margin-top: 30px; padding: 20px; border: 1px solid #e0e0e0; border-radius: 4px; background-color: #fafafa; }
        .bar { padding: 12px; border-radius: 4px; margin-bottom: 10px; font-weight: 500; }
        #status-bar { background-color: #e9ecef; color: #495057; border-left: 5px solid #6c757d; }
        #success-bar { background-color: #d4edda; color: #155724; border-left: 5px solid #28a745; }
        #error-bar { background-color: #f8d7da; color: #721c24; border-left: 5px solid #dc3545; }
    </style>
</head>
<body>
<div class="container">
    <h1>Ferramenta de Teste de Carga</h1>
    <div class="configuracao">
        <h2>Configuração do Teste</h2>
        <form id="start-form" action="/start_test" method="post">
            <div class="form-group">
                <label for="url">URL de Destino</label>
                <input type="text" id="url" name="url" value="https://google.com" required>
            </div>
            <div class="form-group">
                <label for="users">Usuários Virtuais</label>
                <input type="number" id="users" name="users" value="10" min="1" required>
            </div>
            <div class="form-group">
                <label for="requests">Requisições por Usuário</label>
                <input type="number" id="requests" name="requests" value="5" min="1" required>
            </div>
            <div class="form-group">
                <label for="rampup">Ramp-up (s)</label>
                <input type="number" id="rampup" name="rampup" value="5" min="0" required>
            </div>
        </form>
        <div class="button-group">
            <button type="submit" form="start-form" class="btn btn-start">Iniciar Teste</button>
            <form action="/stop_test" method="post" style="flex-grow: 1; margin: 0;">
                <button type="submit" class="btn btn-stop">Parar Teste</button>
            </form>
        </div>
    </div>
    <div class="results">
        <h2>Resultados em Tempo Real</h2>
        <div id="status-bar" class="bar">Status: Ocioso</div>
        <div id="success-bar" class="bar">Sucessos: 0</div>
        <div id="error-bar" class="bar">Erros: 0</div>
    </div>
</div>
<script>
    function updateStatus() {
        fetch('/status')
            .then(response => {
                if (!response.ok) {
                    throw new Error('Network response was not ok');
                }
                return response.json();
            })
            .then(data => {
                document.getElementById('status-bar').textContent = 'Status: ' + data.status_message;
                document.getElementById('success-bar').textContent = 'Sucessos: ' + data.success;
                document.getElementById('error-bar').textContent = 'Erros: ' + data.error;
            })
            .catch(error => {
                console.error('Erro ao buscar status:', error);
                document.getElementById('status-bar').textContent = 'Status: Erro de comunicação com o servidor.';
            });
    }
    // Atualiza o status a cada 1 segundo
    setInterval(updateStatus, 1000);
    // Chama uma vez no início para carregar o estado inicial
    document.addEventListener('DOMContentLoaded', updateStatus);
</script>
</body>
</html>
"""

# --- 3. Classe Gerenciadora de Teste (o "cérebro" da aplicação) ---
class TestManager:
    def __init__(self):
        self._lock = threading.Lock()
        self._test_thread = None
        self._is_running = False
        self._stats = {"success": 0, "error": 0, "total": 0, "status_message": "Ocioso"}

    def start_test(self, params):
        with self._lock:
            if self._is_running:
                logging.warning("Tentativa de iniciar um teste enquanto outro já está em execução. Ação ignorada.")
                return
            logging.info(f"Iniciando um novo teste de carga com os parâmetros: {params}")
            self._is_running = True
            self._stats = {
                "success": 0, "error": 0,
                "total": params.get('virtual_users', 0) * params.get('requests_per_user', 0),
                "status_message": f"Iniciando... Ramp-up de {params.get('ramp_up', 0)}s"
            }
            self._test_thread = threading.Thread(target=self._worker, args=(params,), name="LoadTestWorker", daemon=True)
            self._test_thread.start()
            logging.info(f"Thread de teste '{self._test_thread.name}' iniciada com sucesso.")

    def stop_test(self):
        logging.info("Recebido pedido para parar o teste.")
        thread_to_join = None
        with self._lock:
            if not self._is_running:
                logging.warning("Tentativa de parar um teste que não está em execução.")
                return
            self._is_running = False
            self._stats["status_message"] = "Parando..."
            thread_to_join = self._test_thread
        
        if thread_to_join:
            logging.info(f"Aguardando a thread '{thread_to_join.name}' finalizar...")
            thread_to_join.join(timeout=10.0)
            if thread_to_join.is_alive():
                logging.error("A THREAD DE TESTE NÃO PAROU A TEMPO! Pode estar presa em uma operação de rede.")
            else:
                logging.info("Thread de teste finalizada com sucesso.")
        with self._lock:
            self._test_thread = None
            self._stats["status_message"] = "Ocioso"

    def get_status(self):
        with self._lock:
            return self._stats.copy()

    def _worker(self, params):
        try:
            logging.info("Worker de teste iniciado.")
            target_url, v_users, req_per_user, ramp_up = \
                params['target_url'], params['virtual_users'], params['requests_per_user'], params['ramp_up']
            
            sleep_between = ramp_up / (v_users - 1) if ramp_up > 0 and v_users > 1 else 0

            for i in range(v_users):
                if not self._is_running:
                    logging.info("Sinal de parada detectado durante o ramp-up. Saindo...")
                    break
                logging.info(f"Iniciando usuário virtual {i + 1}/{v_users}")
                
                for j in range(req_per_user):
                    if not self._is_running:
                        logging.info(f"Sinal de parada detectado antes da requisição {j + 1}. Saindo...")
                        break
                    
                    with self._lock:
                        progress = self._stats['success'] + self._stats['error']
                        self._stats["status_message"] = f"Em andamento... ({progress}/{self._stats['total']})"
                    
                    try:
                        requests.get(target_url, timeout=5)
                        with self._lock: self._stats["success"] += 1
                    except requests.RequestException as e:
                        logging.warning(f"Erro na requisição para {target_url}: {e}")
                        with self._lock: self._stats["error"] += 1
                
                if i < v_users - 1 and self._is_running:
                    time.sleep(sleep_between)
        
        except Exception as e:
            logging.error(f"Erro inesperado no worker do teste: {e}", exc_info=True)
        
        finally:
            with self._lock:
                self._is_running = False
                if self._stats["status_message"] not in ["Ocioso", "Parando..."]:
                     self._stats["status_message"] = "Finalizado"
            logging.info("Worker de teste finalizado.")

# --- 4. Configuração do Flask e Rotas ---
app = Flask(__name__)
test_manager = TestManager()

@app.route('/')
def index():
    # Retorna o conteúdo HTML diretamente da string, sem precisar de arquivos externos
    return HTML_TEMPLATE

@app.route('/start_test', methods=['POST'])
def start_test():
    params = {
        'target_url': request.form.get('url'),
        'virtual_users': int(request.form.get('users', 10)),
        'requests_per_user': int(request.form.get('requests', 5)),
        'ramp_up': int(request.form.get('rampup', 5))
    }
    test_manager.start_test(params)
    return redirect(url_for('index'))

@app.route('/stop_test', methods=['POST'])
def stop_test():
    test_manager.stop_test()
    return redirect(url_for('index'))

@app.route('/status')
def status():
    return jsonify(test_manager.get_status())

@app.route('/health')
def health_check():
    return "OK", 200

if __name__ == '__main__':
    # Esta parte é para rodar localmente, não será usada pelo systemd
    logging.info("Aplicação Flask iniciando em modo de desenvolvimento.")
    app.run(host='0.0.0.0', port=5000, debug=False)
