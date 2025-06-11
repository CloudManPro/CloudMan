# load_tester.py - Versão 100% Autossuficiente
# Este script único serve a interface de controle HTML e executa a lógica do teste de carga.

import threading
import time
from flask import Flask, request, jsonify, Response
from flask_cors import CORS
import requests
from statistics import mean, stdev
from collections import Counter

# --- INÍCIO DO TEMPLATE HTML EMBUTIDO ---
# Todo o frontend (HTML, CSS, JS) é armazenado nesta string.
HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="pt-br">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Controle de Teste de Carga Python</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; margin: 0; padding: 20px; background-color: #f0f2f5; color: #1c1e21; display: flex; justify-content: center; align-items: flex-start; min-height: 100vh; }
        .container { background-color: #fff; padding: 25px 35px; border-radius: 8px; box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1); width: 100%; max-width: 900px; border: 1px solid #dddfe2; }
        h1 { text-align: center; color: #1877f2; margin-bottom: 25px; font-size: 24px; }
        h2 { color: #333; border-bottom: 2px solid #e9ecef; padding-bottom: 8px; margin-top: 25px; margin-bottom: 20px; font-size: 18px; }
        .input-group { margin-bottom: 15px; }
        .input-group label { display: block; margin-bottom: 8px; font-weight: 600; color: #606770; }
        .input-group input[type="text"], .input-group input[type="number"] { width: 100%; padding: 10px; border: 1px solid #ccd0d5; border-radius: 6px; box-sizing: border-box; font-size: 15px; }
        button { background-color: #1877f2; color: white; padding: 10px 15px; border: none; border-radius: 6px; cursor: pointer; font-size: 16px; font-weight: 600; margin-right: 10px; transition: background-color 0.2s, opacity 0.2s; }
        button:hover:not(:disabled) { background-color: #166fe5; }
        button:disabled { background-color: #e4e6eb; color: #bcc0c4; cursor: not-allowed; opacity: 0.7; }
        button.danger { background-color: #dc3545; }
        button.danger:hover:not(:disabled) { background-color: #c82333; }
        .columns-wrapper { display: flex; gap: 40px; }
        .column { flex: 1; }
        #summaryContent, #statusMessage { white-space: pre-wrap; word-wrap: break-word; background-color: #f7f7f7; padding: 15px; border-radius: 5px; border: 1px solid #dddfe2; font-family: monospace; font-size: 13px; }
        #summaryContent { min-height: 150px; }
        #statusMessage { min-height: 50px; margin-top: 10px; }
        .test-status-display { font-weight: bold; padding: 8px 0; margin-bottom: 10px; font-size: 1.1em; text-align: center; border-radius: 4px; }
        .status-running { color: #fff; background-color: #28a745; }
        .status-stopping { color: #000; background-color: #ffc107; }
        .status-finished { color: #fff; background-color: #007bff; }
        .status-idle { color: #6c757d; background-color: #f8f9fa; border: 1px solid #dee2e6; }
        .status-error { color: #fff; background-color: #dc3545; }
        @media (max-width: 768px) { .columns-wrapper { flex-direction: column; gap: 0; } }
    </style>
</head>
<body>
    <div class="container">
        <h1>Painel de Teste de Carga</h1>
        <div class="columns-wrapper">
            <div class="column">
                <h2>Parâmetros do Teste</h2>
                <div class="input-group">
                    <label for="targetHost">URL Alvo:</label>
                    <input type="text" id="targetHost" placeholder="https://seu-site.com">
                </div>
                <div class="input-group">
                    <label for="numUsers">Usuários Concorrentes:</label>
                    <input type="number" id="numUsers" value="10" min="1">
                </div>
                <h2>Ações de Controle</h2>
                <div>
                    <button id="startTestBtn">Iniciar Teste</button>
                    <button id="stopTestBtn">Parar Teste</button>
                </div>
                <div style="margin-top: 15px;">
                     <button id="forceResetBtn" class="danger">Reset Forçado</button>
                </div>
            </div>
            <div class="column">
                <h2>Status do Teste</h2>
                <div id="testStatusDisplay" class="test-status-display status-idle">Inativo</div>
                <h3>Resumo em Tempo Real</h3>
                <div id="summaryContent">Aguardando início do teste...</div>
                <h3>Mensagens do Servidor</h3>
                <pre id="statusMessage">Aguardando ações...</pre>
            </div>
        </div>
    </div>
    <script>
        document.addEventListener('DOMContentLoaded', () => {
            const ge = id => document.getElementById(id);
            const targetHostInput = ge('targetHost'), numUsersInput = ge('numUsers');
            const startTestBtn = ge('startTestBtn'), stopTestBtn = ge('stopTestBtn'), forceResetBtn = ge('forceResetBtn');
            const testStatusDisplay = ge('testStatusDisplay'), summaryContent = ge('summaryContent'), statusMessage = ge('statusMessage');
            
            let pollInterval = null;

            const states = {
                idle: { label: 'Inativo', class: 'status-idle', isBusy: false, isRunning: false },
                running: { label: 'Em Execução', class: 'status-running', isBusy: true, isRunning: true },
                stopping: { label: 'Parando...', class: 'status-stopping', isBusy: true, isRunning: false },
                finished: { label: 'Finalizado', class: 'status-finished', isBusy: false, isRunning: false },
                error: { label: 'Erro', class: 'status-error', isBusy: false, isRunning: false }
            };

            function setTestState(state) {
                testStatusDisplay.textContent = state.label;
                testStatusDisplay.className = `test-status-display ${state.class}`;
                startTestBtn.disabled = state.isBusy;
                stopTestBtn.disabled = !state.isRunning;
                forceResetBtn.disabled = !state.isRunning && !state.isBusy;

                if (state.isRunning && !pollInterval) {
                    pollInterval = setInterval(fetchStatus, 2000);
                } else if (!state.isRunning && pollInterval) {
                    clearInterval(pollInterval);
                    pollInterval = null;
                }
            }

            async function fetchData(endpoint, options = {}) {
                try {
                    const response = await fetch(endpoint, options);
                    const data = await response.json();
                    if (!response.ok) throw new Error(data.error || data.message || `Erro ${response.status}`);
                    statusMessage.textContent = `Sucesso: ${data.message}`;
                    fetchStatus();
                } catch (error) {
                    console.error('Fetch Error:', error);
                    statusMessage.textContent = `Falha: ${error.message}`;
                    setTestState(states.error);
                }
            }

            async function fetchStatus() {
                try {
                    const response = await fetch('/get_status');
                    const data = await response.json();
                    if (!response.ok) throw new Error(data.error);

                    setTestState(states[data.status] || states.error);
                    
                    const summary = data.summary;
                    let summaryHtml = "Aguardando dados...";
                    if (summary && summary.total_requests !== undefined) {
                        summaryHtml = 
                            `<strong>Requisições Totais:</strong> ${summary.total_requests}\\n` +
                            `<strong>Sucesso/Falha:</strong> ${summary.success_requests} / ${summary.failed_requests}\\n` +
                            `<strong>Reqs/Seg:</strong> ${summary.requests_per_second.toFixed(2)}\\n\\n` +
                            `<strong>Tempo Médio (ms):</strong> ${summary.avg_response_time_ms.toFixed(2)}\\n` +
                            `<strong>Tempo Mín/Máx (ms):</strong> ${summary.min_response_time_ms.toFixed(2)} / ${summary.max_response_time_ms.toFixed(2)}\\n\\n` +
                            `<strong>Códigos de Status:</strong> ${JSON.stringify(summary.status_code_counts)}`;
                    }
                    summaryContent.textContent = summaryHtml;

                } catch (error) {
                    console.error('Status Check Error:', error.message);
                    setTestState(states.error);
                    statusMessage.textContent = 'Perda de comunicação com o servidor.';
                }
            }

            startTestBtn.addEventListener('click', () => {
                const formData = new FormData();
                formData.append('targetHost', targetHostInput.value);
                formData.append('numUsers', numUsersInput.value);
                fetchData('/start_test', { method: 'POST', body: formData });
            });

            stopTestBtn.addEventListener('click', () => fetchData('/stop_test', { method: 'POST' }));
            forceResetBtn.addEventListener('click', () => {
                if (confirm('ATENÇÃO! Isso irá resetar o teste. Deseja continuar?')) {
                    fetchData('/force_reset', { method: 'POST' });
                }
            });

            const fieldsToPersist = ['targetHost', 'numUsers'];
            fieldsToPersist.forEach(id => {
                const element = ge(id);
                const savedValue = localStorage.getItem(`loadtest_${id}`);
                if (savedValue) element.value = savedValue;
                element.addEventListener('change', () => localStorage.setItem(`loadtest_${id}`, element.value));
            });

            setTestState(states.idle);
            setTimeout(fetchStatus, 500);
        });
    </script>
</body>
</html>
"""
# --- FIM DO TEMPLATE HTML EMBUTIDO ---

# --- Configuração da Aplicação Flask ---
app = Flask(__name__)
CORS(app)

# --- Lógica do Teste de Carga (idêntica à versão anterior) ---
# Estado Global Compartilhado
test_state = {
    "status": "idle", "threads": [], "results": [], "start_time": None
}
state_lock = threading.Lock()
stop_event = threading.Event()

def worker(url, delay_ms):
    with requests.Session() as session:
        while not stop_event.is_set():
            start_time = time.time()
            status_code = -1
            try:
                response = session.get(url, timeout=30)
                status_code = response.status_code
            except requests.exceptions.RequestException:
                pass
            finally:
                response_time = time.time() - start_time
                with state_lock:
                    test_state["results"].append((status_code, response_time))
            time.sleep(delay_ms / 1000.0)

# --- Endpoints da API ---
@app.route('/')
def index():
    """Serve a interface de controle HTML."""
    return Response(HTML_TEMPLATE, mimetype='text/html')

@app.route('/start_test', methods=['POST'])
def start_test():
    with state_lock:
        if test_state["status"] == "running":
            return jsonify({"error": "Um teste já está em execução."}), 409

        stop_event.clear()
        test_state.update({
            "status": "running", "threads": [], "results": [], "start_time": time.time()
        })

        target_url = request.form.get('targetHost')
        num_users = int(request.form.get('numUsers', 10))
        # O delay pode ser adicionado aqui se necessário
        # delay_ms = int(request.form.get('delay', 0)) 

        if not target_url:
            return jsonify({"error": "A URL alvo é obrigatória."}), 400

        for _ in range(num_users):
            thread = threading.Thread(target=worker, args=(target_url, 0), daemon=True) # Delay 0 por padrão
            thread.start()
            test_state["threads"].append(thread)
            
        return jsonify({"message": f"Teste iniciado com {num_users} usuários."})

# Os endpoints /stop_test, /force_reset e /get_status permanecem os mesmos da versão anterior.
@app.route('/stop_test', methods=['POST'])
def stop_test():
    with state_lock:
        if test_state["status"] != "running": return jsonify({"message": "Nenhum teste em execução."})
        test_state["status"] = "stopping"
        stop_event.set()
    return jsonify({"message": "Sinal de parada enviado."})

@app.route('/force_reset', methods=['POST'])
def force_reset():
    with state_lock:
        stop_event.set()
        test_state.update({"status": "idle", "threads": [], "results": [], "start_time": None})
    return jsonify({"message": "Servidor resetado."})

@app.route('/get_status', methods=['GET'])
def get_status():
    with state_lock:
        results_copy = list(test_state["results"])
        status = test_state["status"]
        start_time = test_state["start_time"]
        # Se todas as threads terminaram, muda o status
        if status == 'running' and not any(t.is_alive() for t in test_state["threads"]):
            status = 'finished'
            test_state['status'] = 'finished'

    summary = {}
    if results_copy and (status == "running" or status == "finished"):
        response_times = [r[1] for r in results_copy if r[0] != -1]
        status_codes = [r[0] for r in results_copy]
        duration = time.time() - start_time if start_time else 0
        summary = {
            "total_requests": len(results_copy),
            "success_requests": len(response_times),
            "failed_requests": len(results_copy) - len(response_times),
            "requests_per_second": len(results_copy) / duration if duration > 0 else 0,
            "avg_response_time_ms": mean(response_times) * 1000 if response_times else 0,
            "min_response_time_ms": min(response_times) * 1000 if response_times else 0,
            "max_response_time_ms": max(response_times) * 1000 if response_times else 0,
            "status_code_counts": dict(Counter(status_codes))
        }
    return jsonify({"status": status, "summary": summary})


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5001)
