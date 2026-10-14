# Override these values here or in the environment before starting a collector.
export PING_INTERVAL="${PING_INTERVAL:-1}"
export SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"
export OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Library/Logs/mac-wifi-troubleshooter}"
export RETENTION_DAYS="${RETENTION_DAYS:-7}"
export MAX_LOG_BYTES="${MAX_LOG_BYTES:-10485760}"
# Optional stable asset identifier; defaults to the Mac's hostname.
export MACHINE_ID="${MACHINE_ID:-}"
