#!/usr/bin/env python3
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
import queue

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

AWS_CLI_TIMEOUT_S3_CP = 300
AWS_CLI_TIMEOUT_S3_RM = 60
BOTO3_CLOUDFRONT_CONNECT_TIMEOUT = 10
BOTO3_CLOUDFRONT_READ_TIMEOUT = 60
BOTO3_S3_CONNECT_TIMEOUT = 5 # Timeout para head_object
BOTO3_S3_READ_TIMEOUT = 10    # Timeout para head_object

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

invalidation_queue = queue.Queue()
MAX_INVALIDATION_WORKERS = 1

cf_invalidation_paths_batch = []
cf_invalidation_timer = None
cf_invalidation_lock = threading.RLock()
efs_deleted_by_script = set()
efs_deletion_lock = threading.RLock()

# --- Logger Setup ---
def setup_logger(name, log_file, level=logging.INFO, formatter_str='%(asctime)s - %(name)s - %(levelname)s - %(message)s'):
    log_dir = os.path.dirname(log_file)
    if log_dir and not os.path.exists(log_dir):
        try:
            os.makedirs(log_dir, exist_ok=True)
            os.chmod(log_dir, 0o777)
        except Exception as e:
            print(f"Error creating or setting permissions for log directory {log_dir}: {e}")
            log_file = os.path.join("/tmp", os.path.basename(log_file))
            print(f"Falling back to log file: {log_file}")
    try:
        if not os.path.exists(log_file):
            with open(log_file, 'a'): pass
        os.chmod(log_file, 0o666)
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
            print(f"CRITICAL: Failed to create FileHandler for {log_file}: {e}.")
        console_handler = logging.StreamHandler()
        console_handler.setLevel(logging.INFO)
        console_handler.setFormatter(logging.Formatter(formatter_str))
        logger.addHandler(console_handler)
    return logger

monitor_logger = setup_logger('PY_MONITOR', LOG_FILE_MONITOR)
transfer_logger = setup_logger('PY_S3_TRANSFER', S3_TRANSFER_LOG, formatter_str='%(asctime)s - %(message)s')

# --- Helper Functions ---
def is_path_relevant(path_to_check, base_dir, patterns):
    if not path_to_check.startswith(base_dir + os.path.sep): return False, None
    relative_file_path = os.path.relpath(path_to_check, base_dir)
    is_relevant = any(fnmatch.fnmatch(relative_file_path, pattern) for pattern in patterns)
    return is_relevant, relative_file_path

def _replace_efs_file_with_placeholder(local_path, relative_file_path):
    try:
        with open(local_path, 'w') as f_placeholder: f_placeholder.write(PLACEHOLDER_CONTENT)
        monitor_logger.info(f"Successfully replaced EFS file '{local_path}' with placeholder.")
        transfer_logger.info(f"EFS_PLACEHOLDER_CREATED: {relative_file_path}")
        return True
    except OSError as e: monitor_logger.error(f"Failed to replace EFS file '{local_path}' with placeholder: {e}"); return False
    except Exception as e: monitor_logger.error(f"Unexpected error replacing EFS file '{local_path}' with placeholder: {e}", exc_info=True); return False

# --- Worker Thread para Invalidação do CloudFront ---
def cloudfront_invalidation_worker(q, dist_id, cf_connect_timeout, cf_read_timeout):
    worker_boto_config = Config(connect_timeout=cf_connect_timeout, read_timeout=cf_read_timeout, retries={'max_attempts': 2})
    cloudfront_client = boto3.client('cloudfront', config=worker_boto_config)
    monitor_logger.info(f"CloudFront Invalidation Worker (Thread: {threading.get_ident()}) started.")
    while True:
        try:
            paths_to_invalidate_keys, caller_ref_suffix = q.get(timeout=60)
            if paths_to_invalidate_keys is None:
                monitor_logger.info(f"CloudFront Invalidation Worker (Thread: {threading.get_ident()}) received sentinel. Exiting.")
                q.task_done(); break
            paths_for_cf_api = ["/" + p for p in paths_to_invalidate_keys]
            caller_reference = f"s3-efs-sync-{int(time.time())}-{caller_ref_suffix}"
            monitor_logger.info(f"[Worker-{threading.get_ident()}] Attempting CF invalidation for {len(paths_for_cf_api)} paths. CallerRef: {caller_reference}. Paths: {paths_for_cf_api}")
            try:
                cloudfront_client.create_invalidation(
                    DistributionId=dist_id,
                    InvalidationBatch={'Paths': {'Quantity': len(paths_for_cf_api), 'Items': paths_for_cf_api}, 'CallerReference': caller_reference}
                )
                monitor_logger.info(f"[Worker-{threading.get_ident()}] CF invalidation request CREATED for {len(paths_for_cf_api)} paths. CallerRef: {caller_reference}")
                transfer_logger.info(f"INVALIDATED_CF_REQUESTED_ASYNC: {len(paths_for_cf_api)} paths on {dist_id} - Batch: {', '.join(paths_to_invalidate_keys)}")
            except (ConnectTimeoutError, ReadTimeoutError) as e_timeout:
                monitor_logger.error(f"[Worker-{threading.get_ident()}] Boto3 Timeout ({type(e_timeout).__name__}) during CF invalidation. CallerRef: {caller_reference}. Error: {e_timeout}", exc_info=False)
                transfer_logger.info(f"INVALIDATION_CF_BOTO_TIMEOUT_ASYNC: {len(paths_for_cf_api)} paths - {str(e_timeout)}")
            except ClientError as e_client:
                monitor_logger.error(f"[Worker-{threading.get_ident()}] Boto3 ClientError during CF invalidation. CallerRef: {caller_reference}. Error: {e_client}", exc_info=True)
                transfer_logger.info(f"INVALIDATION_CF_BOTO_ERROR_ASYNC: {len(paths_for_cf_api)} paths - {str(e_client)}")
            except Exception as e_unexp:
                monitor_logger.error(f"[Worker-{threading.get_ident()}] Unexpected error during CF invalidation. CallerRef: {caller_reference}. Error: {e_unexp}", exc_info=True)
                transfer_logger.info(f"INVALIDATION_CF_UNEXPECTED_ERROR_ASYNC: {len(paths_for_cf_api)} paths - {str(e_unexp)}")
            finally:
                monitor_logger.info(f"[Worker-{threading.get_ident()}] CF invalidation attempt for CallerRef: {caller_reference} COMPLETED.")
                q.task_done()
        except queue.Empty: monitor_logger.debug(f"CF Invalidation Worker (Thread: {threading.get_ident()}) queue empty, waiting."); continue
        except Exception as e_worker_loop: monitor_logger.critical(f"CF Invalidation Worker (Thread: {threading.get_ident()}) CRITICAL error: {e_worker_loop}", exc_info=True); time.sleep(5)

# --- FileSystem Event Handler Class ---
class Watcher(FileSystemEventHandler):
    def __init__(self):
        super().__init__()
        s3_client_config = Config(
            connect_timeout=BOTO3_S3_CONNECT_TIMEOUT,
            read_timeout=BOTO3_S3_READ_TIMEOUT,
            retries={'max_attempts': 2}
        )
        self.s3_client_boto = boto3.client('s3', config=s3_client_config) # Cliente S3 para head_object

    def _is_excluded(self, filepath):
        filename = os.path.basename(filepath)
        if filename.startswith('.') or filename.endswith(('.swp', '.swx', '~', '.part', '.crdownload', '.tmp')): return True
        if '/cache/' in filepath or '/.git/' in filepath or '/node_modules/' in filepath: return True
        if '/uploads/sites/' in filepath: monitor_logger.debug(f"Excluding Multisite upload path: {filepath}"); return True
        return False

    def _get_s3_path(self, relative_file_path):
        return f"s3://{S3_BUCKET}/{relative_file_path}"

    def _s3_object_exists(self, bucket, key):
        """Verifica se um objeto existe no S3 usando o cliente S3 da instância."""
        try:
            self.s3_client_boto.head_object(Bucket=bucket, Key=key)
            monitor_logger.debug(f"S3 object check: '{key}' EXISTS in bucket '{bucket}'.")
            return True
        except ClientError as e:
            if e.response['Error']['Code'] in ('404', 'NoSuchKey', '403'): # 403 pode significar que não existe ou não temos permissão para head, tratar como não existente para esta lógica
                monitor_logger.debug(f"S3 object check: '{key}' does NOT exist or not accessible in bucket '{bucket}'. Error: {e.response['Error']['Code']}")
                return False
            else:
                monitor_logger.error(f"ClientError checking S3 object '{key}': {e}", exc_info=True)
                return False # Em caso de outro erro, assumir que não existe para evitar invalidações desnecessárias
        except Exception as e_unexp:
            monitor_logger.error(f"Unexpected error during S3 object check for '{key}': {e_unexp}", exc_info=True)
            return False


    def _trigger_batched_cloudfront_invalidation(self, paths_override=None, reference_suffix_override=None):
        global cf_invalidation_paths_batch, cf_invalidation_timer, invalidation_queue
        monitor_logger.debug(f"[TRIGGER_ENTRY] _trigger_batched_cloudfront_invalidation called. paths_override: {paths_override is not None}, current_batch_size: {len(cf_invalidation_paths_batch)}")
        paths_to_enqueue = []
        caller_ref_suffix_for_queue = ""
        monitor_logger.debug("[TRIGGER_LOCK] Attempting to acquire cf_invalidation_lock (RLock).")
        with cf_invalidation_lock:
            monitor_logger.debug("[TRIGGER_LOCK] cf_invalidation_lock (RLock) ACQUIRED.")
            if paths_override:
                paths_to_enqueue = list(paths_override)
                caller_ref_suffix_for_queue = reference_suffix_override if reference_suffix_override else f"override-batch-{len(paths_to_enqueue)}"
                monitor_logger.info(f"[TRIGGER_LOGIC] Overridden CF invalidation. Enqueuing {len(paths_to_enqueue)} paths with suffix '{caller_ref_suffix_for_queue}'.")
            elif not cf_invalidation_paths_batch:
                monitor_logger.debug("[TRIGGER_LOGIC] Batched CF invalidation triggered, but main batch is empty. Checking timer.")
                if cf_invalidation_timer and cf_invalidation_timer.is_alive():
                    monitor_logger.debug("[TRIGGER_TIMER] Cancelling existing timer (batch empty).")
                    cf_invalidation_timer.cancel()
                cf_invalidation_timer = None
                monitor_logger.debug("[TRIGGER_LOCK] Releasing cf_invalidation_lock (RLock) (batch empty).")
                return
            else:
                paths_to_enqueue = list(cf_invalidation_paths_batch)
                caller_ref_suffix_for_queue = f"batch-{len(paths_to_enqueue)}"
                cf_invalidation_paths_batch = []
                monitor_logger.debug(f"[TRIGGER_LOGIC] CF invalidation main batch (size {len(paths_to_enqueue)}) reset. Enqueuing for async processing with suffix '{caller_ref_suffix_for_queue}'.")
            if cf_invalidation_timer and cf_invalidation_timer.is_alive():
                monitor_logger.debug("[TRIGGER_TIMER] Cancelling existing timer (batch being enqueued/processed).")
                cf_invalidation_timer.cancel()
            cf_invalidation_timer = None
            monitor_logger.debug("[TRIGGER_LOCK] Releasing cf_invalidation_lock (RLock) (before enqueue logic).")
        if not paths_to_enqueue:
            monitor_logger.debug("[TRIGGER_ENQUEUE] No paths to enqueue for invalidation after lock release.")
            return
        if not CLOUDFRONT_DISTRIBUTION_ID:
            monitor_logger.warning(f"[TRIGGER_ENQUEUE] CLOUDFRONT_DISTRIBUTION_ID not set. Skipping enqueueing for: {paths_to_enqueue}")
            return
        monitor_logger.info(f"[TRIGGER_ENQUEUE] Attempting to put {len(paths_to_enqueue)} paths onto invalidation_queue (Suffix: {caller_ref_suffix_for_queue}).")
        try:
            invalidation_queue.put((paths_to_enqueue, caller_ref_suffix_for_queue))
            monitor_logger.info(f"[TRIGGER_ENQUEUE] Successfully enqueued {len(paths_to_enqueue)} paths. Current queue size: {invalidation_queue.qsize()}")
        except Exception as e_enqueue:
            monitor_logger.error(f"[TRIGGER_ENQUEUE] Error enqueuing paths for CF invalidation: {e_enqueue}", exc_info=True)
        monitor_logger.debug(f"[TRIGGER_EXIT] _trigger_batched_cloudfront_invalidation finished for suffix {caller_ref_suffix_for_queue}.")

    def _add_to_cf_invalidation_batch(self, object_key_to_invalidate):
        global cf_invalidation_paths_batch, cf_invalidation_timer
        monitor_logger.debug(f"[ADD_BATCH_ENTRY] _add_to_cf_invalidation_batch called for '{object_key_to_invalidate}'.")
        trigger_invalidation_now = False
        monitor_logger.debug("[ADD_BATCH_LOCK] Attempting to acquire cf_invalidation_lock (RLock).")
        with cf_invalidation_lock:
            monitor_logger.debug("[ADD_BATCH_LOCK] cf_invalidation_lock (RLock) ACQUIRED.")
            if object_key_to_invalidate not in cf_invalidation_paths_batch:
                cf_invalidation_paths_batch.append(object_key_to_invalidate)
                monitor_logger.info(f"[ADD_BATCH_LOGIC] Added '{object_key_to_invalidate}' to CF invalidation batch. Batch size: {len(cf_invalidation_paths_batch)}")
            else:
                monitor_logger.debug(f"[ADD_BATCH_LOGIC] '{object_key_to_invalidate}' already in batch. Skipping add.")
            if cf_invalidation_timer and cf_invalidation_timer.is_alive():
                monitor_logger.debug("[ADD_BATCH_TIMER] Cancelling existing CF invalidation timer.")
                cf_invalidation_timer.cancel()
            if len(cf_invalidation_paths_batch) >= CF_INVALIDATION_BATCH_MAX_SIZE:
                monitor_logger.info(f"[ADD_BATCH_LOGIC] CF invalidation batch reached max size ({CF_INVALIDATION_BATCH_MAX_SIZE}). Will trigger after lock release.")
                trigger_invalidation_now = True
                cf_invalidation_timer = None
            elif cf_invalidation_paths_batch:
                monitor_logger.debug(f"[ADD_BATCH_TIMER] Batch size {len(cf_invalidation_paths_batch)} < max. (Re)starting timer for {CF_INVALIDATION_BATCH_TIMEOUT_SECONDS}s.")
                cf_invalidation_timer = threading.Timer(CF_INVALIDATION_BATCH_TIMEOUT_SECONDS, self._trigger_batched_cloudfront_invalidation_from_timer_context)
                cf_invalidation_timer.daemon = True
                cf_invalidation_timer.start()
            else:
                monitor_logger.debug("[ADD_BATCH_LOGIC] Batch is empty, no timer started/restarted.")
                cf_invalidation_timer = None
            monitor_logger.debug("[ADD_BATCH_LOCK] Releasing cf_invalidation_lock (RLock).")
        if trigger_invalidation_now:
            monitor_logger.debug("[ADD_BATCH_TRIGGER_NOW] Calling _trigger_batched_cloudfront_invalidation due to full batch (lock released).")
            self._trigger_batched_cloudfront_invalidation()
        monitor_logger.debug(f"[ADD_BATCH_EXIT] _add_to_cf_invalidation_batch finished for '{object_key_to_invalidate}'.")

    def _trigger_batched_cloudfront_invalidation_from_timer_context(self):
        monitor_logger.info(f"CloudFront invalidation timer (target: {CF_INVALIDATION_BATCH_TIMEOUT_SECONDS}s) expired. Triggering batch processing.")
        self._trigger_batched_cloudfront_invalidation()

    def _handle_s3_upload(self, local_path, relative_file_path, is_initial_sync=False):
        effective_replace_with_placeholder = DELETE_FROM_EFS_AFTER_SYNC and not is_initial_sync
        current_time = time.time()
        if not is_initial_sync and local_path in last_sync_file_map and \
           (current_time - last_sync_file_map[local_path] < SYNC_DEBOUNCE_SECONDS):
            monitor_logger.info(f"Debounce for '{local_path}'. Skipped upload.")
            return

        s3_full_uri = self._get_s3_path(relative_file_path)
        object_existed_before_upload = False
        if not is_initial_sync: # Só checar para eventos em tempo real
            object_existed_before_upload = self._s3_object_exists(S3_BUCKET, relative_file_path)

        monitor_logger.info(f"Attempting S3 copy: '{local_path}' to '{s3_full_uri}' (Timeout: {AWS_CLI_TIMEOUT_S3_CP}s). Object existed before: {object_existed_before_upload}")
        try:
            process = subprocess.run(
                [AWS_CLI_PATH, 's3', 'cp', local_path, s3_full_uri, '--acl', 'private', '--only-show-errors'],
                capture_output=True, text=True, check=False, timeout=AWS_CLI_TIMEOUT_S3_CP
            )
            if process.returncode == 0:
                monitor_logger.info(f"S3 copy OK for '{relative_file_path}'.")
                transfer_logger.info(f"TRANSFERRED: {relative_file_path} to {s3_full_uri}")
                last_sync_file_map[local_path] = current_time
                if not is_initial_sync:
                    if object_existed_before_upload: # Só invalidar se o objeto foi sobrescrito
                        monitor_logger.info(f"S3 object '{relative_file_path}' was OVERWRITTEN. Adding to CF invalidation batch.")
                        self._add_to_cf_invalidation_batch(relative_file_path)
                    else:
                        monitor_logger.info(f"S3 object '{relative_file_path}' is NEW. Skipping CF invalidation for this upload.")
                if effective_replace_with_placeholder:
                    _, ext = os.path.splitext(local_path)
                    if ext.lower() in PLACEHOLDER_TARGET_EXTENSIONS_EFS: _replace_efs_file_with_placeholder(local_path, relative_file_path)
                    else: monitor_logger.info(f"File '{local_path}' not targeted for placeholder.")
            else:
                monitor_logger.error(f"S3 copy FAILED for '{relative_file_path}'. RC: {process.returncode}. Stderr: {process.stderr.strip()}")
                transfer_logger.info(f"S3_CP_FAILED: {relative_file_path} RC={process.returncode} ERR={process.stderr.strip()}")
        except subprocess.TimeoutExpired:
            monitor_logger.error(f"S3 copy TIMEOUT for '{relative_file_path}' after {AWS_CLI_TIMEOUT_S3_CP}s.")
            transfer_logger.info(f"S3_CP_TIMEOUT: {relative_file_path}")
        except FileNotFoundError: monitor_logger.error(f"AWS CLI not found at '{AWS_CLI_PATH}'. S3 copy failed for '{relative_file_path}'.")
        except Exception as e: monitor_logger.error(f"Exception during S3 copy for {relative_file_path}: {e}", exc_info=True)

    def _handle_s3_delete(self, relative_file_path):
        s3_client_for_verify = boto3.client('s3') # Cliente S3 apenas para verificação pós-delete
        s3_target_path_key = relative_file_path
        s3_full_uri = self._get_s3_path(relative_file_path)
        monitor_logger.info(f"Attempting to delete '{s3_full_uri}' from S3 via AWS CLI (Timeout: {AWS_CLI_TIMEOUT_S3_RM}s)...")
        cli_delete_reported_success = False; cli_rc = -1; cli_stderr = ""
        try:
            process = subprocess.run(
                [AWS_CLI_PATH, 's3', 'rm', s3_full_uri, '--only-show-errors'],
                capture_output=True, text=True, check=False, timeout=AWS_CLI_TIMEOUT_S3_RM
            )
            cli_rc = process.returncode; cli_stderr = process.stderr.strip()
            if cli_rc == 0:
                monitor_logger.info(f"AWS CLI 's3 rm' for '{relative_file_path}' OK (RC: 0).")
                transfer_logger.info(f"DELETED_S3_CLI_OK: {relative_file_path}"); cli_delete_reported_success = True
            else:
                monitor_logger.error(f"AWS CLI 's3 rm' FAILED for '{relative_file_path}'. RC: {cli_rc}. Stderr: {cli_stderr}")
                transfer_logger.info(f"DELETED_S3_CLI_FAILED: {relative_file_path} - RC={cli_rc} ERR={cli_stderr}")
        except subprocess.TimeoutExpired:
            monitor_logger.error(f"S3 rm TIMEOUT for '{relative_file_path}' after {AWS_CLI_TIMEOUT_S3_RM}s.")
            transfer_logger.info(f"S3_RM_TIMEOUT: {relative_file_path}"); return
        except FileNotFoundError: monitor_logger.error(f"AWS CLI not found. S3 delete for '{relative_file_path}' failed."); return
        except Exception as e: monitor_logger.error(f"Exception during AWS CLI 's3 rm' for {relative_file_path}: {e}", exc_info=True)

        monitor_logger.info(f"Verifying deletion of '{s3_target_path_key}' in S3 (Boto3 head_object)...")
        try:
            time.sleep(1) # Consistência eventual
            s3_client_for_verify.head_object(Bucket=S3_BUCKET, Key=s3_target_path_key)
            monitor_logger.error(f"S3 delete VERIFICATION FAILED for '{relative_file_path}'. Object still found. CLI RC: {cli_rc}.")
            if cli_stderr: monitor_logger.error(f"CLI Stderr: {cli_stderr}")
            transfer_logger.info(f"DELETED_S3_VERIFICATION_FAILED_STILL_EXISTS: {relative_file_path}")
        except s3_client_for_verify.exceptions.ClientError as e:
            if e.response['Error']['Code'] in ('404', 'NoSuchKey'):
                monitor_logger.info(f"S3 delete VERIFIED for '{relative_file_path}'. Not found. CLI RC: {cli_rc}.")
                transfer_logger.info(f"DELETED_S3_VERIFIED_NOT_FOUND: {relative_file_path}")
                self._add_to_cf_invalidation_batch(relative_file_path) # Invalidar SEMPRE após deleção
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
                    efs_deleted_by_script.remove(path); ignore_s3_deletion_for_moved_src = True
            if not ignore_s3_deletion_for_moved_src: self._handle_s3_delete(relative_src_path)
            else: transfer_logger.info(f"SKIPPED_S3_DELETE_MOVED_FROM_BY_SCRIPT_FLAG: {relative_src_path}")
            return

        current_path_to_check = dest_path if event_type == 'moved_to' else path
        if self._is_excluded(current_path_to_check) or \
           (os.path.exists(current_path_to_check) and os.path.isdir(current_path_to_check)): return
        relevant, relative_path = is_path_relevant(current_path_to_check, MONITOR_DIR_BASE, RELEVANT_PATTERNS)
        if not relevant or not relative_path: return

        # ===================================================================
        # == INÍCIO DA CORREÇÃO: VERIFICAR SE O ARQUIVO É UM PLACEHOLDER   ==
        # ===================================================================
        # Esta verificação é crucial para eventos de modificação, que são disparados
        # quando o próprio script substitui o arquivo original pelo placeholder de 1 byte.
        if event_type == 'modified' and os.path.exists(current_path_to_check):
            try:
                # Otimização: checa o tamanho primeiro. Se não for 1 byte, não pode ser o placeholder.
                if os.path.getsize(current_path_to_check) == len(PLACEHOLDER_CONTENT.encode('utf-8')):
                    # Se o tamanho bate, verifica o conteúdo para ter 100% de certeza.
                    with open(current_path_to_check, 'r') as f_check:
                        content = f_check.read()
                    if content == PLACEHOLDER_CONTENT:
                        monitor_logger.info(f"Event: MODIFIED for placeholder file '{relative_path}'. Skipping S3 upload.")
                        return # PONTO CRÍTICO: Sai da função para não copiar o placeholder para o S3.
            except OSError:
                # O arquivo pode ter sido deletado entre as chamadas `exists` e `getsize`. Isso é normal.
                pass
        # ===================================================================
        # == FIM DA CORREÇÃO                                               ==
        # ===================================================================

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
            transfer_logger.info(f"INITIAL_SYNC_SUCCESS: {description}"); return True
        elif process.returncode == 2:
            monitor_logger.warning(f"Initial Sync for {description} RC 2. Stderr: {process.stderr.strip()}")
            transfer_logger.info(f"INITIAL_SYNC_WARNING_RC2: {description} - ERR: {process.stderr.strip()}"); return True
        else:
            monitor_logger.error(f"Initial Sync for {description} FAILED. RC: {process.returncode}. Stderr: {process.stderr.strip()}")
            transfer_logger.info(f"INITIAL_SYNC_FAILED: {description} - RC={process.returncode} ERR={process.stderr.strip()}"); return False
    except subprocess.TimeoutExpired:
        monitor_logger.error(f"Initial Sync TIMEOUT for '{description}' after {AWS_CLI_TIMEOUT_S3_CP}s.")
        transfer_logger.info(f"INITIAL_SYNC_TIMEOUT: {description}"); return False
    except FileNotFoundError: monitor_logger.error(f"AWS CLI not found. Initial Sync for {description} failed."); return False
    except Exception as e: monitor_logger.error(f"Exception during Initial Sync for {description}: {e}", exc_info=True); return False

def perform_initial_sync(watcher_instance):
    monitor_logger.info("--- Starting Initial S3 Sync ---")
    if not S3_BUCKET or not os.path.isdir(MONITOR_DIR_BASE):
        monitor_logger.error("S3_BUCKET or MONITOR_DIR_BASE not configured/valid. Skipping initial sync."); return

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
               '--exclude', '*.php', '--exclude', '*/index.php', '--exclude', 'wp-content/cache/*',
               '--exclude', 'wp-content/backups/*', '--exclude', '*/.DS_Store', '--exclude', '*/Thumbs.db',
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
            monitor_logger.info(f"Scanning '{scan_root}' for files to replace with placeholders...")
            for root, _, files in os.walk(scan_root):
                for filename in files:
                    local_path = os.path.join(root, filename)
                    if watcher_instance._is_excluded(local_path): continue
                    is_relevant, rel_path = is_path_relevant(local_path, MONITOR_DIR_BASE, RELEVANT_PATTERNS)
                    if is_relevant and os.path.splitext(local_path)[1].lower() in PLACEHOLDER_TARGET_EXTENSIONS_EFS:
                        try:
                            if os.path.exists(local_path) and \
                               os.path.getsize(local_path) == len(PLACEHOLDER_CONTENT.encode('utf-8')):
                                with open(local_path, 'r') as f_check: content = f_check.read()
                                if content == PLACEHOLDER_CONTENT: monitor_logger.debug(f"'{local_path}' is already placeholder."); continue
                        except OSError: pass
                        if os.path.exists(local_path):
                            monitor_logger.info(f"Initial Sync: Replacing '{local_path}' with placeholder.")
                            _replace_efs_file_with_placeholder(local_path, rel_path)
                        else: monitor_logger.warning(f"Initial Sync: File '{local_path}' gone before placeholder replacement.")
        monitor_logger.info("--- EFS placeholder replacement Attempted ---")
    if CLOUDFRONT_DISTRIBUTION_ID: # A invalidação de /* é para o sync inicial, não para uploads individuais
        monitor_logger.info("Initial sync complete. Enqueuing full CloudFront invalidation (/*).")
        watcher_instance._trigger_batched_cloudfront_invalidation(paths_override=['/*'], reference_suffix_override="initial-sync-full")

# --- Main Execution Block ---
if __name__ == "__main__":
    script_version_tag = "v2.5.0-PlaceholderFix" # Atualizar a tag da versão
    monitor_logger.info(f"Python Watchdog Monitor ({script_version_tag}) starting for '{MONITOR_DIR_BASE}'.")
    monitor_logger.info(f"S3 Bucket: {S3_BUCKET}")
    monitor_logger.info(f"Relevant Patterns (raw): {RELEVANT_PATTERNS_STR}")
    monitor_logger.info(f"Relevant Watcher Patterns (parsed): {RELEVANT_PATTERNS}")
    monitor_logger.info(f"Replace EFS files with placeholders: {DELETE_FROM_EFS_AFTER_SYNC} (Hardcoded)")
    monitor_logger.info(f"EFS file extensions for placeholders: {PLACEHOLDER_TARGET_EXTENSIONS_EFS}")
    monitor_logger.info(f"Perform initial sync: {PERFORM_INITIAL_SYNC} (Hardcoded)")
    monitor_logger.info(f"CloudFront Distribution ID: {CLOUDFRONT_DISTRIBUTION_ID if CLOUDFRONT_DISTRIBUTION_ID else 'Not Set'}")
    monitor_logger.info(f"CF Invalidation Batch: MaxSize={CF_INVALIDATION_BATCH_MAX_SIZE}, Timeout={CF_INVALIDATION_BATCH_TIMEOUT_SECONDS}s")
    monitor_logger.info(f"AWS CLI Timeouts: S3 CP={AWS_CLI_TIMEOUT_S3_CP}s, S3 RM={AWS_CLI_TIMEOUT_S3_RM}s")
    monitor_logger.info(f"Boto3 CF Timeouts: Connect={BOTO3_CLOUDFRONT_CONNECT_TIMEOUT}s, Read={BOTO3_CLOUDFRONT_READ_TIMEOUT}s")
    monitor_logger.info(f"Boto3 S3 (head_object) Timeouts: Connect={BOTO3_S3_CONNECT_TIMEOUT}s, Read={BOTO3_S3_READ_TIMEOUT}s")
    monitor_logger.info(f"Max Invalidation Workers: {MAX_INVALIDATION_WORKERS}")


    if not S3_BUCKET: monitor_logger.critical("S3_BUCKET not set. Exiting."); exit(1)
    if not os.path.isdir(MONITOR_DIR_BASE): monitor_logger.critical(f"Monitor dir '{MONITOR_DIR_BASE}' not found. Exiting."); exit(1)
    resolved_cli_path = shutil.which(AWS_CLI_PATH)
    if not resolved_cli_path: monitor_logger.critical(f"AWS CLI ('{AWS_CLI_PATH}') not found. Exiting."); exit(1)
    AWS_CLI_PATH = resolved_cli_path
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
            thread.daemon = True; thread.start(); invalidation_worker_threads.append(thread)
        monitor_logger.info(f"Started {len(invalidation_worker_threads)} CloudFront invalidation worker(s).")
    else: monitor_logger.warning("CLOUDFRONT_DISTRIBUTION_ID not set, workers NOT started.")

    event_handler = Watcher()
    if PERFORM_INITIAL_SYNC: perform_initial_sync(event_handler)
    if not RELEVANT_PATTERNS_STR or not RELEVANT_PATTERNS:
         monitor_logger.warning(f"RELEVANT_PATTERNS empty. Watchdog may only process initial sync/deletions.")

    observer = Observer()
    observer.schedule(event_handler, MONITOR_DIR_BASE, recursive=True)
    observer.start()
    monitor_logger.info("Observer started. Monitoring for file changes...")
    try:
        while observer.is_alive(): observer.join(1)
    except KeyboardInterrupt: monitor_logger.info("KeyboardInterrupt. Shutting down...")
    except Exception as e_main_loop: monitor_logger.critical(f"CRITICAL error in main observer loop: {e_main_loop}", exc_info=True)
    finally:
        monitor_logger.info("Initiating shutdown sequence...")
        if observer.is_alive(): monitor_logger.info("Stopping observer..."); observer.stop()
        monitor_logger.info("Waiting for observer to join..."); observer.join()
        monitor_logger.info("Observer stopped and joined.")
        if CLOUDFRONT_DISTRIBUTION_ID and invalidation_worker_threads:
            monitor_logger.info("Signaling CF invalidation workers to terminate...")
            for _ in invalidation_worker_threads:
                try: invalidation_queue.put((None, None), block=False, timeout=1)
                except queue.Full: monitor_logger.warning("Queue full sending termination sentinels."); break
            monitor_logger.info(f"Waiting for {invalidation_queue.qsize()} items in invalidation queue (max ~{MAX_INVALIDATION_WORKERS * (BOTO3_CLOUDFRONT_READ_TIMEOUT + 10)}s)...")
            all_processed = False; timeout_join = MAX_INVALIDATION_WORKERS * (BOTO3_CLOUDFRONT_READ_TIMEOUT + 10); start_join_time = time.time()
            while not invalidation_queue.empty():
                if time.time() - start_join_time > timeout_join:
                    monitor_logger.warning(f"Timeout waiting for invalidation queue. {invalidation_queue.qsize()} items may remain.")
                    break
                time.sleep(0.5)
            else: all_processed = True
            if all_processed: monitor_logger.info("Invalidation queue processed (empty).")
        with cf_invalidation_lock:
            if cf_invalidation_timer and cf_invalidation_timer.is_alive():
                monitor_logger.info("Cancelling main CF invalidation timer."); cf_invalidation_timer.cancel()
        monitor_logger.info("Script shutdown complete.")
