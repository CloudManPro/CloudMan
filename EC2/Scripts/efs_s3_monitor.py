#!/usr/bin/env python3
import time
import logging
import subprocess
import os
import fnmatch
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
import shutil
import boto3
import threading
import json

try:
    import pymysql
except ImportError:
    print("CRITICAL: pymysql library not found. Please install it: pip install pymysql")
    exit(1)
try:
    from phpserialize import loads as php_loads
except ImportError:
    print("CRITICAL: phpserialize library not found. Please install it: pip install phpserialize")
    exit(1)

# --- Configuration (Read from environment variables) ---
# EFS Monitor
MONITOR_DIR_BASE = os.environ.get('WP_MONITOR_DIR_BASE', '/var/www/html')
S3_BUCKET = os.environ.get('WP_S3_BUCKET')
RELEVANT_PATTERNS_STR = os.environ.get('WP_RELEVANT_PATTERNS', '')
LOG_FILE_MONITOR = os.environ.get(
    'WP_PY_MONITOR_LOG_FILE', '/var/log/wp_efs_s3_py_monitor_default.log')
S3_TRANSFER_LOG = os.environ.get(
    'WP_PY_S3_TRANSFER_LOG', '/var/log/wp_s3_py_transferred_default.log')
SYNC_DEBOUNCE_SECONDS = int(os.environ.get('WP_SYNC_DEBOUNCE_SECONDS', '5'))
AWS_CLI_PATH = os.environ.get('WP_AWS_CLI_PATH', 'aws')
DELETE_FROM_EFS_AFTER_SYNC = os.environ.get('WP_DELETE_FROM_EFS_AFTER_SYNC', 'false').lower() == 'true'
PERFORM_INITIAL_SYNC = os.environ.get('WP_PERFORM_INITIAL_SYNC', 'true').lower() == 'true'
DELETABLE_IMAGE_EXTENSIONS_FROM_EFS = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.ico', '.svg']

# CloudFront
CLOUDFRONT_DISTRIBUTION_ID = os.environ.get('AWS_CLOUDFRONT_DISTRIBUTION_TARGET_ID_0')
CF_INVALIDATION_BATCH_MAX_SIZE = int(os.environ.get('CF_INVALIDATION_BATCH_MAX_SIZE', 15))
CF_INVALIDATION_BATCH_TIMEOUT_SECONDS = int(os.environ.get('CF_INVALIDATION_BATCH_TIMEOUT_SECONDS', 20))

# RDS Deletion Queue
RDS_DELETION_QUEUE_ENABLED = os.environ.get('WP_RDS_DELETION_QUEUE_ENABLED', 'true').lower() == 'true'
# <<< REMOVIDO: RDS_SECRET_ARN_OR_NAME >>>

# Credenciais RDS serão lidas diretamente das variáveis de ambiente passadas pelo Bash/Systemd
RDS_HOST = os.environ.get('WP_RDS_HOST')
RDS_USER = os.environ.get('WP_RDS_USER')
RDS_PASSWORD = os.environ.get('WP_RDS_PASSWORD') # << IMPORTANTE: Esta agora será usada
RDS_DB_NAME = os.environ.get('WP_RDS_DB_NAME')
RDS_PORT = int(os.environ.get('WP_RDS_PORT', '3306'))
RDS_ENGINE = os.environ.get('WP_RDS_ENGINE', 'mysql') # Adicionado para informação, embora não usado diretamente na conexão pymysql

RDS_WP_POSTS_TABLE_NAME = os.environ.get('WP_RDS_POSTS_TABLE_NAME', 'wp_posts')
RDS_WP_POSTMETA_TABLE_NAME = os.environ.get('WP_RDS_POSTMETA_TABLE_NAME', 'wp_postmeta')
S3_DELETION_QUEUE_TABLE_NAME = os.environ.get('WP_S3_DELETION_QUEUE_TABLE_NAME', 'wp_s3_deletion_queue')
S3_DELETION_QUEUE_POLL_INTERVAL_SECONDS = int(os.environ.get('WP_S3_DELETION_QUEUE_POLL_INTERVAL_SECONDS', '900'))
S3_DELETION_QUEUE_BATCH_SIZE = int(os.environ.get('WP_S3_DELETION_QUEUE_BATCH_SIZE', '10'))
S3_BASE_PATH_FOR_DELETION_QUEUE = os.environ.get('WP_S3_BASE_PATH_FOR_DELETION_QUEUE', 'wp-content/uploads/')

# --- Globals ---
RELEVANT_PATTERNS = [p.strip() for p in RELEVANT_PATTERNS_STR.split(';') if p.strip()]
last_sync_file_map = {}
cf_invalidation_paths_batch = []
cf_invalidation_timer = None
cf_invalidation_lock = threading.Lock()
efs_deleted_by_script = set()
efs_deletion_lock = threading.Lock()
s3_deletion_queue_stop_event = threading.Event()
s3_client_boto_for_deletion_queue = None
# <<< REMOVIDO: rds_credentials_global >>> (usaremos as variáveis de config diretamente)

# --- Logger Setup ---
# (Função setup_logger permanece a mesma)
def setup_logger(name, log_file, level=logging.INFO, formatter_str='%(asctime)s - %(levelname)s - %(name)s - %(message)s'):
    log_dir = os.path.dirname(log_file)
    if log_dir and not os.path.exists(log_dir):
        try:
            os.makedirs(log_dir, exist_ok=True)
        except Exception as e:
            print(f"Error creating log directory {log_dir}: {e}")
            log_file = os.path.join("/tmp", os.path.basename(log_file))
            print(f"Falling back to log file: {log_file}")
    try:
        with open(log_file, 'a'): os.utime(log_file, None)
    except Exception as e:
        print(f"Error touching log file {log_file}: {e}")

    logger = logging.getLogger(name)
    logger.setLevel(level)
    if not logger.hasHandlers():
        handler = logging.FileHandler(log_file, mode='a')
        handler.setFormatter(logging.Formatter(formatter_str))
        logger.addHandler(handler)
        console_handler = logging.StreamHandler()
        console_handler.setLevel(logging.INFO)
        console_handler.setFormatter(logging.Formatter(formatter_str))
        logger.addHandler(console_handler)
    return logger

monitor_logger = setup_logger('PY_MONITOR', LOG_FILE_MONITOR)
transfer_logger = setup_logger('PY_S3_TRANSFER', S3_TRANSFER_LOG, formatter_str='%(asctime)s - %(message)s')
rds_queue_logger = setup_logger('PY_RDS_QUEUE', LOG_FILE_MONITOR)


# <<< REMOVIDA: Função get_rds_credentials_from_secrets_manager >>>

# --- RDS Deletion Queue Functions ---
def get_rds_connection():
    # Verifica se as variáveis de ambiente essenciais foram carregadas
    if not all([RDS_HOST, RDS_USER, RDS_PASSWORD, RDS_DB_NAME]):
        rds_queue_logger.error("RDS connection details (HOST, USER, PASSWORD, DBNAME) from ENV are not fully configured.")
        return None
    try:
        conn = pymysql.connect(
            host=RDS_HOST,
            user=RDS_USER,
            password=RDS_PASSWORD,
            database=RDS_DB_NAME,
            port=RDS_PORT,
            cursorclass=pymysql.cursors.DictCursor,
            connect_timeout=10,
            charset='utf8mb4'
        )
        rds_queue_logger.debug(f"Successfully connected to RDS: {RDS_HOST}/{RDS_DB_NAME}")
        return conn
    except pymysql.Error as e:
        rds_queue_logger.error(f"Error connecting to RDS using ENV credentials: {e}")
        return None

# Funções ensure_deletion_queue_table_exists, ensure_s3_deletion_trigger_exists,
# get_pending_s3_deletions, update_queue_item_status, parse_s3_keys_from_data,
# delete_s3_objects_from_queue_item, process_s3_deletion_queue
# PERMANECEM IGUAIS à versão v2.5.0-SecretsManager-Full, pois elas já
# utilizam a conexão `conn` que será estabelecida pela `get_rds_connection` acima.

# (Cole aqui as funções que permanecem iguais da versão anterior:
# ensure_deletion_queue_table_exists, ensure_s3_deletion_trigger_exists,
# get_pending_s3_deletions, update_queue_item_status, parse_s3_keys_from_data,
# delete_s3_objects_from_queue_item, process_s3_deletion_queue)
# ... (para economizar espaço, vou omiti-las, mas elas devem estar aqui) ...
# --- Copiando as funções inalteradas ---
def ensure_deletion_queue_table_exists(conn):
    if not conn: return False
    try:
        with conn.cursor() as cursor:
            sql = f"""
            CREATE TABLE IF NOT EXISTS `{S3_DELETION_QUEUE_TABLE_NAME}` (
                `id` BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
                `post_id_deleted` BIGINT UNSIGNED NULL,
                `attachment_metadata_snapshot` LONGTEXT NULL,
                `s3_keys_to_delete_json` LONGTEXT NULL,
                `status` ENUM('PENDING', 'PROCESSING', 'DONE', 'ERROR', 'NO_KEYS') NOT NULL DEFAULT 'PENDING',
                `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                `processed_at` TIMESTAMP NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
                `error_message` TEXT NULL,
                INDEX `idx_status_created_at` (`status`, `created_at`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
            """
            cursor.execute(sql)
        conn.commit()
        rds_queue_logger.info(f"Table '{S3_DELETION_QUEUE_TABLE_NAME}' ensured to exist.")
        return True
    except pymysql.Error as e:
        rds_queue_logger.error(f"Error ensuring table '{S3_DELETION_QUEUE_TABLE_NAME}' exists: {e}")
        if conn.open: conn.rollback()
        return False

def ensure_s3_deletion_trigger_exists(conn):
    if not conn: return False
    trigger_name = 'after_attachment_delete_enqueue_s3_v1' # Mantendo o mesmo nome de trigger
    rds_queue_logger.info(f"Ensuring RDS trigger '{trigger_name}' exists...")
    try:
        with conn.cursor() as cursor:
            cursor.execute("SELECT COUNT(*) as count FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = DATABASE() AND TRIGGER_NAME = %s;", (trigger_name,))
            if cursor.fetchone()['count'] > 0:
                rds_queue_logger.info(f"Trigger '{trigger_name}' already exists.")
                return True

            rds_queue_logger.info(f"Trigger '{trigger_name}' not found. Attempting to create...")
            sql_create_trigger = f"""
            CREATE TRIGGER `{trigger_name}`
            AFTER DELETE ON `{RDS_WP_POSTS_TABLE_NAME}`
            FOR EACH ROW
            BEGIN
                DECLARE v_attachment_meta LONGTEXT;
                IF OLD.post_type = 'attachment' THEN
                    SELECT meta_value INTO v_attachment_meta
                    FROM `{RDS_WP_POSTMETA_TABLE_NAME}`
                    WHERE post_id = OLD.ID AND meta_key = '_wp_attachment_metadata'
                    LIMIT 1;
                    INSERT INTO `{S3_DELETION_QUEUE_TABLE_NAME}`
                        (post_id_deleted, attachment_metadata_snapshot, status)
                    VALUES
                        (OLD.ID, v_attachment_meta, 'PENDING');
                END IF;
            END
            """
            cursor.execute(sql_create_trigger)
            conn.commit()
            rds_queue_logger.info(f"Trigger '{trigger_name}' created successfully.")
            return True
    except pymysql.Error as e:
        rds_queue_logger.error(f"MySQL Error for trigger '{trigger_name}': {e.args[0]} - {e.args[1] if len(e.args) > 1 else ''}")
        if conn.open: conn.rollback()
        return False
    except Exception as e_gen:
        rds_queue_logger.error(f"Unexpected error for trigger '{trigger_name}': {e_gen}", exc_info=True)
        if conn.open: conn.rollback()
        return False

def get_pending_s3_deletions(conn, batch_size):
    if not conn: return []
    try:
        with conn.cursor() as cursor:
            sql = f"SELECT id, post_id_deleted, attachment_metadata_snapshot, s3_keys_to_delete_json FROM `{S3_DELETION_QUEUE_TABLE_NAME}` WHERE status = 'PENDING' ORDER BY created_at ASC LIMIT %s;"
            cursor.execute(sql, (batch_size,))
            items = cursor.fetchall()
            return items if items else []
    except pymysql.Error as e:
        rds_queue_logger.error(f"Error fetching pending S3 deletions: {e}")
        return []

def update_queue_item_status(conn, item_id, status, error_msg=None):
    if not conn: return False
    try:
        with conn.cursor() as cursor:
            sql = f"UPDATE `{S3_DELETION_QUEUE_TABLE_NAME}` SET status = %s, error_message = %s WHERE id = %s;"
            cursor.execute(sql, (status, error_msg, item_id))
        conn.commit()
        rds_queue_logger.debug(f"Updated item {item_id} to status {status}.")
        return True
    except pymysql.Error as e:
        rds_queue_logger.error(f"Error updating status for item {item_id} to {status}: {e}")
        if conn.open: conn.rollback()
        return False

def parse_s3_keys_from_data(metadata_snapshot_str, s3_keys_json_str, post_id):
    s3_keys = []
    if s3_keys_json_str:
        try:
            keys = json.loads(s3_keys_json_str)
            if isinstance(keys, list) and all(isinstance(k, str) for k in keys):
                s3_keys.extend(keys)
                rds_queue_logger.info(f"Using pre-calculated S3 keys from JSON for post_id {post_id}: {len(keys)} keys.")
                return list(set(s3_keys))
        except json.JSONDecodeError as e:
            rds_queue_logger.warning(f"Failed to parse s3_keys_to_delete_json for post_id {post_id}: {e}. Will try metadata_snapshot.")

    if not metadata_snapshot_str:
        rds_queue_logger.warning(f"No metadata_snapshot_str or valid s3_keys_json for post_id {post_id}.")
        return []
    try:
        metadata = php_loads(metadata_snapshot_str.encode('utf-8'), decode_strings=True)
        if not isinstance(metadata, dict):
            rds_queue_logger.error(f"Parsed metadata for post_id {post_id} is not a dictionary.")
            return []
        main_file_relative_path = metadata.get('file')
        if main_file_relative_path:
            full_s3_key_main = S3_BASE_PATH_FOR_DELETION_QUEUE.rstrip('/') + '/' + main_file_relative_path.lstrip('/')
            s3_keys.append(full_s3_key_main)
            main_file_dir_relative = os.path.dirname(main_file_relative_path)
            sizes = metadata.get('sizes')
            if isinstance(sizes, dict):
                for size_info in sizes.values():
                    if isinstance(size_info, dict) and 'file' in size_info:
                        thumb_filename = size_info['file']
                        if main_file_dir_relative and main_file_dir_relative != '.':
                            thumb_relative_path_to_uploads = os.path.join(main_file_dir_relative, thumb_filename)
                        else:
                            thumb_relative_path_to_uploads = thumb_filename
                        full_s3_key_thumb = S3_BASE_PATH_FOR_DELETION_QUEUE.rstrip('/') + '/' + thumb_relative_path_to_uploads.lstrip('/')
                        s3_keys.append(full_s3_key_thumb)
        else:
            rds_queue_logger.warning(f"Metadata for post_id {post_id} does not contain 'file' key.")
    except Exception as e:
        rds_queue_logger.error(f"Error parsing PHP serialized metadata for post_id {post_id}: {e}", exc_info=True)
    return list(set(s3_keys))

def delete_s3_objects_from_queue_item(s3_client, bucket_name, s3_keys):
    if not s3_keys:
        rds_queue_logger.info("No S3 keys provided for deletion.")
        return True, None
    objects_to_delete_s3_format = [{'Key': key.lstrip('/')} for key in s3_keys]
    rds_queue_logger.info(f"Attempting to delete {len(objects_to_delete_s3_format)} objects from S3 bucket '{bucket_name}'.")
    rds_queue_logger.debug(f"Objects to delete: {objects_to_delete_s3_format}")
    try:
        response = s3_client.delete_objects(Bucket=bucket_name, Delete={'Objects': objects_to_delete_s3_format, 'Quiet': False})
        deleted_successfully_count = len(response.get('Deleted', []))
        for d_obj in response.get('Deleted', []):
            transfer_logger.info(f"DELETED_S3_FROM_QUEUE: s3://{bucket_name}/{d_obj['Key']}")
        if 'Errors' in response and response['Errors']:
            error_messages = [f"S3 Key: {e['Key']}, Code: {e['Code']}, Message: {e['Message']}" for e in response['Errors']]
            for e in response['Errors']: transfer_logger.info(f"DELETED_S3_FROM_QUEUE_ERROR: s3://{bucket_name}/{e['Key']} - {e['Message']}")
            rds_queue_logger.error(f"S3 delete_objects reported errors: {'; '.join(error_messages)}")
            return deleted_successfully_count > 0, "; ".join(error_messages) # True se algum foi deletado, mesmo com erros
        rds_queue_logger.info(f"Successfully submitted deletion for {deleted_successfully_count} S3 objects.")
        return True, None
    except Exception as e:
        rds_queue_logger.error(f"Exception during S3 delete_objects: {e}", exc_info=True)
        return False, str(e)

def process_s3_deletion_queue(conn, s3_client):
    if not conn or not s3_client:
        rds_queue_logger.error("RDS connection or S3 client not available for queue processing.")
        return
    pending_items = get_pending_s3_deletions(conn, S3_DELETION_QUEUE_BATCH_SIZE)
    if not pending_items:
        rds_queue_logger.debug("No pending items in S3 deletion queue.")
        return
    rds_queue_logger.info(f"Found {len(pending_items)} items in S3 deletion queue to process.")
    for item in pending_items:
        item_id = item['id']; post_id = item.get('post_id_deleted', 'N/A')
        metadata_snapshot = item.get('attachment_metadata_snapshot'); s3_keys_json = item.get('s3_keys_to_delete_json')
        rds_queue_logger.info(f"Processing queue item ID: {item_id}, Post ID: {post_id}")
        update_queue_item_status(conn, item_id, 'PROCESSING')
        s3_keys = parse_s3_keys_from_data(metadata_snapshot, s3_keys_json, post_id)
        if not s3_keys:
            rds_queue_logger.warning(f"No S3 keys for item ID {item_id}. Marking as NO_KEYS.")
            update_queue_item_status(conn, item_id, 'NO_KEYS', "Could not determine S3 keys.")
            continue
        success, error_message = delete_s3_objects_from_queue_item(s3_client, S3_BUCKET, s3_keys)
        if success:
            final_status = 'DONE'
            if error_message: final_status = 'ERROR' # Se houve erros, mesmo que parciais, marca como erro para revisão
            update_queue_item_status(conn, item_id, final_status, error_message)
            if CLOUDFRONT_DISTRIBUTION_ID: # Só invalida se a deleção S3 (mesmo parcial com erros) foi tentada
                for cf_path_key_only in s3_keys:
                    watcher_event_handler._add_to_cf_invalidation_batch(cf_path_key_only.lstrip('/'))
        else: # Falha total na chamada delete_objects
            update_queue_item_status(conn, item_id, 'ERROR', error_message)
# --- Fim das funções inalteradas ---


def s3_deletion_queue_worker_thread_func():
    global s3_client_boto_for_deletion_queue
    rds_queue_logger.info("S3 Deletion Queue Worker thread started.")
    rds_conn = None

    # Verifica se as credenciais RDS foram carregadas do ambiente
    if not all([RDS_HOST, RDS_USER, RDS_PASSWORD, RDS_DB_NAME]):
        rds_queue_logger.critical("Essential RDS credentials (HOST, USER, PASSWORD, DBNAME) not found in ENV. RDS queue worker will not run.")
        return # Impede a thread de continuar se credenciais básicas estiverem faltando

    try:
        s3_client_boto_for_deletion_queue = boto3.client('s3')
        rds_queue_logger.info("Boto3 S3 client initialized for Deletion Queue Worker.")
    except Exception as e:
        rds_queue_logger.critical(f"Failed to initialize Boto3 S3 client for Deletion Queue Worker: {e}. Thread exiting.", exc_info=True)
        return

    initial_setup_done = False

    while not s3_deletion_queue_stop_event.is_set():
        try:
            if not rds_conn or rds_conn.closed:
                rds_queue_logger.info("RDS connection closed or not established. Attempting to (re)connect.")
                if rds_conn and not rds_conn.closed:
                    try: rds_conn.close()
                    except: pass
                rds_conn = get_rds_connection() # Usa as credenciais globais/de ambiente
                if rds_conn:
                    if not initial_setup_done:
                        if ensure_deletion_queue_table_exists(rds_conn):
                            if ensure_s3_deletion_trigger_exists(rds_conn):
                                initial_setup_done = True
                            else:
                                rds_queue_logger.error("Failed to ensure S3 deletion trigger. Processing might be impaired.")
                        else:
                            rds_queue_logger.error("Failed to ensure deletion queue table. Trigger/Processing will be skipped.")
                else:
                    rds_queue_logger.error("Failed to connect to RDS. Will retry later.")
                    s3_deletion_queue_stop_event.wait(60) # Espera antes de tentar reconectar
                    continue
            
            if rds_conn: # Só prossegue se a conexão estiver estabelecida
                try:
                    if not rds_conn.ping(reconnect=False): # Verifica se a conexão está viva
                        rds_queue_logger.warning("RDS ping failed. Will attempt to reconnect in the next cycle.")
                        try: rds_conn.close()
                        except: pass
                        rds_conn = None; initial_setup_done = False # Força reconexão e re-setup
                        continue
                except (pymysql.Error, AttributeError) as pe: # Captura erro se a conexão já estiver morta
                    rds_queue_logger.warning(f"RDS ping error: {pe}. Will attempt to reconnect in the next cycle.")
                    try: rds_conn.close()
                    except: pass
                    rds_conn = None; initial_setup_done = False
                    continue

                if initial_setup_done:
                    rds_queue_logger.info(f"S3 Deletion Queue Worker: Polling queue.")
                    process_s3_deletion_queue(rds_conn, s3_client_boto_for_deletion_queue)
                else:
                    # Tenta o setup novamente se não foi bem sucedido antes e a conexão está OK
                    rds_queue_logger.warning("Initial RDS setup (table/trigger) not complete. Attempting setup again.")
                    if ensure_deletion_queue_table_exists(rds_conn):
                        if ensure_s3_deletion_trigger_exists(rds_conn):
                            initial_setup_done = True
                        else:
                            rds_queue_logger.error("Retried: Failed to ensure S3 deletion trigger.")
                    else:
                        rds_queue_logger.error("Retried: Failed to ensure deletion queue table.")
                    # Não processa a fila neste ciclo se o setup ainda não estiver OK

        except Exception as e:
            rds_queue_logger.error(f"Unhandled error in S3 Deletion Queue Worker loop: {e}", exc_info=True)
            if rds_conn and rds_conn.open:
                try: rds_conn.rollback()
                except Exception as rb_e: rds_queue_logger.error(f"Rollback error: {rb_e}")

        s3_deletion_queue_stop_event.wait(S3_DELETION_QUEUE_POLL_INTERVAL_SECONDS)

    if rds_conn and not rds_conn.closed:
        try: rds_conn.close()
        except pymysql.Error as e: rds_queue_logger.error(f"Error closing RDS connection: {e}")
    rds_queue_logger.info("S3 Deletion Queue Worker thread finished.")


# --- Helper Functions (EFS Monitor - Existing) ---
# (Função is_path_relevant permanece a mesma)
def is_path_relevant(path_to_check, base_dir, patterns):
    if not path_to_check.startswith(base_dir + os.path.sep): return False, None
    relative_file_path = os.path.relpath(path_to_check, base_dir)
    return any(fnmatch.fnmatch(relative_file_path, pattern) for pattern in patterns), relative_file_path

# --- FileSystem Event Handler Class (EFS Monitor - Existing) ---
# (Classe Watcher e suas sub-funções permanecem as mesmas da v2.5.0)
# ... (Cole aqui a classe Watcher completa da versão anterior) ...
# --- Copiando a classe Watcher ---
class Watcher(FileSystemEventHandler):
    def __init__(self):
        super().__init__()

    def _is_excluded(self, filepath):
        filename = os.path.basename(filepath)
        if filename.startswith('.') or filename.endswith(('.swp', '.swx', '~', '.part', '.crdownload', '.tmp')): return True
        if any(excluded_dir in filepath for excluded_dir in ['/cache/', '/.git/', '/node_modules/', '/uploads/sites/']):
            if '/uploads/sites/' in filepath: monitor_logger.debug(f"Excluding Multisite sub-site upload path: {filepath}")
            return True
        return False

    def _get_s3_path(self, relative_file_path): return f"s3://{S3_BUCKET}/{relative_file_path}"

    def _trigger_batched_cloudfront_invalidation(self):
        global cf_invalidation_paths_batch, cf_invalidation_timer
        with cf_invalidation_lock:
            if not cf_invalidation_paths_batch:
                if cf_invalidation_timer: cf_invalidation_timer.cancel(); cf_invalidation_timer = None
                return
            if not CLOUDFRONT_DISTRIBUTION_ID:
                cf_invalidation_paths_batch = []; 
                if cf_invalidation_timer: cf_invalidation_timer.cancel(); cf_invalidation_timer = None
                monitor_logger.warning("CLOUDFRONT_DISTRIBUTION_ID not set. Skipping CF invalidation.")
                return
            paths_to_invalidate_now = ["/" + p for p in cf_invalidation_paths_batch]
            current_batch_to_log = list(cf_invalidation_paths_batch)
            cf_invalidation_paths_batch = []
            if cf_invalidation_timer: cf_invalidation_timer.cancel(); cf_invalidation_timer = None
        monitor_logger.info(f"Triggering batched CF invalidation for {len(paths_to_invalidate_now)} paths on {CLOUDFRONT_DISTRIBUTION_ID}: {paths_to_invalidate_now}")
        try:
            boto3.client('cloudfront').create_invalidation(
                DistributionId=CLOUDFRONT_DISTRIBUTION_ID,
                InvalidationBatch={
                    'Paths': {'Quantity': len(paths_to_invalidate_now), 'Items': paths_to_invalidate_now},
                    'CallerReference': f"s3-efs-sync-batch-{int(time.time())}-{len(paths_to_invalidate_now)}"
                })
            monitor_logger.info(f"Batched CF invalidation request created for {len(paths_to_invalidate_now)} paths.")
            transfer_logger.info(f"INVALIDATED_CF_BATCH: {len(paths_to_invalidate_now)} paths on {CLOUDFRONT_DISTRIBUTION_ID} - Paths: {', '.join(current_batch_to_log)}")
        except Exception as e:
            monitor_logger.error(f"Failed to create batched CF invalidation for {current_batch_to_log}: {e}", exc_info=True)
            transfer_logger.info(f"INVALIDATION_CF_BATCH_FAILED: {len(paths_to_invalidate_now)} paths - {str(e)}")

    def _add_to_cf_invalidation_batch(self, object_key_to_invalidate):
        global cf_invalidation_paths_batch, cf_invalidation_timer
        if not CLOUDFRONT_DISTRIBUTION_ID: return
        with cf_invalidation_lock:
            if object_key_to_invalidate not in cf_invalidation_paths_batch:
                cf_invalidation_paths_batch.append(object_key_to_invalidate)
                monitor_logger.info(f"Added '{object_key_to_invalidate}' to CF invalidation batch. Size: {len(cf_invalidation_paths_batch)}")
            if cf_invalidation_timer: cf_invalidation_timer.cancel()
            if len(cf_invalidation_paths_batch) >= CF_INVALIDATION_BATCH_MAX_SIZE:
                self._trigger_batched_cloudfront_invalidation()
            elif cf_invalidation_paths_batch:
                cf_invalidation_timer = threading.Timer(CF_INVALIDATION_BATCH_TIMEOUT_SECONDS, self._trigger_batched_cloudfront_invalidation)
                cf_invalidation_timer.daemon = True; cf_invalidation_timer.start()

    def _handle_s3_upload(self, local_path, relative_file_path, is_initial_sync=False):
        global efs_deleted_by_script
        effective_delete_from_efs = DELETE_FROM_EFS_AFTER_SYNC and not is_initial_sync
        current_time = time.time()
        if not is_initial_sync and local_path in last_sync_file_map and (current_time - last_sync_file_map[local_path] < SYNC_DEBOUNCE_SECONDS):
            monitor_logger.info(f"Debounce for '{local_path}'. Skipped upload."); return
        s3_full_uri = self._get_s3_path(relative_file_path)
        monitor_logger.info(f"Copying '{local_path}' to '{s3_full_uri}'...")
        try:
            process = subprocess.run([AWS_CLI_PATH, 's3', 'cp', local_path, s3_full_uri, '--acl', 'private', '--only-show-errors'], capture_output=True, text=True, check=False)
            if process.returncode == 0:
                monitor_logger.info(f"S3 copy OK for '{relative_file_path}'.")
                transfer_logger.info(f"TRANSFERRED: {relative_file_path} to {s3_full_uri}")
                last_sync_file_map[local_path] = current_time
                if not is_initial_sync: self._add_to_cf_invalidation_batch(relative_file_path)
                if effective_delete_from_efs and os.path.splitext(local_path)[1].lower() in DELETABLE_IMAGE_EXTENSIONS_FROM_EFS:
                    try:
                        with efs_deletion_lock: efs_deleted_by_script.add(local_path)
                        os.remove(local_path)
                        monitor_logger.info(f"Deleted IMAGE '{local_path}' from EFS."); transfer_logger.info(f"DELETED_EFS_IMAGE: {relative_file_path}")
                    except OSError as e:
                        monitor_logger.error(f"Failed to delete IMAGE '{local_path}' from EFS: {e}")
                        with efs_deletion_lock:
                            if local_path in efs_deleted_by_script: efs_deleted_by_script.remove(local_path)
            else: monitor_logger.error(f"S3 copy FAILED for '{relative_file_path}'. RC: {process.returncode}. Stderr: {process.stderr.strip()}")
        except FileNotFoundError: monitor_logger.error(f"AWS CLI not found at '{AWS_CLI_PATH}'. S3 copy failed for '{relative_file_path}'.")
        except Exception as e: monitor_logger.error(f"Exception during S3 copy for {relative_file_path}: {e}", exc_info=True)

    def _handle_s3_delete(self, relative_file_path):
        s3_target_path_key = relative_file_path; s3_full_uri = self._get_s3_path(relative_file_path)
        monitor_logger.info(f"Attempting to delete '{s3_full_uri}' from S3 (EFS event)...")
        cli_rc = -1; cli_stderr = ""
        try:
            process = subprocess.run([AWS_CLI_PATH, 's3', 'rm', s3_full_uri], capture_output=True, text=True, check=False)
            cli_rc = process.returncode; cli_stderr = process.stderr.strip()
            if cli_rc == 0: transfer_logger.info(f"DELETED_S3_EFS_EVENT_CLI_OK: {relative_file_path}")
            else: transfer_logger.info(f"DELETED_S3_EFS_EVENT_CLI_FAILED: {relative_file_path} - RC={cli_rc} ERR={cli_stderr}"); monitor_logger.error(f"AWS CLI 's3 rm' FAILED for '{relative_file_path}'. RC: {cli_rc}. Stderr: {cli_stderr}")
        except FileNotFoundError: monitor_logger.error(f"AWS CLI not found at '{AWS_CLI_PATH}'. S3 delete failed."); return
        except Exception as e: monitor_logger.error(f"Exception during AWS CLI 's3 rm' for {relative_file_path}: {e}", exc_info=True)

        monitor_logger.info(f"Verifying S3 deletion of '{s3_target_path_key}' (Boto3 head_object)...")
        try:
            time.sleep(1); boto3.client('s3').head_object(Bucket=S3_BUCKET, Key=s3_target_path_key)
            monitor_logger.error(f"S3 delete VERIFICATION FAILED for '{relative_file_path}'. Object still found. CLI RC: {cli_rc}. CLI Stderr: {cli_stderr}")
            transfer_logger.info(f"DELETED_S3_EFS_EVENT_VERIFICATION_FAILED_STILL_EXISTS: {relative_file_path}")
        except boto3.client('s3').exceptions.ClientError as e:
            if e.response['Error']['Code'] in ['404', 'NoSuchKey']:
                monitor_logger.info(f"S3 delete VERIFIED for '{relative_file_path}'. CLI RC: {cli_rc}."); transfer_logger.info(f"DELETED_S3_EFS_EVENT_VERIFIED_NOT_FOUND: {relative_file_path}")
                self._add_to_cf_invalidation_batch(relative_file_path)
            else:
                monitor_logger.error(f"Error during S3 delete VERIFICATION for '{relative_file_path}': {e.response['Error']['Code']}. CLI RC: {cli_rc}. CLI Stderr: {cli_stderr}")
                transfer_logger.info(f"DELETED_S3_EFS_EVENT_VERIFICATION_ERROR_HEAD_OBJECT: {relative_file_path} - {e.response['Error']['Code']}")
        except Exception as ve: monitor_logger.error(f"Unexpected error during S3 delete VERIFICATION for '{s3_target_path_key}': {ve}", exc_info=True); transfer_logger.info(f"DELETED_S3_EFS_EVENT_VERIFICATION_UNEXPECTED_ERROR: {relative_file_path}")

    def process_event_for_sync(self, event_type, path, dest_path=None):
        global efs_deleted_by_script
        if event_type == 'moved_from':
            if self._is_excluded(path) or (os.path.exists(path) and os.path.isdir(path)): return
            relevant_src, relative_src_path = is_path_relevant(path, MONITOR_DIR_BASE, RELEVANT_PATTERNS)
            if not relevant_src or not relative_src_path: return
            monitor_logger.info(f"Event: MOVED_FROM for '{relative_src_path}'")
            ignore_s3_del = False
            with efs_deletion_lock:
                if path in efs_deleted_by_script: efs_deleted_by_script.remove(path); ignore_s3_del = True
            if not ignore_s3_del: self._handle_s3_delete(relative_src_path)
            else: transfer_logger.info(f"SKIPPED_S3_DELETE_MOVED_FROM_BY_SCRIPT_FLAG: {relative_src_path}")
            return

        current_path_to_check = dest_path if event_type == 'moved_to' else path
        if self._is_excluded(current_path_to_check) or (os.path.exists(current_path_to_check) and os.path.isdir(current_path_to_check)): return
        relevant, relative_path = is_path_relevant(current_path_to_check, MONITOR_DIR_BASE, RELEVANT_PATTERNS)
        if not relevant or not relative_path: return
        monitor_logger.info(f"Event: {event_type.upper()} for '{relative_path}'")

        if event_type in ['created', 'modified', 'moved_to']: self._handle_s3_upload(current_path_to_check, relative_path)
        elif event_type == 'deleted':
            ignore_s3_del = False
            with efs_deletion_lock:
                if path in efs_deleted_by_script: efs_deleted_by_script.remove(path); ignore_s3_del = True
            if not ignore_s3_del: self._handle_s3_delete(relative_path)
            else: transfer_logger.info(f"SKIPPED_S3_DELETE_BY_SCRIPT_FLAG: {relative_path}")

    def on_created(self, event):
        if not event.is_directory: self.process_event_for_sync('created', event.src_path)
    def on_modified(self, event):
        if not event.is_directory: self.process_event_for_sync('modified', event.src_path)
    def on_deleted(self, event):
        if not event.is_directory: self.process_event_for_sync('deleted', event.src_path)
    def on_moved(self, event):
        if not event.is_directory:
            self.process_event_for_sync('moved_from', event.src_path)
            self.process_event_for_sync('moved_to', event.src_path, dest_path=event.dest_path)
# --- Fim da classe Watcher ---


# --- Initial Sync Function (EFS Monitor - Existing) ---
# (Função run_s3_sync_command e perform_initial_sync permanecem as mesmas da v2.5.0)
# ... (Cole aqui as funções de initial sync) ...
# --- Copiando funções de initial sync ---
def run_s3_sync_command(command_parts, description):
    monitor_logger.info(f"Attempting Initial Sync for {description} with command: {' '.join(command_parts)}")
    try:
        process = subprocess.run(command_parts, capture_output=True, text=True, check=False)
        if process.returncode == 0:
            monitor_logger.info(f"Initial Sync for {description} OK."); transfer_logger.info(f"INITIAL_SYNC_SUCCESS: {description}")
            return True
        elif process.returncode == 2: 
            monitor_logger.warning(f"Initial Sync for {description} RC 2. Stderr: {process.stderr.strip()}"); transfer_logger.info(f"INITIAL_SYNC_WARNING_RC2: {description} - ERR: {process.stderr.strip()}")
            return True
        else:
            monitor_logger.error(f"Initial Sync for {description} FAILED. RC: {process.returncode}. Stderr: {process.stderr.strip()}"); transfer_logger.info(f"INITIAL_SYNC_FAILED: {description} - RC={process.returncode} ERR={process.stderr.strip()}")
            return False
    except FileNotFoundError: monitor_logger.error(f"AWS CLI not found at '{AWS_CLI_PATH}'. Initial Sync failed."); return False
    except Exception as e: monitor_logger.error(f"Exception during Initial Sync for {description}: {e}", exc_info=True); return False

def perform_initial_sync():
    monitor_logger.info("--- Starting Initial S3 Sync ---")
    if not S3_BUCKET or not os.path.isdir(MONITOR_DIR_BASE):
        monitor_logger.error("S3_BUCKET not set or MONITOR_DIR_BASE not found. Skipping initial sync."); return
    general_includes = ['*.css', '*.js', '*.jpg', '*.jpeg', '*.png', '*.gif', '*.svg', '*.webp', '*.ico', '*.woff', '*.woff2', '*.ttf', '*.eot', '*.otf', '*.mp4', '*.mov', '*.webm', '*.avi', '*.wmv', '*.mkv', '*.flv', '*.mp3', '*.wav', '*.ogg', '*.aac', '*.wma', '*.flac', '*.pdf', '*.doc', '*.docx', '*.xls', '*.xlsx', '*.ppt', '*.pptx', '*.zip', '*.txt']
    includes_cmd = [item for sublist in [['--include', i] for i in general_includes] for item in sublist]
    
    wp_content_path = os.path.join(MONITOR_DIR_BASE, "wp-content")
    if os.path.isdir(wp_content_path):
        cmd = [AWS_CLI_PATH, 's3', 'sync', wp_content_path, f"s3://{S3_BUCKET}/wp-content/", '--exclude', '*.php', '--exclude', '*/index.php', '--exclude', '*/cache/*', '--exclude', '*/backups/*', '--exclude', '*/.DS_Store', '--exclude', '*/Thumbs.db'] + includes_cmd + ['--exact-timestamps', '--acl', 'private']
        run_s3_sync_command(cmd, "wp-content")
    
    wp_includes_path = os.path.join(MONITOR_DIR_BASE, "wp-includes")
    if os.path.isdir(wp_includes_path):
        wp_inc_assets = ['*.css', '*.js', '*.jpg', '*.jpeg', '*.png', '*.gif', '*.svg', '*.webp', '*.ico']
        inc_wp_inc_cmd = [item for sublist in [['--include', i] for i in wp_inc_assets] for item in sublist]
        cmd = [AWS_CLI_PATH, 's3', 'sync', wp_includes_path, f"s3://{S3_BUCKET}/wp-includes/", '--exclude', '*'] + inc_wp_inc_cmd + ['--exact-timestamps', '--acl', 'private']
        run_s3_sync_command(cmd, "wp-includes (assets only)")
    monitor_logger.info("--- Initial S3 Sync Attempted ---")
# --- Fim das funções de initial sync ---

# --- Main Execution Block ---
watcher_event_handler = Watcher() # Instância global para ser acessada pela thread RDS para CF invalidation

if __name__ == "__main__":
    script_version_tag = "v2.5.1-EnvCreds" # <<< NOVA VERSÃO >>>
    monitor_logger.info(f"Python EFS/S3 Monitor & RDS Queue Processor ({script_version_tag}) starting...")
    monitor_logger.info(f"S3 Bucket: {S3_BUCKET}")
    monitor_logger.info(f"EFS Monitor Dir: {MONITOR_DIR_BASE}")
    monitor_logger.info(f"EFS Relevant Patterns: {RELEVANT_PATTERNS}")
    monitor_logger.info(f"EFS Delete After Sync: {DELETE_FROM_EFS_AFTER_SYNC}")
    monitor_logger.info(f"EFS Perform Initial Sync: {PERFORM_INITIAL_SYNC}")
    monitor_logger.info(f"CF Distribution ID: {CLOUDFRONT_DISTRIBUTION_ID or 'Not Set'}")

    monitor_logger.info(f"RDS Deletion Queue Enabled: {RDS_DELETION_QUEUE_ENABLED}")
    if RDS_DELETION_QUEUE_ENABLED:
        monitor_logger.info(f"RDS Host (ENV): {RDS_HOST or 'Not Set'}")
        monitor_logger.info(f"RDS User (ENV): {RDS_USER or 'Not Set'}")
        monitor_logger.info(f"RDS DB Name (ENV): {RDS_DB_NAME or 'Not Set'}")
        monitor_logger.info(f"RDS Port (ENV): {RDS_PORT or 'Not Set'}")
        # Não logar RDS_PASSWORD
        monitor_logger.info(f"RDS Engine (ENV): {RDS_ENGINE or 'Not Set'}")
        monitor_logger.info(f"RDS Posts Table Name: {RDS_WP_POSTS_TABLE_NAME}")
        monitor_logger.info(f"RDS Postmeta Table Name: {RDS_WP_POSTMETA_TABLE_NAME}")
        monitor_logger.info(f"RDS Queue Table Name: {S3_DELETION_QUEUE_TABLE_NAME}")
        monitor_logger.info(f"RDS Queue Poll Interval: {S3_DELETION_QUEUE_POLL_INTERVAL_SECONDS}s")
        monitor_logger.info(f"S3 Base Path for Queue Deletion: '{S3_BASE_PATH_FOR_DELETION_QUEUE}'")

    if not S3_BUCKET:
        monitor_logger.critical("S3_BUCKET not set. Exiting."); exit(1)

    aws_cli_actual_path = shutil.which(AWS_CLI_PATH)
    if not aws_cli_actual_path:
        monitor_logger.critical(f"AWS CLI not found at '{AWS_CLI_PATH}'. Exiting."); exit(1)
    AWS_CLI_PATH = aws_cli_actual_path; monitor_logger.info(f"Using AWS CLI at: {AWS_CLI_PATH}")

    try:
        boto3.client('s3'); monitor_logger.info("Boto3 S3 client test OK.")
    except Exception as e: # Captura exceções mais amplas, incluindo NoCredentialsError
        monitor_logger.critical(f"Boto3 S3 client init failed. Check AWS credentials/config (IAM Role, etc.): {e}", exc_info=True); exit(1)

    if PERFORM_INITIAL_SYNC:
        perform_initial_sync()

    observer = None
    if RELEVANT_PATTERNS:
        if not os.path.isdir(MONITOR_DIR_BASE):
            monitor_logger.error(f"EFS Monitor: Dir '{MONITOR_DIR_BASE}' not found. Observer not started.")
        else:
            observer = Observer()
            observer.schedule(watcher_event_handler, MONITOR_DIR_BASE, recursive=True)
            observer.start(); monitor_logger.info("EFS Watchdog Observer started.")
    else:
        monitor_logger.info("No RELEVANT_PATTERNS for EFS. Watchdog Observer not started.")

    rds_deletion_thread = None
    if RDS_DELETION_QUEUE_ENABLED:
        # A verificação de credenciais agora é feita dentro da thread worker
        rds_deletion_thread = threading.Thread(target=s3_deletion_queue_worker_thread_func, daemon=True)
        rds_deletion_thread.start(); monitor_logger.info("RDS S3 Deletion Queue Worker thread initiated.")
    else:
        monitor_logger.info("RDS Deletion Queue is disabled.")

    try:
        while True: # Main loop to keep script alive
            if observer and not observer.is_alive():
                monitor_logger.error("EFS Observer thread died.")
                if not rds_deletion_thread or not rds_deletion_thread.is_alive(): break
            if rds_deletion_thread and not rds_deletion_thread.is_alive() and RDS_DELETION_QUEUE_ENABLED:
                # Esta condição pode ser atingida se a thread worker sair devido à falta de credenciais
                monitor_logger.error("RDS Deletion Queue thread died or did not start properly (check logs for credential errors).")
                if not observer or not observer.is_alive(): break
            
            # Condição de saída se nenhuma thread ativa estiver configurada ou rodando
            all_threads_done_or_disabled = True
            if RELEVANT_PATTERNS and observer and observer.is_alive():
                all_threads_done_or_disabled = False
            if RDS_DELETION_QUEUE_ENABLED and rds_deletion_thread and rds_deletion_thread.is_alive():
                all_threads_done_or_disabled = False
            
            if all_threads_done_or_disabled:
                 monitor_logger.info("No active monitoring threads (EFS or RDS queue) or they are disabled. Script will exit.")
                 break
            
            time.sleep(5)
    except KeyboardInterrupt:
        monitor_logger.info("Keyboard interrupt. Stopping...")
        if cf_invalidation_timer and cf_invalidation_timer.is_alive(): # Tratamento do timer do CF
            with cf_invalidation_lock:
                if cf_invalidation_timer and cf_invalidation_timer.is_alive(): cf_invalidation_timer.cancel()
            watcher_event_handler._trigger_batched_cloudfront_invalidation() # Tenta invalidar o que estiver no batch
    except Exception as e:
        monitor_logger.critical(f"Critical error in main loop: {e}", exc_info=True)
    finally:
        monitor_logger.info("Shutting down...")
        if rds_deletion_thread and rds_deletion_thread.is_alive():
            s3_deletion_queue_stop_event.set()
            rds_deletion_thread.join(timeout=S3_DELETION_QUEUE_POLL_INTERVAL_SECONDS + 15) # Aumenta um pouco o timeout
            if rds_deletion_thread.is_alive(): monitor_logger.warning("RDS Worker thread timed out on stop.")
            else: monitor_logger.info("RDS Worker thread stopped.")
        if observer and observer.is_alive():
            observer.stop(); observer.join(timeout=10)
            if observer.is_alive(): monitor_logger.warning("EFS Observer timed out on stop.")
            else: monitor_logger.info("EFS Observer stopped.")
        with cf_invalidation_lock: # Limpeza final do timer do CF
            if cf_invalidation_timer and cf_invalidation_timer.is_alive(): cf_invalidation_timer.cancel()
        monitor_logger.info("Script finished.")
