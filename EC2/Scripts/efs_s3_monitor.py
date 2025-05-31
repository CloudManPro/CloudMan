import time
import logging
import subprocess
import os
import fnmatch
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
import shutil # Para initial_sync se usar aws s3 sync e precisar do path do CLI

# Configuration (Read from environment variables passed by systemd service)
MONITOR_DIR_BASE = os.environ.get('WP_MONITOR_DIR_BASE', '/var/www/html')
S3_BUCKET = os.environ.get('WP_S3_BUCKET')
RELEVANT_PATTERNS_STR = os.environ.get('WP_RELEVANT_PATTERNS', '')
LOG_FILE_MONITOR = os.environ.get(
    'WP_PY_MONITOR_LOG_FILE', '/var/log/wp_efs_s3_py_monitor.log')
S3_TRANSFER_LOG = os.environ.get(
    'WP_PY_S3_TRANSFER_LOG', '/var/log/wp_s3_py_transferred.log')
SYNC_DEBOUNCE_SECONDS = int(os.environ.get('WP_SYNC_DEBOUNCE_SECONDS', '5'))
AWS_CLI_PATH = os.environ.get('WP_AWS_CLI_PATH', 'aws') # Usar o que foi detectado pelo bash
DELETE_FROM_EFS_AFTER_SYNC = os.environ.get('WP_DELETE_FROM_EFS_AFTER_SYNC', 'false').lower() == 'true'
PERFORM_INITIAL_SYNC = os.environ.get('WP_PERFORM_INITIAL_SYNC', 'true').lower() == 'true'


RELEVANT_PATTERNS = [p.strip()
                     for p in RELEVANT_PATTERNS_STR.split(';') if p.strip()]
last_sync_file_map = {}


def setup_logger(name, log_file, level=logging.INFO, formatter_str='%(asctime)s - %(name)s - %(levelname)s - %(message)s'):
    log_dir = os.path.dirname(log_file)
    if log_dir and not os.path.exists(log_dir):
        try:
            os.makedirs(log_dir, exist_ok=True)
            os.chmod(log_dir, 0o755) # Permissão mais comum para diretórios de log
        except Exception as e:
            print(f"Error creating log directory {log_dir}: {e}")
            # Fallback to /tmp if /var/log is not writable (e.g. permissions issue)
            log_file = os.path.join("/tmp", os.path.basename(log_file))
            print(f"Falling back to log file: {log_file}")
    try:
        # Touch the file and set permissions
        with open(log_file, 'a'):
            os.utime(log_file, None)
        os.chmod(log_file, 0o644) # Permissão mais comum para arquivos de log
    except Exception as e:
        print(f"Error touching/chmod log file {log_file}: {e}")

    logger = logging.getLogger(name)
    logger.setLevel(level)
    if not logger.hasHandlers(): # Evitar adicionar handlers duplicados
        handler = logging.FileHandler(log_file, mode='a')
        handler.setFormatter(logging.Formatter(formatter_str))
        logger.addHandler(handler)
    return logger


monitor_logger = setup_logger('PY_MONITOR', LOG_FILE_MONITOR)
transfer_logger = setup_logger(
    'PY_S3_TRANSFER', S3_TRANSFER_LOG, formatter_str='%(asctime)s - %(message)s')


def is_path_relevant(path_to_check, base_dir, patterns):
    if not path_to_check.startswith(base_dir + os.path.sep):
        return False, None
    relative_file_path = os.path.relpath(path_to_check, base_dir)
    return any(fnmatch.fnmatch(relative_file_path, pattern) for pattern in patterns), relative_file_path

class Watcher(FileSystemEventHandler):
    def _is_excluded(self, filepath):
        filename = os.path.basename(filepath)
        # Excluir arquivos temporários, de backup, parciais de download, etc.
        if filename.startswith('.') or filename.endswith(('.swp', '.swx', '~', '.part', '.crdownload', '.tmp')):
            return True
        # Excluir diretórios comuns de cache ou desenvolvimento que não devem ir para S3 (a menos que especificado)
        if '/cache/' in filepath or '/.git/' in filepath or '/node_modules/' in filepath:
            return True
        if '/uploads/sites/' in filepath: # Exemplo para Multisite, ajuste conforme necessário
             monitor_logger.debug(f"Excluding Multisite sub-site upload path: {filepath}")
             return True
        return False

    def _get_s3_path(self, relative_file_path):
        return f"s3://{S3_BUCKET}/{relative_file_path}"

    def _handle_s3_upload(self, local_path, relative_file_path):
        current_time = time.time()
        if local_path in last_sync_file_map and \
           (current_time - last_sync_file_map[local_path] < SYNC_DEBOUNCE_SECONDS):
            monitor_logger.info(f"Debounce for '{local_path}'. Skipped.")
            return

        s3_dest_path = self._get_s3_path(relative_file_path)
        monitor_logger.info(f"Copying '{local_path}' to '{s3_dest_path}'...")

        try:
            process = subprocess.run(
                [AWS_CLI_PATH, 's3', 'cp', local_path, s3_dest_path,
                 '--acl', 'private', '--only-show-errors'], # Adicionado --only-show-errors
                capture_output=True, text=True, check=False # check=False para pegar o erro manualmente
            )

            if process.returncode == 0:
                monitor_logger.info(f"S3 copy OK for '{relative_file_path}'.")
                transfer_logger.info(f"TRANSFERRED: {relative_file_path} to {s3_dest_path}")
                last_sync_file_map[local_path] = current_time
                if DELETE_FROM_EFS_AFTER_SYNC:
                    try:
                        os.remove(local_path)
                        monitor_logger.info(f"Successfully deleted '{local_path}' from EFS (DELETE_FROM_EFS_AFTER_SYNC=true).")
                        transfer_logger.info(f"DELETED_EFS: {relative_file_path}")
                    except OSError as e:
                        monitor_logger.error(f"Failed to delete '{local_path}' from EFS: {e}")
            else:
                monitor_logger.error(
                    f"S3 copy FAILED for '{relative_file_path}'. RC: {process.returncode}. Stdout: {process.stdout.strip()}. Stderr: {process.stderr.strip()}")
        except FileNotFoundError:
             monitor_logger.error(f"AWS CLI not found at '{AWS_CLI_PATH}'. S3 copy failed for '{relative_file_path}'.")
        except Exception as e:
            monitor_logger.error(f"Exception during S3 copy for {relative_file_path}: {e}", exc_info=True)


    def _handle_s3_delete(self, relative_file_path):
        s3_target_path = self._get_s3_path(relative_file_path)
        monitor_logger.info(f"Deleting '{s3_target_path}' from S3...")
        try:
            process = subprocess.run(
                [AWS_CLI_PATH, 's3', 'rm', s3_target_path, '--only-show-errors'],
                capture_output=True, text=True, check=False
            )
            if process.returncode == 0:
                monitor_logger.info(f"S3 delete OK for '{relative_file_path}'.")
                transfer_logger.info(f"DELETED_S3: {relative_file_path}")
            else:
                # s3 rm pode retornar 255 se o arquivo não existir, o que é OK se já foi deletado
                if process.returncode == 255 and "NoSuchKey" in process.stderr: # Aproximação, AWS CLI pode não ter NoSuchKey no stderr
                     monitor_logger.info(f"S3 delete for '{relative_file_path}' indicated file not found (RC: {process.returncode}). Assuming already deleted or never existed. Stderr: {process.stderr.strip()}")
                     transfer_logger.info(f"DELETED_S3_NOT_FOUND: {relative_file_path}")
                else:
                    monitor_logger.error(
                        f"S3 delete FAILED for '{relative_file_path}'. RC: {process.returncode}. Stderr: {process.stderr.strip()}")
        except FileNotFoundError:
             monitor_logger.error(f"AWS CLI not found at '{AWS_CLI_PATH}'. S3 delete failed for '{relative_file_path}'.")
        except Exception as e:
            monitor_logger.error(f"Exception during S3 delete for {relative_file_path}: {e}", exc_info=True)

    def process_event_for_sync(self, event_type, path):
        if self._is_excluded(path) or os.path.isdir(path): # Também ignorar diretórios aqui
            # monitor_logger.debug(f"Ignoring excluded/directory for event: {event_type} for {path}")
            return

        relevant, relative_path = is_path_relevant(path, MONITOR_DIR_BASE, RELEVANT_PATTERNS)
        if not relevant:
            # monitor_logger.debug(f"File '{path}' (relative: {relative_path}) not relevant for {event_type}. Ignored.")
            return

        monitor_logger.info(f"Event: {event_type.upper()} for relevant file '{relative_path}' (full: {path})")

        if event_type in ['created', 'modified', 'moved_to']: # moved_to é o destino de um 'moved'
            self._handle_s3_upload(path, relative_path)
        elif event_type == 'deleted':
            self._handle_s3_delete(relative_path)

    def on_created(self, event):
        if not event.is_directory:
            self.process_event_for_sync('created', event.src_path)

    def on_modified(self, event):
        if not event.is_directory:
            self.process_event_for_sync('modified', event.src_path)

    def on_deleted(self, event):
        if not event.is_directory:
            self.process_event_for_sync('deleted', event.src_path)

    def on_moved(self, event):
        if not event.is_directory:
            # Um 'moved' é um 'deleted' no src_path e um 'created' (ou 'moved_to') no dest_path
            # Tratar a deleção do local antigo
            relevant_src, relative_src_path = is_path_relevant(event.src_path, MONITOR_DIR_BASE, RELEVANT_PATTERNS)
            if relevant_src and not self._is_excluded(event.src_path): # Verificar exclusão também para o source
                monitor_logger.info(f"Event: MOVED (source part) for relevant file '{relative_src_path}' (full: {event.src_path})")
                self._handle_s3_delete(relative_src_path) # Deletar o antigo do S3

            # Tratar a criação/modificação no novo local
            self.process_event_for_sync('moved_to', event.dest_path) # O dest_path será tratado como upload

def perform_initial_sync():
    monitor_logger.info("--- Starting Initial S3 Sync ---")
    if not S3_BUCKET:
        monitor_logger.error("S3_BUCKET not configured. Skipping initial sync.")
        return

    # Usando aws s3 sync para eficiência
    s3_sync_command = [
        AWS_CLI_PATH, 's3', 'sync',
        MONITOR_DIR_BASE,
        f"s3://{S3_BUCKET}/",
        '--acl', 'private',
        '--only-show-errors',
        # '--delete' # NÃO USAR --delete aqui, pois deletaria do S3 o que não existe no EFS.
                      # O objetivo é popular o S3 com o que está no EFS.
    ]
    # Adicionar includes e excludes baseados em RELEVANT_PATTERNS
    # O aws s3 sync trata includes/excludes de forma um pouco diferente de fnmatch
    # Por simplicidade, vamos sincronizar tudo que *não* for explicitamente excluído pelas regras de _is_excluded
    # E então confiar que os RELEVANT_PATTERNS serão usados pelo watcher para uploads futuros.
    # Para uma sincronização inicial que respeite RELEVANT_PATTERNS com `aws s3 sync`,
    # seria preciso converter os fnmatch para padrões do AWS CLI e usar múltiplos --exclude e --include.
    # Exemplo simplificado (pode precisar de ajuste fino para os padrões):
    # s3_sync_command.extend(['--exclude', '*']) # Exclui tudo por padrão
    # for pattern in RELEVANT_PATTERNS:
    # s3_sync_command.extend(['--include', pattern])

    # Alternativa: iterar e copiar individualmente (mais lento, mas usa a mesma lógica de relevância)
    files_synced = 0
    files_failed = 0
    for root, _, filenames in os.walk(MONITOR_DIR_BASE):
        for filename in filenames:
            local_path = os.path.join(root, filename)
            if Watcher()._is_excluded(local_path): # Reutilizar a lógica de exclusão
                continue

            relevant, relative_path = is_path_relevant(local_path, MONITOR_DIR_BASE, RELEVANT_PATTERNS)
            if relevant:
                # Para a sincronização inicial, não queremos deletar do EFS.
                # Temporariamente "desligar" a deleção do EFS se estiver ativa.
                original_delete_efs_setting = DELETE_FROM_EFS_AFTER_SYNC
                globals()['DELETE_FROM_EFS_AFTER_SYNC'] = False # Hackish, melhor passar como arg

                monitor_logger.info(f"[Initial Sync] Processing: {relative_path}")
                Watcher()._handle_s3_upload(local_path, relative_path) # Reutilizar a lógica de upload
                
                # Restaurar a configuração original
                globals()['DELETE_FROM_EFS_AFTER_SYNC'] = original_delete_efs_setting
                
                # Verificar se foi bem sucedido olhando o log ou o last_sync_file_map (complexo aqui)
                # Simplificadamente, vamos apenas contar. Para mais robustez, _handle_s3_upload precisaria retornar status.
                files_synced +=1 # Assumindo que _handle_s3_upload loga erros
            # else:
                # monitor_logger.debug(f"[Initial Sync] Skipping non-relevant: {local_path}")


    monitor_logger.info(f"--- Initial S3 Sync Attempted --- Files processed for sync: {files_synced}. Check logs for individual statuses.")
    # Se usasse `aws s3 sync`:
    # try:
    #     monitor_logger.info(f"Executing: {' '.join(s3_sync_command)}")
    #     process = subprocess.run(s3_sync_command, capture_output=True, text=True, check=False)
    #     if process.returncode == 0:
    #         monitor_logger.info("Initial S3 sync completed successfully.")
    #         transfer_logger.info("INITIAL_SYNC_SUCCESS")
    #     else:
    #         monitor_logger.error(f"Initial S3 sync FAILED. RC: {process.returncode}. Stdout: {process.stdout.strip()}. Stderr: {process.stderr.strip()}")
    #         transfer_logger.info(f"INITIAL_SYNC_FAILED: RC={process.returncode} ERR={process.stderr.strip()}")
    # except FileNotFoundError:
    #     monitor_logger.error(f"AWS CLI not found at '{AWS_CLI_PATH}'. Initial S3 sync failed.")
    # except Exception as e:
    #     monitor_logger.error(f"Exception during initial S3 sync: {e}", exc_info=True)


if __name__ == "__main__":
    monitor_logger.info(
        f"Python Watchdog Monitor (v2.3.1 - Enhanced w/ Deletion & Initial Sync) starting for '{MONITOR_DIR_BASE}'.")
    monitor_logger.info(f"S3 Bucket: {S3_BUCKET}")
    monitor_logger.info(f"Relevant Patterns (raw): {RELEVANT_PATTERNS_STR}")
    monitor_logger.info(f"Relevant Patterns (parsed): {RELEVANT_PATTERNS}")
    monitor_logger.info(f"Delete from EFS after sync: {DELETE_FROM_EFS_AFTER_SYNC}")
    monitor_logger.info(f"Perform initial sync: {PERFORM_INITIAL_SYNC}")


    if not S3_BUCKET or not RELEVANT_PATTERNS_STR:
        monitor_logger.critical(
            "S3_BUCKET or WP_RELEVANT_PATTERNS environment variables not set. Exiting.")
        exit(1)
    if not os.path.isdir(MONITOR_DIR_BASE):
        monitor_logger.critical(
            f"Monitor directory '{MONITOR_DIR_BASE}' does not exist. Exiting.")
        exit(1)
    
    aws_cli_actual_path = shutil.which(AWS_CLI_PATH) # Verifica se o AWS_CLI_PATH é executável e no PATH
    if not aws_cli_actual_path:
        monitor_logger.critical(f"AWS CLI not found at '{AWS_CLI_PATH}' or not in PATH. Please check WP_AWS_CLI_PATH. Exiting.")
        exit(1)
    else:
        AWS_CLI_PATH = aws_cli_actual_path # Usa o caminho absoluto encontrado
        monitor_logger.info(f"Using AWS CLI at: {AWS_CLI_PATH}")


    if PERFORM_INITIAL_SYNC:
        perform_initial_sync()

    event_handler = Watcher()
    observer = Observer()
    observer.schedule(event_handler, MONITOR_DIR_BASE, recursive=True)

    try:
        observer.start()
        monitor_logger.info("Observer started. Monitoring for file changes...")
        while observer.is_alive():
            observer.join(1)
    except KeyboardInterrupt:
        monitor_logger.info(
            "Keyboard interrupt received. Stopping observer...")
    except Exception as e:
        monitor_logger.critical(
            f"Critical error in observer loop: {e}", exc_info=True)
    finally:
        if observer.is_alive():
            observer.stop()
        observer.join()
        monitor_logger.info("Observer stopped and joined. Exiting.")
