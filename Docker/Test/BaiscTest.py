import time
import datetime
import sys

print("--- Iniciando o Container de Teste de Logs ---")
# O flush garante que o log apareça no CloudWatch sem atrasos
sys.stdout.flush()

while True:
    agora = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{agora}] ECS Log Test: O container está rodando perfeitamente.")
    sys.stdout.flush()
    time.sleep(30)
