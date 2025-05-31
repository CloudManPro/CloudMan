import time
import logging
import subprocess
import os
import fnmatch
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

# Configuration (Read from environment variables passed by systemd service)
MONITOR_DIR_BASE = os.environ.get('WP_MONITOR_DIR_BASE', '/var/www/html')
S3_BUCKET = os.environ.get('WP_S3_BUCKET')
RELEVANT_PATTERNS_STR = os.environ.get('WP_RELEVANT_PATTERNS', '')
LOG_FILE_MONITOR = os.environ.get(
    'WP_PY_MONITOR_LOG_FILE', '/var/log/wp_efs_s3_py_monitor.log')  # Defaulted from Bash
S3_TRANSFER_LOG = os.environ.get(
    'WP_PY_S3_TRANSFER_LOG', '/var/log/wp_s3_py_transferred.log')  # Defaulted from Bash
SYNC_DEBOUNCE_SECONDS = int(os.environ.get('WP_SYNC_DEBOUNCE_SECONDS', '5'))
AWS_CLI_PATH = os.environ.get('WP_AWS_CLI_PATH', 'aws')

RELEVANT_PATTERNS = [p.strip()
                     for p in RELEVANT_PATTERNS_STR.split(';') if p.strip()]
last_sync_file_map = {}


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
    # Evitar adicionar handlers duplicados se o script for reiniciado no mesmo processo de alguma forma
    if not logger.hasHandlers():
        handler = logging.FileHandler(log_file, mode='a')
        handler.setFormatter(logging.Formatter(formatter_str))
        logger.addHandler(handler)
    return logger


monitor_logger = setup_logger('PY_MONITOR', LOG_FILE_MONITOR)
transfer_logger = setup_logger(
    'PY_S3_TRANSFER', S3_TRANSFER_LOG, formatter_str='%(asctime)s - %(message)s')


class Watcher(FileSystemEventHandler):
    def _is_excluded(self, filepath):
        filename = os.path.basename(filepath)
        if filename.endswith(('.swp', '.swx', '~', '.part', '.crdownload')):
            return True
        if '/cache/' in filepath or '/.git/' in filepath or '/node_modules/' in filepath or '/uploads/sites/' in filepath:
            return True  # Multisite uploads sub-sites
        return False

    def process_event(self, event_type, path):
        if self._is_excluded(path):
            # monitor_logger.debug(f"Ignoring excluded file event: {event_type} for {path}")
            return

        monitor_logger.info(f"Event: {event_type.upper()} at {path}")

        try:
            if not path.startswith(MONITOR_DIR_BASE + os.path.sep):
                monitor_logger.info(
                    f"File '{path}' outside base '{MONITOR_DIR_BASE}'. Ignored.")
                return

            relative_file_path = os.path.relpath(path, MONITOR_DIR_BASE)
            file_is_relevant = any(fnmatch.fnmatch(
                relative_file_path, pattern) for pattern in RELEVANT_PATTERNS)

            if not file_is_relevant:
                monitor_logger.info(
                    f"File '{relative_file_path}' not relevant. Ignored.")
                return

            monitor_logger.info(
                f"Relevant file '{relative_file_path}' changed. Preparing for S3.")

            current_time = time.time()
            if path in last_sync_file_map and \
               (current_time - last_sync_file_map[path] < SYNC_DEBOUNCE_SECONDS):
                monitor_logger.info(f"Debounce for '{path}'. Skipped.")
                return

            s3_dest_path = f"s3://{S3_BUCKET}/{relative_file_path}"
            monitor_logger.info(f"Copying '{path}' to '{s3_dest_path}'...")

            process = subprocess.run(
                [AWS_CLI_PATH, 's3', 'cp', path, s3_dest_path,
                    '--acl', 'private', '--only-show-errors'],
                capture_output=True, text=True, check=False
            )

            if process.returncode == 0:
                monitor_logger.info(f"S3 copy OK for '{relative_file_path}'.")
                transfer_logger.info(f"TRANSFERRED: {relative_file_path}")
                last_sync_file_map[path] = current_time
            else:
                monitor_logger.error(
                    f"S3 copy FAILED for '{relative_file_path}'. RC: {process.returncode}. Stderr: {process.stderr.strip()}")

        except Exception as e:
            monitor_logger.error(
                f"Error processing event for {path}: {e}", exc_info=True)

    def on_created(self, event):
        if not event.is_directory:
            self.process_event(event.event_type, event.src_path)

    def on_modified(self, event):
        if not event.is_directory:
            self.process_event(event.event_type, event.src_path)

    def on_moved(self, event):  # Catches renames and moves
        if not event.is_directory:
            # For moves, the relevant path is the destination
            self.process_event(event.event_type, event.dest_path)


if __name__ == "__main__":
    monitor_logger.info(
        f"Python Watchdog Monitor (v2.3.1) starting for '{MONITOR_DIR_BASE}'.")
    monitor_logger.info(f"S3 Bucket: {S3_BUCKET}")
    monitor_logger.info(f"Relevant Patterns (raw): {RELEVANT_PATTERNS_STR}")
    monitor_logger.info(f"Relevant Patterns (parsed): {RELEVANT_PATTERNS}")

    if not S3_BUCKET or not RELEVANT_PATTERNS_STR:
        monitor_logger.critical(
            "S3_BUCKET or WP_RELEVANT_PATTERNS environment variables not set. Exiting.")
        exit(1)
    if not os.path.isdir(MONITOR_DIR_BASE):
        monitor_logger.critical(
            f"Monitor directory '{MONITOR_DIR_BASE}' does not exist. Exiting.")
        exit(1)

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
