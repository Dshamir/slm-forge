#!/bin/bash
# forge-ingest-db: database extraction → canonical JSONL.
# Reads a YAML config and emits slm-forge/.runs/<run-id>/ingested-db.jsonl.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../../.."
CREDS_FILE="${FORGE_CREDS_FILE:-/tmp/forge-creds.env}"

RUN_ID="${1:-}"
CONFIG_PATH="${2:-}"

if [[ -z "$RUN_ID" ]]; then
  echo "usage: $0 <run-id> [path/to/db-sources.yaml]" >&2
  exit 64
fi

RUN_DIR="${REPO_ROOT}/slm-forge/.runs/${RUN_ID}"
mkdir -p "$RUN_DIR"

# Default config path: inside the run dir
if [[ -z "$CONFIG_PATH" ]]; then
  CONFIG_PATH="$RUN_DIR/db-sources.yaml"
fi
if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "forge-ingest-db: config not found: $CONFIG_PATH" >&2
  exit 1
fi

# Load credentials so env:VAR refs resolve
[[ -f "$CREDS_FILE" ]] && set -a && source "$CREDS_FILE" && set +a

# Ensure venv + deps
VENV="${FORGE_VENV:-/tmp/forge-venv}"
if [[ ! -x "$VENV/bin/python" ]]; then
  echo "[forge-ingest-db] creating venv at $VENV..." >&2
  python3 -m venv "$VENV" >&2
fi
"$VENV/bin/pip" install --quiet pyyaml 2>&1 | tail -1 >&2 || true

# Determine which DB drivers to install based on config kinds
KINDS=$("$VENV/bin/python" -c "
import sys, yaml
with open('$CONFIG_PATH') as f:
    cfg = yaml.safe_load(f)
kinds = set(s.get('kind','') for s in cfg.get('sources', []))
print(' '.join(sorted(kinds)))
" 2>/dev/null || echo "")

for k in $KINDS; do
  case "$k" in
    postgres) "$VENV/bin/pip" install --quiet psycopg2-binary 2>&1 | tail -1 >&2 || true ;;
    mysql)    "$VENV/bin/pip" install --quiet pymysql 2>&1 | tail -1 >&2 || true ;;
    mongodb)  "$VENV/bin/pip" install --quiet pymongo 2>&1 | tail -1 >&2 || true ;;
    sqlite)   : ;;  # stdlib, no install needed
  esac
done

INGEST_PY="${SCRIPT_DIR}/ingest.py"

echo "[forge-ingest-db] running ingest (kinds: ${KINDS:-none})..." >&2
"$VENV/bin/python" "$INGEST_PY" "$RUN_ID" "$CONFIG_PATH" || {
  echo "[forge-ingest-db] ingest.py failed" >&2
  exit 1
}
