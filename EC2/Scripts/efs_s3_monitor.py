import time
import logging
import subprocess
import os
import fnmatch
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
import shutil # Para shutil.which
import boto3 # Para interagir com S3 e CloudFront via API

# --- Configuration (Read from environment variables passed by systemd service) ---
MONITOR_DIR_BASE = os.environ.get('WP_MONITOR_DIR_BASE', '/var/www/html')
S3_BUCKET = os.environ.get('WP_S3_BUCKET')
RELEVANT_PATTERNS_STR = os.environ.get('WP_RELEVANT_PATTERNS', '')
LOG_FILE_MONITOR = os.environ.get(
    'WP_PY_MONITOR_LOG_FILE', '/var/log/wp_efs_s3_py_monitor_default.log')
S3_TRANSFER_LOG = os.environ.get(
    'WP_PY_S3_TRANSFER_LOG', '/var/log/wp_s3_py_transferred_default.log')
SYNC_DEBOUNCE_SECONDS = int(os.environ.get('WP_SYNC_DEBOUNCE_SECONDS', '5'))
AWS_CLI_PATH = os.environ.get('WP_AWS_CLI_PATH', 'aws')

# Novas configurações para controle fino
DELETE_FROM_EFS_AFTER_SYNC = os.environ.get('WP_DELETE_FROM_EFS_AFTER_SYNC', 'false').lower() == 'true'
PERFORM_INITIAL_SYNC = os.environ.get('WP_PERFORM_INITIAL_SYNC', 'true').lower() == 'true'
CLOUDFRONT_DISTRIBUTION_ID = os.environ.get('AWS_CLOUDFRONT_DISTRIBUTION_TARGET_ID_0')

# Lista de extensões de IMAGEM que podem ser deletadas do EFS se DELETE_FROM_EFS_AFTER_SYNC=true
DELETABLE_IMAGE_EXTENSIONS_FROM_EFS = [
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.ico', '.svg'
]

RELEVANT_PATTERNS = [p.strip()
                     for p in RELEVANT_PATTERNS_STR.split(';') if p.strip()]
last_sync_file_map = {}

# --- Logger Setup ---
def setup_logger(name, log_file, level=logging.INFO, formatter_str='%(asctime)s - %(name)s - %(levelname)s - %(message)s'):
    log_dir = os.path.dirname(log_file)
    if log_dir and not os.path.exists(log_dir):
        try:
            os.makedirs(log_dir, exist_ok=True)
            os.chmod(log_dir, 0o755)
        except Exception as e:
            print(f"Error creating log directory {log_dir}: {e}")
            log_file = os.path.join("/tmp", os.path.basename(log_file))
            print(f"Falling back to log file: {log_file}")
    try:
        with open(log_file, 'a'):
            os.utime(log_file, None)
        os.chmod(log_file, 0o644)
    except Exception as e:
        print(f"Error touching/chmod log file {log_file}: {e}")

    logger = logging.getLogger(name)
    logger.setLevel(level)
    if not logger.hasHandlers():
        handler = logging.FileHandler(log_file, mode='a')
        handler.setFormatter(logging.Formatter(formatter_str))
        logger.addHandler(handler)
    return logger

monitor_logger = setup_logger('PY_MONITOR', LOG_FILE_MONITOR)
transfer_logger = setup_logger(
    'PY_S3_TRANSFER', S3_TRANSFER_LOG, formatter_str='%(asctime)s - %(message)s')

# --- Helper Functions ---
def is_path_relevant(path_to_check, base_dir, patterns):
    if not path_to_check.startswith(base_dir + os.path.sep):
        return False, None
    relative_file_path = os.path.relpath(path_to_check, base_dir)
    is_relevant = any(fnmatch.fnmatch(relative_file_path, pattern) for pattern in patterns)
    return is_relevant, relative_file_path

# --- FileSystem Event Handler Class ---
class Watcher(FileSystemEventHandler):
    def __init__(self):
        super().__init__()
        # Inicializar clientes boto3 uma vez para reutilização, se apropriado.
        # Ou instanciá-los dentro dos métodos se a configuração/região puder mudar
        # ou se o script for muito curto e não houver benefício de mantê-los.
        # Para simplicidade aqui, vamos instanciar nos métodos.
        pass

    def _is_excluded(self, filepath):
        filename = os.path.basename(filepath)
        if filename.startswith('.') or filename.endswith(('.swp', '.swx', '~', '.part', '.crdownload', '.tmp')):
            return True
        if '/cache/' in filepath or '/.git/' in filepath or '/node_modules/' in filepath:
            return True
        if '/uploads/sites/' in filepath:
             monitor_logger.debug(f"Excluding Multisite sub-site upload path: {filepath}")
             return True
        return False

    def _get_s3_path(self, relative_file_path):
        return f"s3://{S3_BUCKET}/{relative_file_path}"

    def _check_s3_object_exists(self, s3_key):
        """Verifica se um objeto existe no S3."""
        s3_client_boto = boto3.client('s3')
        try:
            s3_client_boto.head_object(Bucket=S3_BUCKET, Key=s3_key)
            monitor_logger.debug(f"S3 object '{s3_key}' found using head_object.")
            return True
        except s3_client_boto.exceptions.ClientError as e:
            if e.response['Error']['Code'] == '404' or e.response['Error']['Code'] == 'NoSuchKey':
                monitor_logger.debug(f"S3 object '{s3_key}' not found (404/NoSuchKey).")
                return False
            else:
                monitor_logger.error(f"ClientError checking S3 object '{s3_key}' with head_object: {e.response['Error']['Code']} - {e.response['Error']['Message']}")
                return False # Assumir que não existe em caso de outros erros para evitar invalidações indevidas
        except Exception as e:
            monitor_logger.error(f"Unexpected error checking S3 object '{s3_key}' with head_object: {e}", exc_info=True)
            return False # Assumir que não existe

    def _invalidate_cloudfront(self, object_key_to_invalidate):
        """Cria uma invalidação no CloudFront para o objeto especificado."""
        if not CLOUDFRONT_DISTRIBUTION_ID:
            monitor_logger.warning("CLOUDFRONT_DISTRIBUTION_ID not set in environment. Skipping CloudFront invalidation.")
            return

        cloudfront_client_boto = boto3.client('cloudfront')
        path_to_invalidate = '/' + object_key_to_invalidate
        
        monitor_logger.info(f"Attempting CloudFront invalidation for path: {path_to_invalidate} on distribution: {CLOUDFRONT_DISTRIBUTION_ID}")
        try:
            cloudfront_client_boto.create_invalidation(
                DistributionId=CLOUDFRONT_DISTRIBUTION_ID,
                InvalidationBatch={
                    'Paths': {
                        'Quantity': 1,
                        'Items': [path_to_invalidate]
                    },
                    'CallerReference': f"s3-efs-sync-{object_key_to_invalidate.replace('/', '-')}-{int(time.time())}"
                }
            )
            monitor_logger.info(f"CloudFront invalidation request created for: {path_to_invalidate}")
            transfer_logger.info(f"INVALIDATED_CF: {path_to_invalidate} on {CLOUDFRONT_DISTRIBUTION_ID}")
        except Exception as e:
            monitor_logger.error(f"Failed to create CloudFront invalidation for {path_to_invalidate}: {e}", exc_info=True)
            transfer_logger.info(f"INVALIDATION_CF_FAILED: {path_to_invalidate} - {str(e)}")

    def _handle_s3_upload(self, local_path, relative_file_path, is_initial_sync=False):
        effective_delete_from_efs = DELETE_FROM_EFS_AFTER_SYNC and not is_initial_sync

        current_time = time.time()
        if not is_initial_sync and local_path in last_sync_file_map and \
           (current_time - last_sync_file_map[local_path] < SYNC_DEBOUNCE_SECONDS):
            monitor_logger.info(f"Debounce for '{local_path}'. Skipped.")
            return

        object_existed_before_upload = False
        if not is_initial_sync: # Apenas para eventos do watcher
            object_existed_before_upload = self._check_s3_object_exists(relative_file_path)
            if object_existed_before_upload:
                monitor_logger.info(f"Object '{relative_file_path}' already exists in S3. This will be an update, triggering CloudFront invalidation if configured.")
            else:
                monitor_logger.info(f"Object '{relative_file_path}' does not exist in S3. This will be a new creation. No CloudFront invalidation for new objects.")

        s3_full_uri = self._get_s3_path(relative_file_path)
        monitor_logger.info(f"Copying '{local_path}' to '{s3_full_uri}'...")

        try:
            process = subprocess.run(
                [AWS_CLI_PATH, 's3', 'cp', local_path, s3_full_uri,
                 '--acl', 'private', '--only-show-errors'],
                capture_output=True, text=True, check=False
            )

            if process.returncode == 0:
                monitor_logger.info(f"S3 copy OK for '{relative_file_path}'.")
                transfer_logger.info(f"TRANSFERRED: {relative_file_path} to {s3_full_uri}")
                last_sync_file_map[local_path] = current_time

                if not is_initial_sync and object_existed_before_upload:
                    self._invalidate_cloudfront(relative_file_path)
                
                if effective_delete_from_efs:
                    _, ext = os.path.splitext(local_path)
                    if ext.lower() in DELETABLE_IMAGE_EXTENSIONS_FROM_EFS:
                        try:
                            os.remove(local_path)
                            monitor_logger.info(f"Successfully deleted IMAGE '{local_path}' from EFS (DELETE_FROM_EFS_AFTER_SYNC=true).")
                            transfer_logger.info(f"DELETED_EFS_IMAGE: {relative_file_path}")
                        except OSError as e:
                            monitor_logger.error(f"Failed to delete IMAGE '{local_path}' from EFS: {e}")
                    else:
                        monitor_logger.info(f"File '{local_path}' (ext: {ext.lower()}) not in DELETABLE_IMAGE_EXTENSIONS_FROM_EFS. Kept on EFS.")
            else:
                monitor_logger.error(
                    f"S3 copy FAILED for '{relative_file_path}'. RC: {process.returncode}. Stdout: {process.stdout.strip()}. Stderr: {process.stderr.strip()}")
        except FileNotFoundError:
             monitor_logger.error(f"AWS CLI not found at '{AWS_CLI_PATH}'. S3 copy failed for '{relative_file_path}'.")
        except Exception as e:
            monitor_logger.error(f"Exception during S3 copy for {relative_file_path}: {e}", exc_info=True)

    def _handle_s3_delete(self, relative_file_path):
        s3_client_boto = boto3.client('s3')
        s3_target_path_key = relative_file_path
        s3_full_uri = self._get_s3_path(relative_file_path)

        monitor_logger.info(f"Attempting to delete '{s3_full_uri}' from S3 via AWS CLI...")
        cli_delete_reported_success = False
        cli_rc = -1
        cli_stderr = ""

        try:
            process = subprocess.run(
                [AWS_CLI_PATH, 's3', 'rm', s3_full_uri], # Removido --only-show-errors para debug
                capture_output=True, text=True, check=False
            )
            cli_rc = process.returncode
            cli_stderr = process.stderr.strip()

            if cli_rc == 0:
                monitor_logger.info(f"AWS CLI 's3 rm' for '{relative_file_path}' reported success (RC: 0).")
                if cli_stderr: monitor_logger.info(f"CLI Stderr (RC 0): {cli_stderr}") # Logar stderr mesmo em sucesso
                transfer_logger.info(f"DELETED_S3_CLI_OK: {relative_file_path}")
                cli_delete_reported_success = True
            else:
                monitor_logger.error(
                    f"AWS CLI 's3 rm' FAILED for '{relative_file_path}'. RC: {cli_rc}. Stderr: {cli_stderr}")
                transfer_logger.info(f"DELETED_S3_CLI_FAILED: {relative_file_path} - RC={cli_rc} ERR={cli_stderr}")

        except FileNotFoundError:
             monitor_logger.error(f"AWS CLI not found at '{AWS_CLI_PATH}'. S3 delete for '{relative_file_path}' failed at CLI stage.")
             return
        except Exception as e:
            monitor_logger.error(f"Exception during AWS CLI 's3 rm' for {relative_file_path}: {e}", exc_info=True)
            # Mesmo com exceção no CLI, vamos tentar verificar com head_object, pois o estado pode ser incerto
            pass # Continua para a verificação

        monitor_logger.info(f"Verifying deletion of '{s3_target_path_key}' in S3 using Boto3 head_object...")
        try:
            time.sleep(1) 
            s3_client_boto.head_object(Bucket=S3_BUCKET, Key=s3_target_path_key)
            monitor_logger.error(
                f"S3 delete VERIFICATION FAILED for '{relative_file_path}'. Object still found in S3 after 'aws s3 rm' (CLI RC: {cli_rc}). Review IAM permissions and bucket policies.")
            if cli_stderr: monitor_logger.error(f"CLI Stderr was: {cli_stderr}")
            transfer_logger.info(f"DELETED_S3_VERIFICATION_FAILED_STILL_EXISTS: {relative_file_path}")

        except s3_client_boto.exceptions.ClientError as e:
            if e.response['Error']['Code'] == '404' or e.response['Error']['Code'] == 'NoSuchKey':
                monitor_logger.info(f"S3 delete VERIFIED for '{relative_file_path}'. Object no longer found in S3 (confirmed by head_object). CLI RC: {cli_rc}.")
                if cli_stderr and not cli_delete_reported_success: monitor_logger.info(f"CLI Stderr was (file now gone): {cli_stderr}")
                transfer_logger.info(f"DELETED_S3_VERIFIED_NOT_FOUND: {relative_file_path}")
                 # Se a verificação Boto3 confirma a deleção, invalidar CloudFront
                self._invalidate_cloudfront(relative_file_path)
            else:
                monitor_logger.error(
                    f"Error during S3 delete VERIFICATION for '{relative_file_path}' using head_object: {e.response['Error']['Code']} - {e.response['Error']['Message']}. CLI RC: {cli_rc}.")
                if cli_stderr: monitor_logger.error(f"CLI Stderr was: {cli_stderr}")
                transfer_logger.info(f"DELETED_S3_VERIFICATION_ERROR_HEAD_OBJECT: {relative_file_path} - {e.response['Error']['Code']}")
        except Exception as ve:
            monitor_logger.error(f"Unexpected error during S3 delete VERIFICATION for '{s3_target_path_key}': {ve}", exc_info=True)
            transfer_logger.info(f"DELETED_S3_VERIFICATION_UNEXPECTED_ERROR: {relative_file_path}")


    def process_event_for_sync(self, event_type, path):
        if self._is_excluded(path) or (os.path.exists(path) and os.path.isdir(path)):
            return

        relevant, relative_path = is_path_relevant(path, MONITOR_DIR_BASE, RELEVANT_PATTERNS)
        if not relevant or not relative_path:
            return

        monitor_logger.info(f"Event: {event_type.upper()} for relevant file '{relative_path}' (full: {path})")

        if event_type in ['created', 'modified', 'moved_to']:
            self._handle_s3_upload(path, relative_path)
        elif event_type == 'deleted':
            self._handle_s3_delete(relative_path) # A invalidação CF para deleção acontece dentro de _handle_s3_delete após confirmação

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
            relevant_src, relative_src_path = is_path_relevant(event.src_path, MONITOR_DIR_BASE, RELEVANT_PATTERNS)
            if relevant_src and relative_src_path and not self._is_excluded(event.src_path):
                monitor_logger.info(f"Event: MOVED (source part) for relevant file '{relative_src_path}' (full: {event.src_path})")
                self._handle_s3_delete(relative_src_path) # A invalidação CF para deleção acontece aqui dentro
            self.process_event_for_sync('moved_to', event.dest_path) # O _handle_s3_upload lida com invalidação para updates

# --- Initial Sync Function using 'aws s3 sync' ---
def run_s3_sync_command(command_parts, description):
    monitor_logger.info(f"Attempting Initial Sync for {description} with command: {' '.join(command_parts)}")
    try:
        process = subprocess.run(command_parts, capture_output=True, text=True, check=False)
        if process.returncode == 0:
            monitor_logger.info(f"Initial Sync for {description} completed successfully.")
            if process.stdout.strip():
                 monitor_logger.info(f"Initial Sync for {description} stdout: {process.stdout.strip()}")
            transfer_logger.info(f"INITIAL_SYNC_SUCCESS: {description}")
            return True
        elif process.returncode == 2:
            monitor_logger.warning(f"Initial Sync for {description} completed with RC 2 (some files may not have been synced). Check stderr.")
            if process.stdout.strip():
                 monitor_logger.info(f"Initial Sync for {description} stdout: {process.stdout.strip()}")
            if process.stderr.strip():
                monitor_logger.warning(f"Initial Sync for {description} stderr: {process.stderr.strip()}")
            transfer_logger.info(f"INITIAL_SYNC_WARNING_RC2: {description} - ERR: {process.stderr.strip()}")
            return True
        else:
            monitor_logger.error(f"Initial Sync for {description} FAILED. RC: {process.returncode}.")
            if process.stdout.strip():
                monitor_logger.error(f"Initial Sync for {description} stdout: {process.stdout.strip()}")
            if process.stderr.strip():
                monitor_logger.error(f"Initial Sync for {description} stderr: {process.stderr.strip()}")
            transfer_logger.info(f"INITIAL_SYNC_FAILED: {description} - RC={process.returncode} ERR={process.stderr.strip()}")
            return False
    except FileNotFoundError:
        monitor_logger.error(f"AWS CLI not found at '{AWS_CLI_PATH}'. Initial Sync for {description} failed.")
        return False
    except Exception as e:
        monitor_logger.error(f"Exception during Initial Sync for {description}: {e}", exc_info=True)
        return False

def perform_initial_sync():
    monitor_logger.info("--- Starting Initial S3 Sync using 'aws s3 sync' commands ---")
    if not S3_BUCKET:
        monitor_logger.error("S3_BUCKET not configured. Skipping initial sync.")
        return
    if not os.path.isdir(MONITOR_DIR_BASE):
        monitor_logger.error(f"Monitor directory '{MONITOR_DIR_BASE}' does not exist. Skipping initial sync.")
        return

    wp_content_path = os.path.join(MONITOR_DIR_BASE, "wp-content")
    if os.path.isdir(wp_content_path):
        s3_sync_wp_content_cmd = [
            AWS_CLI_PATH, 's3', 'sync', wp_content_path, f"s3://{S3_BUCKET}/wp-content/",
            '--exclude', '*.php',
            '--include', '*.css', '--include', '*.js',
            '--include', '*.jpg', '--include', '*.jpeg', '--include', '*.png', '--include', '*.gif',
            '--include', '*.svg', '--include', '*.webp', '--include', '*.ico',
            '--include', '*.woff', '--include', '*.woff2', '--include', '*.ttf',
            '--include', '*.eot', '--include', '*.otf',
            '--include', '*.mp4', '--include', '*.mov', '--include', '*.webm',
            '--include', '*.avi', '--include', '*.wmv', '--include', '*.mkv', '--include', '*.flv',
            '--include', '*.mp3', '--include', '*.wav', '--include', '*.ogg',
            '--include', '*.aac', '--include', '*.wma', '--include', '*.flac',
            '--include', '*.pdf', '--include', '*.doc', '--include', '*.docx',
            '--include', '*.xls', '--include', '*.xlsx', '--include', '*.ppt', '--include', '*.pptx',
            '--include', '*.zip', '--include', '*.txt',
            '--exact-timestamps', '--acl', 'private', '--only-show-errors'
        ]
        run_s3_sync_command(s3_sync_wp_content_cmd, "wp-content")
    else:
        monitor_logger.warning(f"Directory '{wp_content_path}' not found. Skipping sync for wp-content.")

    wp_includes_path = os.path.join(MONITOR_DIR_BASE, "wp-includes")
    if os.path.isdir(wp_includes_path):
        s3_sync_wp_includes_cmd = [
            AWS_CLI_PATH, 's3', 'sync', wp_includes_path, f"s3://{S3_BUCKET}/wp-includes/",
            '--exclude', '*.php',
            '--include', '*.css', '--include', '*.js',
            '--include', '*.jpg', '--include', '*.jpeg', '--include', '*.png', '--include', '*.gif',
            '--include', '*.svg', '--include', '*.webp', '--include', '*.ico',
            '--exact-timestamps', '--acl', 'private', '--only-show-errors'
        ]
        run_s3_sync_command(s3_sync_wp_includes_cmd, "wp-includes")
    else:
        monitor_logger.warning(f"Directory '{wp_includes_path}' not found. Skipping sync for wp-includes.")

    monitor_logger.info("--- Initial S3 Sync using 'aws s3 sync' commands Attempted ---")

# --- Main Execution Block ---
if __name__ == "__main__":
    script_version_tag = "vLocalDev-CF-Invalidation" # Mude conforme necessário
    monitor_logger.info(
        f"Python Watchdog Monitor (EFS to S3 Sync - {script_version_tag}) starting for '{MONITOR_DIR_BASE}'.")
    monitor_logger.info(f"S3 Bucket: {S3_BUCKET}")
    monitor_logger.info(f"Relevant Patterns for Watcher (raw): {RELEVANT_PATTERNS_STR}")
    monitor_logger.info(f"Relevant Watcher Patterns (parsed): {RELEVANT_PATTERNS}")
    monitor_logger.info(f"Delete IMAGES from EFS after sync (watcher only): {DELETE_FROM_EFS_AFTER_SYNC}")
    monitor_logger.info(f"Image extensions to delete from EFS: {DELETABLE_IMAGE_EXTENSIONS_FROM_EFS if DELETE_FROM_EFS_AFTER_SYNC else 'N/A'}")
    monitor_logger.info(f"Perform initial sync using 'aws s3 sync': {PERFORM_INITIAL_SYNC}")
    monitor_logger.info(f"CloudFront Distribution ID for Invalidation: {CLOUDFRONT_DISTRIBUTION_ID if CLOUDFRONT_DISTRIBUTION_ID else 'Not Set'}")


    if not S3_BUCKET:
        monitor_logger.critical("S3_BUCKET environment variable not set. Exiting.")
        exit(1)
    if not os.path.isdir(MONITOR_DIR_BASE):
        monitor_logger.critical(f"Monitor directory '{MONITOR_DIR_BASE}' does not exist. Exiting.")
        exit(1)

    aws_cli_actual_path = shutil.which(AWS_CLI_PATH)
    if not aws_cli_actual_path:
        monitor_logger.critical(f"AWS CLI not found at specified path '{AWS_CLI_PATH}' or not in system PATH. Please check WP_AWS_CLI_PATH. Exiting.")
        exit(1)
    else:
        if AWS_CLI_PATH != aws_cli_actual_path:
             monitor_logger.info(f"Resolved AWS CLI path from '{AWS_CLI_PATH}' to '{aws_cli_actual_path}'.")
        AWS_CLI_PATH = aws_cli_actual_path
        monitor_logger.info(f"Using AWS CLI at: {AWS_CLI_PATH}")

    if PERFORM_INITIAL_SYNC:
        monitor_logger.info("WP_PERFORM_INITIAL_SYNC is true. Calling perform_initial_sync().")
        perform_initial_sync()
        monitor_logger.info("Call to perform_initial_sync() has completed.")
    else:
        monitor_logger.info("WP_PERFORM_INITIAL_SYNC is false. Skipping initial sync.")
    
    if not RELEVANT_PATTERNS_STR and PERFORM_INITIAL_SYNC: # Ajuste da lógica de aviso
        monitor_logger.warning("RELEVANT_PATTERNS_STR is empty. Watchdog will not process new file events unless patterns are added.")
    elif not RELEVANT_PATTERNS_STR and not PERFORM_INITIAL_SYNC: # Condição crítica
         monitor_logger.critical("RELEVANT_PATTERNS_STR is empty and PERFORM_INITIAL_SYNC is false. Script will do nothing. Exiting.")
         exit(1) # Sai se não há nada para o script fazer

    event_handler = Watcher()
    observer = Observer()
    try:
        observer.schedule(event_handler, MONITOR_DIR_BASE, recursive=True)
        observer.start()
        monitor_logger.info("Observer started. Monitoring for file changes based on RELEVANT_PATTERNS...")
        while observer.is_alive():
            observer.join(1)
    except KeyboardInterrupt:
        monitor_logger.info("Keyboard interrupt received. Stopping observer...")
    except Exception as e:
        monitor_logger.critical(f"Critical error in observer loop: {e}", exc_info=True)
    finally:
        if observer.is_alive():
            observer.stop()
        observer.join()
        monitor_logger.info("Observer stopped and joined. Exiting.")
