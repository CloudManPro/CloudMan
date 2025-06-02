import time
import logging
import subprocess
import os
import fnmatch
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
import shutil  # Para shutil.which
import boto3
from botocore.config import Config # Para timeouts do Boto3
from botocore.exceptions import ClientError, ConnectTimeoutError, ReadTimeoutError # Para capturar erros do Boto3
import threading

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

DELETE_FROM_EFS_AFTER_SYNC = True
PERFORM_INITIAL_SYNC = True

CLOUDFRONT_DISTRIBUTION_ID = os.environ.get(
    'AWS_CLOUDFRONT_DISTRIBUTION_TARGET_ID_0')

CF_INVALIDATION_BATCH_MAX_SIZE = int(
    os.environ.get('CF_INVALIDATION_BATCH_MAX_SIZE', 15))
CF_INVALIDATION_BATCH_TIMEOUT_SECONDS = int(
    os.environ.get('CF_INVALIDATION_BATCH_TIMEOUT_SECONDS', 20))

# Timeouts (em segundos)
AWS_CLI_TIMEOUT_S3_CP = 300  # 5 minutos para cópia S3
AWS_CLI_TIMEOUT_S3_RM = 60   # 1 minuto para remoção S3
BOTO3_CLOUDFRONT_CONNECT_TIMEOUT = 10 # Segundos para conectar à API do CloudFront
BOTO3_CLOUDFRONT_READ_TIMEOUT = 60    # Segundos para ler a resposta da API do CloudFront

PLACEHOLDER_TARGET_EXTENSIONS_EFS = [
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.ico', '.svg',
    '.mp4', '.mov', '.webm', '.avi', '.wmv', '.mkv', '.flv',
    '.mp3', '.wav', '.ogg', '.aac', '.wma', '.flac',
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
    '.zip', '.txt',
]
PLACEHOLDER_CONTENT = "0"

RELEVANT_PATTERNS = [p.strip()
                     for p in RELEVANT_PATTERNS_STR.split(';') if p.strip()]
last_sync_file_map = {}

cf_invalidation_paths_batch = []
cf_invalidation_timer = None
cf_invalidation_lock = threading.Lock()
efs_deleted_by_script = set()
efs_deletion_lock = threading.Lock()

# --- Logger Setup ---
def setup_logger(name, log_file, level=logging.INFO, formatter_str='%(asctime)s - %(name)s - %(levelname)s - %(message)s'):
    log_dir = os.path.dirname(log_file)
    if log_dir and not os.path.exists(log_dir):
        try:
            os.makedirs(log_dir, exist_ok=True)
            os.chmod(log_dir, 0o755) # Tentar definir permissões mais abertas para o diretório
        except Exception as e:
            print(f"Error creating or setting permissions for log directory {log_dir}: {e}")
            log_file = os.path.join(
                "/tmp", os.path.basename(log_file))
            print(f"Falling back to log file: {log_file}")

    try:
        # Tentar criar o arquivo de log se não existir e definir permissões
        if not os.path.exists(log_file):
            with open(log_file, 'a'): # Cria o arquivo se não existir
                pass
        os.chmod(log_file, 0o666) # Permissões mais abertas para o arquivo de log
    except Exception as e:
        print(f"Error touching/chmod log file {log_file}: {e}")
        # Se falhar, o handler do logging pode falhar ao abrir o arquivo.

    logger = logging.getLogger(name)
    logger.setLevel(level)
    if not logger.hasHandlers(): # Evitar adicionar handlers múltiplos se a função for chamada de novo
        try:
            handler = logging.FileHandler(log_file, mode='a')
            handler.setFormatter(logging.Formatter(formatter_str))
            logger.addHandler(handler)
        except Exception as e:
            print(f"CRITICAL: Failed to create FileHandler for {log_file}: {e}. Logging to file will NOT work.")

        console_handler = logging.StreamHandler() # Log para stdout/stderr (visto no journalctl)
        console_handler.setLevel(logging.INFO) # Mostrar INFO e acima no console/journalctl
        console_handler.setFormatter(logging.Formatter(formatter_str))
        logger.addHandler(console_handler)
    return logger

monitor_logger = setup_logger('PY_MONITOR', LOG_FILE_MONITOR)
transfer_logger = setup_logger(
    'PY_S3_TRANSFER', S3_TRANSFER_LOG, formatter_str='%(asctime)s - %(message)s')

# --- Helper Functions ---
def is_path_relevant(path_to_check, base_dir, patterns):
    if not path_to_check.startswith(base_dir + os.path.sep):
        return False, None
    relative_file_path = os.path.relpath(path_to_check, base_dir)
    is_relevant = any(fnmatch.fnmatch(relative_file_path, pattern)
                      for pattern in patterns)
    return is_relevant, relative_file_path

def _replace_efs_file_with_placeholder(local_path, relative_file_path):
    try:
        with open(local_path, 'w') as f_placeholder:
            f_placeholder.write(PLACEHOLDER_CONTENT)
        monitor_logger.info(
            f"Successfully replaced EFS file '{local_path}' with placeholder.")
        transfer_logger.info(
            f"EFS_PLACEHOLDER_CREATED: {relative_file_path}")
        return True
    except OSError as e:
        monitor_logger.error(
            f"Failed to replace EFS file '{local_path}' with placeholder: {e}")
        return False
    except Exception as e:
        monitor_logger.error(
            f"Unexpected error replacing EFS file '{local_path}' with placeholder: {e}", exc_info=True)
        return False

# --- FileSystem Event Handler Class ---
class Watcher(FileSystemEventHandler):
    def __init__(self):
        super().__init__()
        boto_config = Config(
            connect_timeout=BOTO3_CLOUDFRONT_CONNECT_TIMEOUT,
            read_timeout=BOTO3_CLOUDFRONT_READ_TIMEOUT,
            retries={'max_attempts': 2}
        )
        self.cloudfront_client_boto = boto3.client('cloudfront', config=boto_config)

    def _is_excluded(self, filepath):
        filename = os.path.basename(filepath)
        if filename.startswith('.') or filename.endswith(('.swp', '.swx', '~', '.part', '.crdownload', '.tmp')):
            return True
        if '/cache/' in filepath or '/.git/' in filepath or '/node_modules/' in filepath:
            return True
        if '/uploads/sites/' in filepath:
            monitor_logger.debug(
                f"Excluding Multisite sub-site upload path: {filepath}")
            return True
        return False

    def _get_s3_path(self, relative_file_path):
        return f"s3://{S3_BUCKET}/{relative_file_path}"

    def _trigger_batched_cloudfront_invalidation(self, paths_override=None, reference_suffix_override=None):
        global cf_invalidation_paths_batch, cf_invalidation_timer
        paths_to_invalidate_now = []
        current_batch_to_log = []

        with cf_invalidation_lock:
            if paths_override:
                paths_to_invalidate_now = paths_override
                current_batch_to_log = list(paths_override)
                monitor_logger.info(f"CloudFront invalidation triggered with overridden paths: {paths_override}")
            elif not cf_invalidation_paths_batch:
                monitor_logger.debug("Batched CloudFront invalidation triggered, but batch is empty.")
                if cf_invalidation_timer:
                    cf_invalidation_timer.cancel()
                    cf_invalidation_timer = None
                return
            else:
                paths_to_invalidate_now = ["/" + p for p in cf_invalidation_paths_batch]
                current_batch_to_log = list(cf_invalidation_paths_batch)
                cf_invalidation_paths_batch = [] # Limpa o lote global
                monitor_logger.debug(f"CloudFront invalidation batch (size {len(paths_to_invalidate_now)}) reset before API call.")

            if cf_invalidation_timer:
                cf_invalidation_timer.cancel()
                cf_invalidation_timer = None
                monitor_logger.debug("Cancelled CloudFront invalidation timer as batch is being processed now.")

        if not paths_to_invalidate_now: # Checagem extra
            monitor_logger.debug("No paths to invalidate after batch processing logic.")
            return

        if not CLOUDFRONT_DISTRIBUTION_ID:
            monitor_logger.warning(
                f"CLOUDFRONT_DISTRIBUTION_ID not set. Skipping CloudFront invalidation for: {current_batch_to_log}")
            return

        monitor_logger.info(
            f"Attempting to create CloudFront invalidation for {len(paths_to_invalidate_now)} paths on {CLOUDFRONT_DISTRIBUTION_ID}. Paths: {paths_to_invalidate_now}")
        try:
            ref_suffix = reference_suffix_override if reference_suffix_override else f"batch-{len(paths_to_invalidate_now)}"
            caller_ref = f"s3-efs-sync-{int(time.time())}-{ref_suffix}"

            self.cloudfront_client_boto.create_invalidation(
                DistributionId=CLOUDFRONT_DISTRIBUTION_ID,
                InvalidationBatch={
                    'Paths': {
                        'Quantity': len(paths_to_invalidate_now),
                        'Items': paths_to_invalidate_now
                    },
                    'CallerReference': caller_ref
                }
            )
            monitor_logger.info(
                f"CloudFront invalidation request CREATED successfully for {len(paths_to_invalidate_now)} paths. CallerReference: {caller_ref}")
            transfer_logger.info(
                f"INVALIDATED_CF_REQUESTED: {len(paths_to_invalidate_now)} paths on {CLOUDFRONT_DISTRIBUTION_ID} - Batch: {', '.join(current_batch_to_log)}")
        except (ConnectTimeoutError, ReadTimeoutError) as e:
            monitor_logger.error(
                f"Boto3 Timeout ({type(e).__name__}) during CloudFront invalidation for paths {current_batch_to_log}: {e}", exc_info=True)
            transfer_logger.info(
                f"INVALIDATION_CF_BOTO_TIMEOUT: {len(paths_to_invalidate_now)} paths - {str(e)}")
        except ClientError as e:
            monitor_logger.error(
                f"Boto3 ClientError during CloudFront invalidation for paths {current_batch_to_log}: {e}", exc_info=True)
            transfer_logger.info(
                f"INVALIDATION_CF_BOTO_ERROR: {len(paths_to_invalidate_now)} paths - {str(e)}")
        except Exception as e:
            monitor_logger.error(
                f"Unexpected error during CloudFront invalidation for paths {current_batch_to_log}: {e}", exc_info=True)
            transfer_logger.info(
                f"INVALIDATION_CF_UNEXPECTED_ERROR: {len(paths_to_invalidate_now)} paths - {str(e)}")
        monitor_logger.info(f"CloudFront invalidation attempt for {len(paths_to_invalidate_now)} paths COMPLETED (check logs for success/failure).")


    def _add_to_cf_invalidation_batch(self, object_key_to_invalidate):
        global cf_invalidation_paths_batch, cf_invalidation_timer
        with cf_invalidation_lock:
            if object_key_to_invalidate not in cf_invalidation_paths_batch:
                cf_invalidation_paths_batch.append(object_key_to_invalidate)
                monitor_logger.info(
                    f"Added '{object_key_to_invalidate}' to CloudFront invalidation batch. Batch size: {len(cf_invalidation_paths_batch)}")

            if cf_invalidation_timer:
                cf_invalidation_timer.cancel()
                monitor_logger.debug("Cancelled existing CloudFront invalidation timer.")

            if len(cf_invalidation_paths_batch) >= CF_INVALIDATION_BATCH_MAX_SIZE:
                monitor_logger.info(
                    f"CloudFront invalidation batch reached max size ({CF_INVALIDATION_BATCH_MAX_SIZE}). Triggering invalidation now.")
                self._trigger_batched_cloudfront_invalidation() # Timer será cancelado/tratado dentro desta função
            elif cf_invalidation_paths_batch:
                cf_invalidation_timer = threading.Timer(
                    CF_INVALIDATION_BATCH_TIMEOUT_SECONDS, self._trigger_batched_cloudfront_invalidation)
                cf_invalidation_timer.daemon = True # Para que o timer não impeça o script de sair
                cf_invalidation_timer.start()
                monitor_logger.debug(
                    f"CloudFront invalidation timer (re)started for {CF_INVALIDATION_BATCH_TIMEOUT_SECONDS}s. Batch size: {len(cf_invalidation_paths_batch)}")

    def _handle_s3_upload(self, local_path, relative_file_path, is_initial_sync=False):
        effective_replace_with_placeholder = DELETE_FROM_EFS_AFTER_SYNC and not is_initial_sync
        current_time = time.time()
        if not is_initial_sync and local_path in last_sync_file_map and \
           (current_time - last_sync_file_map[local_path] < SYNC_DEBOUNCE_SECONDS):
            monitor_logger.info(
                f"Debounce for '{local_path}'. Skipped upload and subsequent actions.")
            return

        s3_full_uri = self._get_s3_path(relative_file_path)
        monitor_logger.info(f"Attempting S3 copy: '{local_path}' to '{s3_full_uri}' with timeout {AWS_CLI_TIMEOUT_S3_CP}s...")

        try:
            process = subprocess.run(
                [AWS_CLI_PATH, 's3', 'cp', local_path, s3_full_uri,
                 '--acl', 'private', '--only-show-errors'],
                capture_output=True, text=True, check=False, # check=False para que não levante exceção em RC != 0
                timeout=AWS_CLI_TIMEOUT_S3_CP
            )

            if process.returncode == 0:
                monitor_logger.info(f"S3 copy OK for '{relative_file_path}'.")
                transfer_logger.info(
                    f"TRANSFERRED: {relative_file_path} to {s3_full_uri}")
                last_sync_file_map[local_path] = current_time

                if not is_initial_sync:
                    monitor_logger.info(
                        f"Adding '{relative_file_path}' to CloudFront invalidation batch due to EFS event (create/update).")
                    self._add_to_cf_invalidation_batch(relative_file_path)

                if effective_replace_with_placeholder:
                    _, ext = os.path.splitext(local_path)
                    if ext.lower() in PLACEHOLDER_TARGET_EXTENSIONS_EFS:
                        monitor_logger.info(
                            f"Preparing to replace EFS file '{local_path}' with placeholder.")
                        _replace_efs_file_with_placeholder(local_path, relative_file_path)
                    else:
                        monitor_logger.info(
                            f"File '{local_path}' (ext: {ext.lower()}) not in PLACEHOLDER_TARGET_EXTENSIONS_EFS. Kept on EFS as is.")
            else:
                monitor_logger.error(
                    f"S3 copy FAILED for '{relative_file_path}'. RC: {process.returncode}. Stdout: {process.stdout.strip()}. Stderr: {process.stderr.strip()}")
                transfer_logger.info(f"S3_CP_FAILED: {relative_file_path} RC={process.returncode} ERR={process.stderr.strip()}")

        except subprocess.TimeoutExpired:
            monitor_logger.error(f"S3 copy TIMEOUT for '{relative_file_path}' after {AWS_CLI_TIMEOUT_S3_CP}s.")
            transfer_logger.info(f"S3_CP_TIMEOUT: {relative_file_path}")
        except FileNotFoundError:
            monitor_logger.error(
                f"AWS CLI not found at '{AWS_CLI_PATH}'. S3 copy failed for '{relative_file_path}'.")
        except Exception as e:
            monitor_logger.error(
                f"Exception during S3 copy for {relative_file_path}: {e}", exc_info=True)

    def _handle_s3_delete(self, relative_file_path):
        s3_client_boto = boto3.client('s3')
        s3_target_path_key = relative_file_path
        s3_full_uri = self._get_s3_path(relative_file_path)

        monitor_logger.info(
            f"Attempting to delete '{s3_full_uri}' from S3 via AWS CLI with timeout {AWS_CLI_TIMEOUT_S3_RM}s...")
        cli_delete_reported_success = False
        cli_rc = -1
        cli_stderr = ""

        try:
            process = subprocess.run(
                [AWS_CLI_PATH, 's3', 'rm', s3_full_uri, '--only-show-errors'],
                capture_output=True, text=True, check=False, # check=False
                timeout=AWS_CLI_TIMEOUT_S3_RM
            )
            cli_rc = process.returncode
            cli_stderr = process.stderr.strip()

            if cli_rc == 0:
                monitor_logger.info(
                    f"AWS CLI 's3 rm' for '{relative_file_path}' reported success (RC: 0).")
                if cli_stderr:
                    monitor_logger.info(f"CLI Stderr (RC 0, only-show-errors): {cli_stderr}")
                transfer_logger.info(
                    f"DELETED_S3_CLI_OK: {relative_file_path}")
                cli_delete_reported_success = True
            else:
                monitor_logger.error(
                    f"AWS CLI 's3 rm' FAILED for '{relative_file_path}'. RC: {cli_rc}. Stderr: {cli_stderr}")
                transfer_logger.info(
                    f"DELETED_S3_CLI_FAILED: {relative_file_path} - RC={cli_rc} ERR={cli_stderr}")

        except subprocess.TimeoutExpired:
            monitor_logger.error(f"S3 rm TIMEOUT for '{relative_file_path}' after {AWS_CLI_TIMEOUT_S3_RM}s.")
            transfer_logger.info(f"S3_RM_TIMEOUT: {relative_file_path}")
            return # Não prosseguir com a verificação Boto3 se o CLI deu timeout
        except FileNotFoundError:
            monitor_logger.error(
                f"AWS CLI not found at '{AWS_CLI_PATH}'. S3 delete for '{relative_file_path}' failed at CLI stage.")
            return
        except Exception as e:
            monitor_logger.error(
                f"Exception during AWS CLI 's3 rm' for {relative_file_path}: {e}", exc_info=True)
            # Continuar para a verificação Boto3 pode ser útil em alguns casos de erro CLI não fatal

        monitor_logger.info(
            f"Verifying deletion of '{s3_target_path_key}' in S3 using Boto3 head_object...")
        try:
            time.sleep(1)
            s3_client_boto.head_object(
                Bucket=S3_BUCKET, Key=s3_target_path_key)
            monitor_logger.error(
                f"S3 delete VERIFICATION FAILED for '{relative_file_path}'. Object still found in S3 after 'aws s3 rm' (CLI RC: {cli_rc}).")
            if cli_stderr:
                monitor_logger.error(f"CLI Stderr from failed 's3 rm' was: {cli_stderr}")
            transfer_logger.info(
                f"DELETED_S3_VERIFICATION_FAILED_STILL_EXISTS: {relative_file_path}")
        except s3_client_boto.exceptions.ClientError as e:
            if e.response['Error']['Code'] == '404' or e.response['Error']['Code'] == 'NoSuchKey':
                monitor_logger.info(
                    f"S3 delete VERIFIED for '{relative_file_path}'. Object no longer found in S3 (confirmed by head_object). CLI RC: {cli_rc}.")
                if cli_stderr and not cli_delete_reported_success:
                    monitor_logger.info(
                        f"CLI Stderr from 's3 rm' (file now gone, CLI RC non-zero) was: {cli_stderr}")
                transfer_logger.info(
                    f"DELETED_S3_VERIFIED_NOT_FOUND: {relative_file_path}")
                monitor_logger.info(
                    f"Adding '{relative_file_path}' to CloudFront invalidation batch due to S3 delete confirmation.")
                self._add_to_cf_invalidation_batch(relative_file_path)
            else:
                monitor_logger.error(
                    f"Boto3 ClientError during S3 delete VERIFICATION for '{relative_file_path}': {e.response['Error']['Code']} - {e.response['Error']['Message']}. CLI RC: {cli_rc}.")
                if cli_stderr:
                    monitor_logger.error(f"CLI Stderr from 's3 rm' was: {cli_stderr}")
                transfer_logger.info(
                    f"DELETED_S3_VERIFICATION_ERROR_HEAD_OBJECT: {relative_file_path} - {e.response['Error']['Code']}")
        except Exception as ve:
            monitor_logger.error(
                f"Unexpected error during S3 delete VERIFICATION for '{s3_target_path_key}': {ve}", exc_info=True)
            transfer_logger.info(
                f"DELETED_S3_VERIFICATION_UNEXPECTED_ERROR: {relative_file_path}")

    def process_event_for_sync(self, event_type, path, dest_path=None):
        global efs_deleted_by_script

        if event_type == 'moved_from':
            if self._is_excluded(path) or (os.path.exists(path) and os.path.isdir(path)):
                return
            relevant_src, relative_src_path = is_path_relevant(
                path, MONITOR_DIR_BASE, RELEVANT_PATTERNS)
            if not relevant_src or not relative_src_path:
                return

            monitor_logger.info(
                f"Event: MOVED_FROM (source part) for relevant file '{relative_src_path}' (full: {path})")

            ignore_s3_deletion_for_moved_src = False
            with efs_deletion_lock:
                if path in efs_deleted_by_script:
                    monitor_logger.info(
                        f"EFS MOVED_FROM event for '{path}' was likely part of script-initiated rename/process. Not deleting from S3 for source.")
                    efs_deleted_by_script.remove(path)
                    ignore_s3_deletion_for_moved_src = True

            if not ignore_s3_deletion_for_moved_src:
                monitor_logger.info(
                    f"EFS MOVED_FROM event for '{path}' was external or placeholder rename. Proceeding with S3 delete for source.")
                self._handle_s3_delete(relative_src_path)
            else:
                transfer_logger.info(
                    f"SKIPPED_S3_DELETE_MOVED_FROM_BY_SCRIPT_FLAG: {relative_src_path}")
            return

        current_path_to_check = dest_path if event_type == 'moved_to' else path

        if self._is_excluded(current_path_to_check) or \
           (os.path.exists(current_path_to_check) and os.path.isdir(current_path_to_check)):
            return

        relevant, relative_path = is_path_relevant(
            current_path_to_check, MONITOR_DIR_BASE, RELEVANT_PATTERNS)
        if not relevant or not relative_path:
            return

        if event_type == 'modified' and os.path.exists(current_path_to_check):
            try:
                if os.path.getsize(current_path_to_check) == len(PLACEHOLDER_CONTENT.encode('utf-8')):
                    with open(current_path_to_check, 'r') as f_check:
                        content = f_check.read()
                    if content == PLACEHOLDER_CONTENT:
                        monitor_logger.info(f"Event: MODIFIED for placeholder '{relative_path}'. Skipping S3 upload.")
                        return
            except OSError:
                pass

        monitor_logger.info(
            f"Event: {event_type.upper()} for relevant file '{relative_path}' (full: {current_path_to_check})")

        if event_type in ['created', 'modified', 'moved_to']:
            self._handle_s3_upload(current_path_to_check, relative_path)
        elif event_type == 'deleted':
            monitor_logger.info(
                f"EFS delete event for '{path}' (likely a placeholder). Proceeding with S3 delete.")
            self._handle_s3_delete(relative_path)

    def on_created(self, event):
        if not event.is_directory:
            monitor_logger.debug(f"ON_CREATED raw: {event.src_path}")
            self.process_event_for_sync('created', event.src_path)

    def on_modified(self, event):
        if not event.is_directory:
            monitor_logger.debug(f"ON_MODIFIED raw: {event.src_path}")
            self.process_event_for_sync('modified', event.src_path)

    def on_deleted(self, event):
        if not event.is_directory:
            monitor_logger.debug(f"ON_DELETED raw: {event.src_path}")
            self.process_event_for_sync('deleted', event.src_path)

    def on_moved(self, event):
        if not os.path.isdir(event.src_path):
             monitor_logger.debug(f"ON_MOVED (src part) raw: {event.src_path}")
             self.process_event_for_sync('moved_from', event.src_path)

        if not event.is_directory:
            monitor_logger.debug(f"ON_MOVED (dest part) raw: {event.dest_path}")
            self.process_event_for_sync(
                'moved_to', event.src_path, dest_path=event.dest_path)

# --- Initial Sync Function ---
def run_s3_sync_command(command_parts, description):
    monitor_logger.info(
        f"Attempting Initial Sync for {description} with command: {' '.join(command_parts)} (timeout: {AWS_CLI_TIMEOUT_S3_CP}s)")
    try:
        process = subprocess.run(
            command_parts, capture_output=True, text=True, check=False,
            timeout=AWS_CLI_TIMEOUT_S3_CP # Usar timeout para sync também
        )
        if process.returncode == 0:
            monitor_logger.info(
                f"Initial Sync for {description} completed successfully.")
            if process.stdout.strip():
                monitor_logger.info(
                    f"Initial Sync for {description} stdout: {process.stdout.strip()}")
            transfer_logger.info(f"INITIAL_SYNC_SUCCESS: {description}")
            return True
        elif process.returncode == 2:
            monitor_logger.warning(
                f"Initial Sync for {description} completed with RC 2 (some files may not have been synced). Check stderr.")
            if process.stdout.strip():
                monitor_logger.info(
                    f"Initial Sync for {description} stdout: {process.stdout.strip()}")
            if process.stderr.strip():
                monitor_logger.warning(
                    f"Initial Sync for {description} stderr: {process.stderr.strip()}")
            transfer_logger.info(
                f"INITIAL_SYNC_WARNING_RC2: {description} - ERR: {process.stderr.strip()}")
            return True
        else:
            monitor_logger.error(
                f"Initial Sync for {description} FAILED. RC: {process.returncode}.")
            if process.stdout.strip():
                monitor_logger.error(
                    f"Initial Sync for {description} stdout: {process.stdout.strip()}")
            if process.stderr.strip():
                monitor_logger.error(
                    f"Initial Sync for {description} stderr: {process.stderr.strip()}")
            transfer_logger.info(
                f"INITIAL_SYNC_FAILED: {description} - RC={process.returncode} ERR={process.stderr.strip()}")
            return False
    except subprocess.TimeoutExpired:
        monitor_logger.error(f"Initial Sync TIMEOUT for '{description}' after {AWS_CLI_TIMEOUT_S3_CP}s.")
        transfer_logger.info(f"INITIAL_SYNC_TIMEOUT: {description}")
        return False # Considerar falha se der timeout
    except FileNotFoundError:
        monitor_logger.error(
            f"AWS CLI not found at '{AWS_CLI_PATH}'. Initial Sync for {description} failed.")
        return False
    except Exception as e:
        monitor_logger.error(
            f"Exception during Initial Sync for {description}: {e}", exc_info=True)
        return False

def perform_initial_sync(watcher_instance):
    monitor_logger.info(
        "--- Starting Initial S3 Sync using 'aws s3 sync' commands ---")
    if not S3_BUCKET:
        monitor_logger.error(
            "S3_BUCKET not configured. Skipping initial sync.")
        return
    if not os.path.isdir(MONITOR_DIR_BASE):
        monitor_logger.error(
            f"Monitor directory '{MONITOR_DIR_BASE}' does not exist. Skipping initial sync.")
        return

    general_sync_includes = [
        '*.css', '*.js',
        '*.jpg', '*.jpeg', '*.png', '*.gif', '*.svg', '*.webp', '*.ico',
        '*.woff', '*.woff2', '*.ttf', '*.eot', '*.otf',
        '*.mp4', '*.mov', '*.webm', '*.avi', '*.wmv', '*.mkv', '*.flv',
        '*.mp3', '*.wav', '*.ogg', '*.aac', '*.wma', '*.flac',
        '*.pdf', '*.doc', '*.docx', '*.xls', '*.xlsx', '*.ppt', '.pptx', # Corrigido .pptx
        '*.zip', '*.txt',
    ]
    includes_for_sync_cmd = []
    for item in general_sync_includes:
        includes_for_sync_cmd.extend(['--include', item])

    wp_content_path = os.path.join(MONITOR_DIR_BASE, "wp-content")
    if os.path.isdir(wp_content_path):
        s3_sync_wp_content_cmd = [
            AWS_CLI_PATH, 's3', 'sync', wp_content_path, f"s3://{S3_BUCKET}/wp-content/",
            '--exclude', '*.php',
            '--exclude', 'wp-content/plugins/index.php',
            '--exclude', 'wp-content/themes/index.php',
            '--exclude', 'wp-content/uploads/index.php',
            '--exclude', 'wp-content/cache/*',
            '--exclude', 'wp-content/backups/*',
            '--exclude', '*/.DS_Store',
            '--exclude', '*/Thumbs.db',
            '--exclude', '*/node_modules/*',
            '--exclude', '*/.git/*'
        ] + includes_for_sync_cmd + ['--exact-timestamps', '--acl', 'private', '--only-show-errors']
        run_s3_sync_command(s3_sync_wp_content_cmd, "wp-content")
    else:
        monitor_logger.warning(
            f"Directory '{wp_content_path}' not found. Skipping sync for wp-content.")

    wp_includes_path = os.path.join(MONITOR_DIR_BASE, "wp-includes")
    if os.path.isdir(wp_includes_path):
        wp_includes_assets_includes = [
            '*.css', '*.js',
            '*.jpg', '*.jpeg', '*.png', '*.gif',
            '*.svg', '*.webp', '*.ico',
            '*.woff', '*.woff2', '*.ttf', '*.eot', '*.otf',
        ]
        includes_for_wp_includes_cmd = []
        for item in wp_includes_assets_includes:
            includes_for_wp_includes_cmd.extend(['--include', item])

        s3_sync_wp_includes_cmd = [
            AWS_CLI_PATH, 's3', 'sync', wp_includes_path, f"s3://{S3_BUCKET}/wp-includes/",
            '--exclude', '*'
        ] + includes_for_wp_includes_cmd + [
            '--exact-timestamps', '--acl', 'private', '--only-show-errors'
        ]
        run_s3_sync_command(s3_sync_wp_includes_cmd, "wp-includes (assets only)")
    else:
        monitor_logger.warning(
            f"Directory '{wp_includes_path}' not found. Skipping sync for wp-includes.")

    monitor_logger.info(
        "--- Initial S3 Sync using 'aws s3 sync' commands Attempted ---")

    if DELETE_FROM_EFS_AFTER_SYNC:
        monitor_logger.info(
            "--- Starting EFS placeholder replacement for initially synced files ---")
        paths_to_scan_for_placeholders = []
        if os.path.isdir(wp_content_path):
            paths_to_scan_for_placeholders.append(wp_content_path)
        if os.path.isdir(wp_includes_path):
            paths_to_scan_for_placeholders.append(wp_includes_path)

        for scan_root_path in paths_to_scan_for_placeholders:
            monitor_logger.info(f"Scanning '{scan_root_path}' for files to replace with placeholders...")
            for root, _, files in os.walk(scan_root_path):
                for filename in files:
                    local_path = os.path.join(root, filename)
                    if watcher_instance._is_excluded(local_path):
                        monitor_logger.debug(f"Skipping placeholder for excluded file (initial sync): {local_path}")
                        continue
                    is_relevant, relative_path = is_path_relevant(
                        local_path, MONITOR_DIR_BASE, RELEVANT_PATTERNS)
                    if is_relevant:
                        _, ext = os.path.splitext(local_path)
                        if ext.lower() in PLACEHOLDER_TARGET_EXTENSIONS_EFS:
                            try:
                                if os.path.exists(local_path) and os.path.getsize(local_path) == len(PLACEHOLDER_CONTENT.encode('utf-8')): # Checa se existe antes de getsize
                                    with open(local_path, 'r') as f_check:
                                        content = f_check.read()
                                    if content == PLACEHOLDER_CONTENT:
                                        monitor_logger.debug(f"File '{local_path}' is already a placeholder. Skipping.")
                                        continue
                            except OSError:
                                pass
                            if os.path.exists(local_path): # Checa novamente antes de tentar substituir
                                monitor_logger.info(
                                    f"Initial Sync: Replacing EFS file '{local_path}' with placeholder.")
                                _replace_efs_file_with_placeholder(local_path, relative_path)
                            else:
                                monitor_logger.warning(f"Initial Sync: File '{local_path}' disappeared before placeholder replacement.")
        monitor_logger.info(
            "--- EFS placeholder replacement for initially synced files Attempted ---")

    if CLOUDFRONT_DISTRIBUTION_ID:
        monitor_logger.info("Initial sync complete. Triggering a full CloudFront invalidation (/*) due to potential widespread changes.")
        watcher_instance._trigger_batched_cloudfront_invalidation(paths_override=['/*'], reference_suffix_override="initial-sync-full")
    else:
        monitor_logger.info("Initial sync complete. CLOUDFRONT_DISTRIBUTION_ID not set, skipping full invalidation.")

# --- Main Execution Block ---
if __name__ == "__main__":
    script_version_tag = "v2.4.2-RobustTimeoutsLogging"
    monitor_logger.info(
        f"Python Watchdog Monitor (EFS to S3 Sync - {script_version_tag}) starting for '{MONITOR_DIR_BASE}'.")
    monitor_logger.info(f"S3 Bucket: {S3_BUCKET}")
    monitor_logger.info(
        f"Relevant Patterns for Watcher (raw): {RELEVANT_PATTERNS_STR}")
    monitor_logger.info(
        f"Relevant Watcher Patterns (parsed): {RELEVANT_PATTERNS}")
    monitor_logger.info(
        f"Replace EFS files with placeholders after sync: {DELETE_FROM_EFS_AFTER_SYNC} (Hardcoded)")
    monitor_logger.info(
        f"EFS file extensions to replace with placeholders: {PLACEHOLDER_TARGET_EXTENSIONS_EFS}")
    monitor_logger.info(
        f"Perform initial sync (EFS to S3, then EFS placeholder replacement): {PERFORM_INITIAL_SYNC} (Hardcoded)")
    monitor_logger.info(
        f"CloudFront Distribution ID for Invalidation: {CLOUDFRONT_DISTRIBUTION_ID if CLOUDFRONT_DISTRIBUTION_ID else 'Not Set'}")
    monitor_logger.info(
        f"CloudFront Invalidation Batch Max Size: {CF_INVALIDATION_BATCH_MAX_SIZE}, Timeout (s): {CF_INVALIDATION_BATCH_TIMEOUT_SECONDS}")
    monitor_logger.info(
        f"AWS CLI Timeouts: S3 CP={AWS_CLI_TIMEOUT_S3_CP}s, S3 RM={AWS_CLI_TIMEOUT_S3_RM}s")
    monitor_logger.info(
        f"Boto3 CloudFront Timeouts: Connect={BOTO3_CLOUDFRONT_CONNECT_TIMEOUT}s, Read={BOTO3_CLOUDFRONT_READ_TIMEOUT}s")


    if not S3_BUCKET:
        monitor_logger.critical(
            "S3_BUCKET environment variable not set. Exiting.")
        exit(1)
    if not os.path.isdir(MONITOR_DIR_BASE):
        monitor_logger.critical(
            f"Monitor directory '{MONITOR_DIR_BASE}' does not exist or is not a directory. Exiting.")
        exit(1)

    aws_cli_actual_path = shutil.which(AWS_CLI_PATH)
    if not aws_cli_actual_path:
        monitor_logger.critical(
            f"AWS CLI not found at specified path '{AWS_CLI_PATH}' or not in system PATH. Please check WP_AWS_CLI_PATH. Exiting.")
        exit(1)
    else:
        if AWS_CLI_PATH != aws_cli_actual_path:
            monitor_logger.info(
                f"Resolved AWS CLI path from '{AWS_CLI_PATH}' to '{aws_cli_actual_path}'.")
        AWS_CLI_PATH = aws_cli_actual_path
        monitor_logger.info(f"Using AWS CLI at: {AWS_CLI_PATH}")

    try:
        boto3.client('s3')
        monitor_logger.info(
            "Boto3 S3 client can be initialized successfully.")
    except Exception as e:
        monitor_logger.critical(
            f"Failed to initialize Boto3 S3 client. Check AWS credentials/configuration: {e}", exc_info=True)
        exit(1)

    event_handler = Watcher()

    if PERFORM_INITIAL_SYNC:
        monitor_logger.info(
            "PERFORM_INITIAL_SYNC is true (Hardcoded). Calling perform_initial_sync().")
        perform_initial_sync(event_handler)
        monitor_logger.info("Call to perform_initial_sync() has completed.")

    if not RELEVANT_PATTERNS_STR or not RELEVANT_PATTERNS:
        monitor_logger.warning(
            f"RELEVANT_PATTERNS_STR ('{RELEVANT_PATTERNS_STR}') is empty or resulted in no valid patterns. Watchdog will only process initial sync and deletions if patterns were previously matched.")
        # Não sair, pois o script ainda pode ser útil para deleções de placeholders existentes

    observer = Observer()
    try:
        monitor_logger.info(f"Scheduling observer on directory: {MONITOR_DIR_BASE}")
        observer.schedule(event_handler, MONITOR_DIR_BASE, recursive=True)
        monitor_logger.info("Starting observer...")
        observer.start()
        monitor_logger.info(
            "Observer started successfully. Monitoring for file changes...")
        while observer.is_alive():
            observer.join(1) # O join bloqueia até o observer parar ou o timeout de 1s
    except KeyboardInterrupt:
        monitor_logger.info(
            "Keyboard interrupt received. Stopping observer...")
        if cf_invalidation_paths_batch and CLOUDFRONT_DISTRIBUTION_ID:
            monitor_logger.info("Attempting to trigger pending CloudFront invalidations before exit...")
            event_handler._trigger_batched_cloudfront_invalidation()
    except Exception as e:
        monitor_logger.critical(
            f"Critical error in observer loop or setup: {e}", exc_info=True)
    finally:
        monitor_logger.info("Shutting down observer...")
        with cf_invalidation_lock:
            if cf_invalidation_timer and cf_invalidation_timer.is_alive():
                monitor_logger.info(
                    "Cancelling active CloudFront invalidation timer during final shutdown.")
                cf_invalidation_timer.cancel()
        if observer.is_alive():
            observer.stop()
        observer.join() # Esperar o observer thread terminar completamente
        monitor_logger.info("Observer stopped and joined. Exiting script.")
