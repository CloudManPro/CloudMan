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
import queue # Adicionado

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

# --- Configuração para a fila de invalidação ---
invalidation_queue = queue.Queue()
MAX_INVALIDATION_WORKERS = 1 # Comece com 1, pode aumentar se necessário e testado

# Variáveis globais para o watcher
cf_invalidation_paths_batch = [] # Lote principal antes de enfileirar
cf_invalidation_timer = None
cf_invalidation_lock = threading.Lock() # Para proteger cf_invalidation_paths_batch e cf_invalidation_timer
efs_deleted_by_script = set() # Para rastrear deleções feitas pelo script (se necessário)
efs_deletion_lock = threading.Lock() # Para proteger efs_deleted_by_script

# --- Logger Setup ---
def setup_logger(name, log_file, level=logging.INFO, formatter_str='%(asctime)s - %(name)s - %(levelname)s - %(message)s'):
    log_dir = os.path.dirname(log_file)
    if log_dir and not os.path.exists(log_dir):
        try:
            os.makedirs(log_dir, exist_ok=True)
            os.chmod(log_dir, 0o777) # Permissões mais abertas para o diretório
        except Exception as e:
            print(f"Error creating or setting permissions for log directory {log_dir}: {e}")
            log_file = os.path.join("/tmp", os.path.basename(log_file))
            print(f"Falling back to log file: {log_file}")

    try:
        if not os.path.exists(log_file):
            with open(log_file, 'a'):
                pass
        os.chmod(log_file, 0o666) # Permissões mais abertas para o arquivo de log
    except Exception as e:
        print(f"Error touching/chmod log file {log_file}: {e}")

    logger = logging.getLogger(name)
    logger.setLevel(level)
    if not logger.hasHandlers():
        try:
            handler = logging.FileHandler(log_file, mode='a')
            handler.setFormatter(logging.Formatter(formatter_str))
            logger.addHandler(handler)
        except Exception as e:
            print(f"CRITICAL: Failed to create FileHandler for {log_file}: {e}. Logging to file will NOT work.")

        console_handler = logging.StreamHandler()
        console_handler.setLevel(logging.INFO)
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

# --- Worker Thread para Invalidação do CloudFront ---
def cloudfront_invalidation_worker(q, dist_id, cf_connect_timeout, cf_read_timeout):
    """Processa itens da fila de invalidação do CloudFront."""
    worker_boto_config = Config(
        connect_timeout=cf_connect_timeout,
        read_timeout=cf_read_timeout,
        retries={'max_attempts': 2}
    )
    cloudfront_client = boto3.client('cloudfront', config=worker_boto_config)
    monitor_logger.info(f"CloudFront Invalidation Worker (Thread: {threading.get_ident()}) started.")

    while True:
        try:
            paths_to_invalidate_keys, caller_ref_suffix = q.get(timeout=60)
            if paths_to_invalidate_keys is None: # Sinal para terminar
                monitor_logger.info(f"CloudFront Invalidation Worker (Thread: {threading.get_ident()}) received sentinel. Exiting.")
                q.task_done()
                break

            paths_for_cf_api = ["/" + p for p in paths_to_invalidate_keys]
            caller_reference = f"s3-efs-sync-{int(time.time())}-{caller_ref_suffix}"

            monitor_logger.info(
                f"[Worker-{threading.get_ident()}] Attempting CloudFront invalidation for {len(paths_for_cf_api)} paths. CallerRef: {caller_reference}. Paths: {paths_for_cf_api}"
            )
            try:
                cloudfront_client.create_invalidation(
                    DistributionId=dist_id,
                    InvalidationBatch={
                        'Paths': {
                            'Quantity': len(paths_for_cf_api),
                            'Items': paths_for_cf_api
                        },
                        'CallerReference': caller_reference
                    }
                )
                monitor_logger.info(
                    f"[Worker-{threading.get_ident()}] CloudFront invalidation request CREATED for {len(paths_for_cf_api)} paths. CallerRef: {caller_reference}")
                transfer_logger.info(
                    f"INVALIDATED_CF_REQUESTED_ASYNC: {len(paths_for_cf_api)} paths on {dist_id} - Batch: {', '.join(paths_to_invalidate_keys)}")
            except (ConnectTimeoutError, ReadTimeoutError) as e_timeout:
                monitor_logger.error(
                    f"[Worker-{threading.get_ident()}] Boto3 Timeout ({type(e_timeout).__name__}) during CloudFront invalidation. CallerRef: {caller_reference}. Error: {e_timeout}", exc_info=False) # exc_info=False para não poluir demais com tracebacks de timeout
                transfer_logger.info(
                    f"INVALIDATION_CF_BOTO_TIMEOUT_ASYNC: {len(paths_for_cf_api)} paths - {str(e_timeout)}")
            except ClientError as e_client:
                monitor_logger.error(
                    f"[Worker-{threading.get_ident()}] Boto3 ClientError during CloudFront invalidation. CallerRef: {caller_reference}. Error: {e_client}", exc_info=True)
                transfer_logger.info(
                    f"INVALIDATION_CF_BOTO_ERROR_ASYNC: {len(paths_for_cf_api)} paths - {str(e_client)}")
            except Exception as e_unexp:
                monitor_logger.error(
                    f"[Worker-{threading.get_ident()}] Unexpected error during CloudFront invalidation. CallerRef: {caller_reference}. Error: {e_unexp}", exc_info=True)
                transfer_logger.info(
                    f"INVALIDATION_CF_UNEXPECTED_ERROR_ASYNC: {len(paths_for_cf_api)} paths - {str(e_unexp)}")
            finally:
                monitor_logger.info(f"[Worker-{threading.get_ident()}] CloudFront invalidation attempt for CallerRef: {caller_reference} COMPLETED.")
                q.task_done()

        except queue.Empty:
            monitor_logger.debug(f"CloudFront Invalidation Worker (Thread: {threading.get_ident()}) queue empty, continuing to wait.")
            continue
        except Exception as e_worker_loop: # Captura exceções no loop do worker
            monitor_logger.critical(f"CloudFront Invalidation Worker (Thread: {threading.get_ident()}) CRITICAL error in loop: {e_worker_loop}", exc_info=True)
            time.sleep(5) # Evita spam de logs

# --- FileSystem Event Handler Class ---
class Watcher(FileSystemEventHandler):
    def __init__(self):
        super().__init__()
        # O cliente CloudFront é usado pelos workers agora

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
        global cf_invalidation_paths_batch, cf_invalidation_timer, invalidation_queue

        paths_to_enqueue = []
        caller_ref_suffix_for_queue = ""

        with cf_invalidation_lock:
            if paths_override:
                paths_to_enqueue = list(paths_override)
                caller_ref_suffix_for_queue = reference_suffix_override if reference_suffix_override else f"override-batch-{len(paths_to_enqueue)}"
                monitor_logger.info(f"Overridden CloudFront invalidation. Enqueuing {len(paths_to_enqueue)} paths with suffix '{caller_ref_suffix_for_queue}'.")
            elif not cf_invalidation_paths_batch:
                monitor_logger.debug("Batched CloudFront invalidation triggered (via timer or batch full), but main batch is empty.")
                if cf_invalidation_timer:
                    cf_invalidation_timer.cancel()
                    cf_invalidation_timer = None
                return
            else:
                paths_to_enqueue = list(cf_invalidation_paths_batch)
                caller_ref_suffix_for_queue = f"batch-{len(paths_to_enqueue)}"
                cf_invalidation_paths_batch = []
                monitor_logger.debug(f"CloudFront invalidation main batch (size {len(paths_to_enqueue)}) reset. Enqueuing for async processing with suffix '{caller_ref_suffix_for_queue}'.")

            if cf_invalidation_timer:
                cf_invalidation_timer.cancel()
                cf_invalidation_timer = None
                monitor_logger.debug("Cancelled CloudFront invalidation timer as batch is being enqueued.")

        if not paths_to_enqueue:
            monitor_logger.debug("No paths to enqueue for invalidation.")
            return

        if not CLOUDFRONT_DISTRIBUTION_ID:
            monitor_logger.warning(
                f"CLOUDFRONT_DISTRIBUTION_ID not set. Skipping enqueueing CloudFront invalidation for: {paths_to_enqueue}")
            return

        try:
            invalidation_queue.put((paths_to_enqueue, caller_ref_suffix_for_queue))
            monitor_logger.info(f"Enqueued {len(paths_to_enqueue)} paths for CloudFront invalidation (Suffix: {caller_ref_suffix_for_queue}). Current queue size: {invalidation_queue.qsize()}")
        except Exception as e_enqueue:
            monitor_logger.error(f"Error enqueuing paths for CloudFront invalidation: {e_enqueue}", exc_info=True)

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
                    f"CloudFront invalidation batch reached max size ({CF_INVALIDATION_BATCH_MAX_SIZE}). Triggering (will be enqueued).")
                self._trigger_batched_cloudfront_invalidation()
            elif cf_invalidation_paths_batch:
                cf_invalidation_timer = threading.Timer(
                    CF_INVALIDATION_BATCH_TIMEOUT_SECONDS, self._trigger_batched_cloudfront_invalidation)
                cf_invalidation_timer.daemon = True
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
                capture_output=True, text=True, check=False,
                timeout=AWS_CLI_TIMEOUT_S3_CP
            )
            if process.returncode == 0:
                monitor_logger.info(f"S3 copy OK for '{relative_file_path}'.")
                transfer_logger.info(
                    f"TRANSFERRED: {relative_file_path} to {s3_full_uri}")
                last_sync_file_map[local_path] = current_time
                if not is_initial_sync:
                    self._add_to_cf_invalidation_batch(relative_file_path)
                if effective_replace_with_placeholder:
                    _, ext = os.path.splitext(local_path)
                    if ext.lower() in PLACEHOLDER_TARGET_EXTENSIONS_EFS:
                        _replace_efs_file_with_placeholder(local_path, relative_file_path)
                    else:
                        monitor_logger.info(f"File '{local_path}' (ext: {ext.lower()}) not targeted for placeholder. Kept on EFS.")
            else:
                monitor_logger.error(
                    f"S3 copy FAILED for '{relative_file_path}'. RC: {process.returncode}. Stderr: {process.stderr.strip()}")
                transfer_logger.info(f"S3_CP_FAILED: {relative_file_path} RC={process.returncode} ERR={process.stderr.strip()}")
        except subprocess.TimeoutExpired:
            monitor_logger.error(f"S3 copy TIMEOUT for '{relative_file_path}' after {AWS_CLI_TIMEOUT_S3_CP}s.")
            transfer_logger.info(f"S3_CP_TIMEOUT: {relative_file_path}")
        except FileNotFoundError:
            monitor_logger.error(f"AWS CLI not found at '{AWS_CLI_PATH}'. S3 copy failed for '{relative_file_path}'.")
        except Exception as e:
            monitor_logger.error(f"Exception during S3 copy for {relative_file_path}: {e}", exc_info=True)

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
                capture_output=True, text=True, check=False,
                timeout=AWS_CLI_TIMEOUT_S3_RM
            )
            cli_rc = process.returncode
            cli_stderr = process.stderr.strip()
            if cli_rc == 0:
                monitor_logger.info(f"AWS CLI 's3 rm' for '{relative_file_path}' reported success (RC: 0).")
                transfer_logger.info(f"DELETED_S3_CLI_OK: {relative_file_path}")
                cli_delete_reported_success = True
            else:
                monitor_logger.error(f"AWS CLI 's3 rm' FAILED for '{relative_file_path}'. RC: {cli_rc}. Stderr: {cli_stderr}")
                transfer_logger.info(f"DELETED_S3_CLI_FAILED: {relative_file_path} - RC={cli_rc} ERR={cli_stderr}")
        except subprocess.TimeoutExpired:
            monitor_logger.error(f"S3 rm TIMEOUT for '{relative_file_path}' after {AWS_CLI_TIMEOUT_S3_RM}s.")
            transfer_logger.info(f"S3_RM_TIMEOUT: {relative_file_path}")
            return
        except FileNotFoundError:
            monitor_logger.error(f"AWS CLI not found at '{AWS_CLI_PATH}'. S3 delete failed for '{relative_file_path}'.")
            return
        except Exception as e:
            monitor_logger.error(f"Exception during AWS CLI 's3 rm' for {relative_file_path}: {e}", exc_info=True)

        monitor_logger.info(f"Verifying deletion of '{s3_target_path_key}' in S3 using Boto3 head_object...")
        try:
            time.sleep(1)
            s3_client_boto.head_object(Bucket=S3_BUCKET, Key=s3_target_path_key)
            monitor_logger.error(f"S3 delete VERIFICATION FAILED for '{relative_file_path}'. Object still found. CLI RC: {cli_rc}.")
            if cli_stderr: monitor_logger.error(f"CLI Stderr was: {cli_stderr}")
            transfer_logger.info(f"DELETED_S3_VERIFICATION_FAILED_STILL_EXISTS: {relative_file_path}")
        except s3_client_boto.exceptions.ClientError as e:
            if e.response['Error']['Code'] in ('404', 'NoSuchKey'):
                monitor_logger.info(f"S3 delete VERIFIED for '{relative_file_path}'. Not found. CLI RC: {cli_rc}.")
                transfer_logger.info(f"DELETED_S3_VERIFIED_NOT_FOUND: {relative_file_path}")
                self._add_to_cf_invalidation_batch(relative_file_path)
            else:
                monitor_logger.error(f"Boto3 ClientError during S3 delete VERIFICATION for '{relative_file_path}': {e.response['Error']['Code']}. CLI RC: {cli_rc}.")
                transfer_logger.info(f"DELETED_S3_VERIFICATION_ERROR_HEAD_OBJECT: {relative_file_path} - {e.response['Error']['Code']}")
        except Exception as ve:
            monitor_logger.error(f"Unexpected error during S3 delete VERIFICATION for '{s3_target_path_key}': {ve}", exc_info=True)
            transfer_logger.info(f"DELETED_S3_VERIFICATION_UNEXPECTED_ERROR: {relative_file_path}")

    def process_event_for_sync(self, event_type, path, dest_path=None):
        global efs_deleted_by_script
        if event_type == 'moved_from':
            if self._is_excluded(path) or (os.path.exists(path) and os.path.isdir(path)): return
            relevant_src, relative_src_path = is_path_relevant(path, MONITOR_DIR_BASE, RELEVANT_PATTERNS)
            if not relevant_src or not relative_src_path: return
            monitor_logger.info(f"Event: MOVED_FROM for relevant file '{relative_src_path}' (full: {path})")
            ignore_s3_deletion_for_moved_src = False
            with efs_deletion_lock:
                if path in efs_deleted_by_script:
                    monitor_logger.info(f"EFS MOVED_FROM for '{path}' was script-initiated. Not deleting from S3 for source.")
                    efs_deleted_by_script.remove(path)
                    ignore_s3_deletion_for_moved_src = True
            if not ignore_s3_deletion_for_moved_src:
                self._handle_s3_delete(relative_src_path)
            else:
                transfer_logger.info(f"SKIPPED_S3_DELETE_MOVED_FROM_BY_SCRIPT_FLAG: {relative_src_path}")
            return

        current_path_to_check = dest_path if event_type == 'moved_to' else path
        if self._is_excluded(current_path_to_check) or \
           (os.path.exists(current_path_to_check) and os.path.isdir(current_path_to_check)): return
        relevant, relative_path = is_path_relevant(current_path_to_check, MONITOR_DIR_BASE, RELEVANT_PATTERNS)
        if not relevant or not relative_path: return

        if event_type == 'modified' and os.path.exists(current_path_to_check):
            try:
                if os.path.getsize(current_path_to_check) == len(PLACEHOLDER_CONTENT.encode('utf-8')):
                    with open(current_path_to_check, 'r') as f_check: content = f_check.read()
                    if content == PLACEHOLDER_CONTENT:
                        monitor_logger.info(f"Event: MODIFIED for placeholder '{relative_path}'. Skipping S3 upload.")
                        return
            except OSError: pass
        monitor_logger.info(f"Event: {event_type.upper()} for relevant file '{relative_path}' (full: {current_path_to_check})")
        if event_type in ['created', 'modified', 'moved_to']:
            self._handle_s3_upload(current_path_to_check, relative_path)
        elif event_type == 'deleted':
            self._handle_s3_delete(relative_path)

    def on_created(self, event):
        if not event.is_directory: self.process_event_for_sync('created', event.src_path)
    def on_modified(self, event):
        if not event.is_directory: self.process_event_for_sync('modified', event.src_path)
    def on_deleted(self, event):
        if not event.is_directory: self.process_event_for_sync('deleted', event.src_path)
    def on_moved(self, event):
        if not os.path.isdir(event.src_path): self.process_event_for_sync('moved_from', event.src_path)
        if not event.is_directory: self.process_event_for_sync('moved_to', event.src_path, dest_path=event.dest_path)

# --- Initial Sync Function ---
def run_s3_sync_command(command_parts, description):
    monitor_logger.info(f"Attempting Initial Sync for {description} (timeout: {AWS_CLI_TIMEOUT_S3_CP}s)")
    try:
        process = subprocess.run(command_parts, capture_output=True, text=True, check=False, timeout=AWS_CLI_TIMEOUT_S3_CP)
        if process.returncode == 0:
            monitor_logger.info(f"Initial Sync for {description} OK.")
            transfer_logger.info(f"INITIAL_SYNC_SUCCESS: {description}")
            return True
        elif process.returncode == 2: # RC 2 for s3 sync can mean some files didn't sync
            monitor_logger.warning(f"Initial Sync for {description} RC 2 (some files may not have synced). Stderr: {process.stderr.strip()}")
            transfer_logger.info(f"INITIAL_SYNC_WARNING_RC2: {description} - ERR: {process.stderr.strip()}")
            return True # Still proceed
        else:
            monitor_logger.error(f"Initial Sync for {description} FAILED. RC: {process.returncode}. Stderr: {process.stderr.strip()}")
            transfer_logger.info(f"INITIAL_SYNC_FAILED: {description} - RC={process.returncode} ERR={process.stderr.strip()}")
            return False
    except subprocess.TimeoutExpired:
        monitor_logger.error(f"Initial Sync TIMEOUT for '{description}' after {AWS_CLI_TIMEOUT_S3_CP}s.")
        transfer_logger.info(f"INITIAL_SYNC_TIMEOUT: {description}")
        return False
    except FileNotFoundError:
        monitor_logger.error(f"AWS CLI not found. Initial Sync for {description} failed.")
        return False
    except Exception as e:
        monitor_logger.error(f"Exception during Initial Sync for {description}: {e}", exc_info=True)
        return False

def perform_initial_sync(watcher_instance):
    monitor_logger.info("--- Starting Initial S3 Sync ---")
    if not S3_BUCKET or not os.path.isdir(MONITOR_DIR_BASE):
        monitor_logger.error("S3_BUCKET or MONITOR_DIR_BASE not configured/valid. Skipping initial sync.")
        return

    general_sync_includes = [
        '*.css', '*.js', '*.jpg', '*.jpeg', '*.png', '*.gif', '*.svg', '*.webp', '*.ico',
        '*.woff', '*.woff2', '*.ttf', '*.eot', '*.otf', '*.mp4', '*.mov', '*.webm',
        '*.avi', '*.wmv', '*.mkv', '*.flv', '*.mp3', '*.wav', '*.ogg', '*.aac',
        '*.wma', '*.flac', '*.pdf', '*.doc', '*.docx', '*.xls', '*.xlsx', '*.ppt',
        '*.pptx', '*.zip', '*.txt',
    ]
    includes_for_sync_cmd = [arg for item in general_sync_includes for arg in ('--include', item)]

    wp_content_path = os.path.join(MONITOR_DIR_BASE, "wp-content")
    if os.path.isdir(wp_content_path):
        cmd = [AWS_CLI_PATH, 's3', 'sync', wp_content_path, f"s3://{S3_BUCKET}/wp-content/",
               '--exclude', '*.php', '--exclude', '*/index.php', '--exclude', '*/cache/*',
               '--exclude', '*/backups/*', '--exclude', '*/.DS_Store', '--exclude', '*/Thumbs.db',
               '--exclude', '*/node_modules/*', '--exclude', '*/.git/*'] + \
              includes_for_sync_cmd + ['--exact-timestamps', '--acl', 'private', '--only-show-errors']
        run_s3_sync_command(cmd, "wp-content")

    wp_includes_path = os.path.join(MONITOR_DIR_BASE, "wp-includes")
    if os.path.isdir(wp_includes_path):
        assets_includes = ['*.css', '*.js', '*.jpg', '*.jpeg', '*.png', '*.gif', '*.svg', '*.webp', '*.ico',
                           '*.woff', '*.woff2', '*.ttf', '*.eot', '*.otf']
        cmd_includes = [arg for item in assets_includes for arg in ('--include', item)]
        cmd = [AWS_CLI_PATH, 's3', 'sync', wp_includes_path, f"s3://{S3_BUCKET}/wp-includes/",
               '--exclude', '*'] + cmd_includes + \
              ['--exact-timestamps', '--acl', 'private', '--only-show-errors']
        run_s3_sync_command(cmd, "wp-includes (assets only)")

    monitor_logger.info("--- Initial S3 Sync Attempted ---")
    if DELETE_FROM_EFS_AFTER_SYNC:
        monitor_logger.info("--- Starting EFS placeholder replacement for initially synced files ---")
        for scan_root in (p for p in (wp_content_path, wp_includes_path) if os.path.isdir(p)):
            for root, _, files in os.walk(scan_root):
                for filename in files:
                    local_path = os.path.join(root, filename)
                    if watcher_instance._is_excluded(local_path): continue
                    is_relevant, rel_path = is_path_relevant(local_path, MONITOR_DIR_BASE, RELEVANT_PATTERNS)
                    if is_relevant and os.path.splitext(local_path)[1].lower() in PLACEHOLDER_TARGET_EXTENSIONS_EFS:
                        try:
                            if os.path.exists(local_path) and \
                               os.path.getsize(local_path) == len(PLACEHOLDER_CONTENT.encode('utf-8')) and \
                               open(local_path, 'r').read() == PLACEHOLDER_CONTENT:
                                continue # Already a placeholder
                        except OSError: pass
                        if os.path.exists(local_path):
                            _replace_efs_file_with_placeholder(local_path, rel_path)
        monitor_logger.info("--- EFS placeholder replacement Attempted ---")

    if CLOUDFRONT_DISTRIBUTION_ID:
        monitor_logger.info("Initial sync complete. Enqueuing full CloudFront invalidation (/*).")
        watcher_instance._trigger_batched_cloudfront_invalidation(paths_override=['/*'], reference_suffix_override="initial-sync-full")


# --- Main Execution Block ---
if __name__ == "__main__":
    script_version_tag = "v2.4.3-AsyncCFInvalidation"
    monitor_logger.info(f"Python Watchdog Monitor ({script_version_tag}) starting for '{MONITOR_DIR_BASE}'.")
    # ... (outros logs de inicialização)
    monitor_logger.info(f"Max Invalidation Workers: {MAX_INVALIDATION_WORKERS}")

    if not S3_BUCKET: monitor_logger.critical("S3_BUCKET not set. Exiting."); exit(1)
    if not os.path.isdir(MONITOR_DIR_BASE): monitor_logger.critical(f"Monitor dir '{MONITOR_DIR_BASE}' not found. Exiting."); exit(1)
    AWS_CLI_PATH = shutil.which(AWS_CLI_PATH) or AWS_CLI_PATH # Resolve para path completo se possível
    if not shutil.which(AWS_CLI_PATH): monitor_logger.critical(f"AWS CLI at '{AWS_CLI_PATH}' not found. Exiting."); exit(1)
    monitor_logger.info(f"Using AWS CLI at: {AWS_CLI_PATH}")
    try: boto3.client('s3'); monitor_logger.info("Boto3 S3 client OK.")
    except Exception as e: monitor_logger.critical(f"Boto3 S3 client init failed: {e}", exc_info=True); exit(1)

    invalidation_worker_threads = []
    if CLOUDFRONT_DISTRIBUTION_ID:
        for i in range(MAX_INVALIDATION_WORKERS):
            thread = threading.Thread(target=cloudfront_invalidation_worker,
                                     args=(invalidation_queue, CLOUDFRONT_DISTRIBUTION_ID,
                                           BOTO3_CLOUDFRONT_CONNECT_TIMEOUT, BOTO3_CLOUDFRONT_READ_TIMEOUT),
                                     name=f"CFInvalidationWorker-{i}")
            thread.daemon = True
            thread.start()
            invalidation_worker_threads.append(thread)
        monitor_logger.info(f"Started {len(invalidation_worker_threads)} CloudFront invalidation worker(s).")
    else:
        monitor_logger.warning("CLOUDFRONT_DISTRIBUTION_ID not set, workers NOT started.")

    event_handler = Watcher()
    if PERFORM_INITIAL_SYNC: perform_initial_sync(event_handler)
    if not RELEVANT_PATTERNS: monitor_logger.warning("RELEVANT_PATTERNS is empty. Watcher may not process new files as expected.")

    observer = Observer()
    observer.schedule(event_handler, MONITOR_DIR_BASE, recursive=True)
    observer.start()
    monitor_logger.info("Observer started. Monitoring for file changes...")

    try:
        while observer.is_alive():
            observer.join(1)
    except KeyboardInterrupt:
        monitor_logger.info("KeyboardInterrupt received. Shutting down...")
    except Exception as e_main_loop:
        monitor_logger.critical(f"CRITICAL error in main observer loop: {e_main_loop}", exc_info=True)
    finally:
        monitor_logger.info("Initiating shutdown sequence...")
        if observer.is_alive():
            monitor_logger.info("Stopping observer...")
            observer.stop()
        monitor_logger.info("Waiting for observer to join...")
        observer.join()
        monitor_logger.info("Observer stopped and joined.")

        if CLOUDFRONT_DISTRIBUTION_ID and invalidation_worker_threads:
            monitor_logger.info("Signaling CloudFront invalidation workers to terminate...")
            for _ in invalidation_worker_threads:
                try: invalidation_queue.put((None, None), block=False)
                except queue.Full: monitor_logger.warning("Queue full while sending termination sentinels."); break
            
            monitor_logger.info(f"Waiting for {invalidation_queue.qsize()} items in invalidation queue to be processed (max 30s)...")
            try:
                invalidation_queue.join() # Espera que a fila seja esvaziada pelos workers
                monitor_logger.info("Invalidation queue processed.")
            except Exception as e_q_join: # Em Python < 3.9, join() não tem timeout, mas KeyboardInterrupt pode ocorrer
                 monitor_logger.warning(f"Exception during invalidation_queue.join(): {e_q_join}. Some tasks might be pending.")


            # # Esperar os threads terminarem (opcional, pois são daemon e a fila join() deve cobrir)
            # for t in invalidation_worker_threads:
            #     if t.is_alive():
            #         monitor_logger.info(f"Joining worker thread {t.name}...")
            #         t.join(timeout=5) # Dê um pequeno timeout para o join do thread
            #         if t.is_alive():
            #              monitor_logger.warning(f"Worker thread {t.name} did not exit cleanly after sentinel and join.")
        
        # Cancela o timer principal de invalidação, se ativo
        with cf_invalidation_lock:
            if cf_invalidation_timer and cf_invalidation_timer.is_alive():
                monitor_logger.info("Cancelling main CloudFront invalidation timer.")
                cf_invalidation_timer.cancel()

        monitor_logger.info("Script shutdown complete.")
