#!/bin/bash
# forge-ingest: multi-source fan-out → merged prepped.jsonl.
# Reads $RUN_DIR/config.yaml (or path arg), dispatches each source kind to
# the matching handler, merges into one canonical JSONL.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../../.."
CREDS_FILE="${FORGE_CREDS_FILE:-/tmp/forge-creds.env}"

RUN_ID=""
CONFIG_PATH=""
DRY_RUN=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN="--dry-run" ;;
    -*)        echo "unknown flag: $arg" >&2; exit 64 ;;
    *)
      if [[ -z "$RUN_ID" ]]; then RUN_ID="$arg"
      elif [[ -z "$CONFIG_PATH" ]]; then CONFIG_PATH="$arg"
      else echo "extra positional arg: $arg" >&2; exit 64
      fi ;;
  esac
done

if [[ -z "$RUN_ID" ]]; then
  echo "usage: $0 <run-id> [path/to/config.yaml] [--dry-run]" >&2
  exit 64
fi

RUN_DIR="${REPO_ROOT}/slm-forge/.runs/${RUN_ID}"
mkdir -p "$RUN_DIR"

# Default config: $RUN_DIR/config.yaml — if absent, look at the analyze
# target_dir which may itself BE the config.yaml (for multi-source-config runs)
if [[ -z "$CONFIG_PATH" ]]; then
  if [[ -f "$RUN_DIR/config.yaml" ]]; then
    CONFIG_PATH="$RUN_DIR/config.yaml"
  elif [[ -f "$RUN_DIR/analysis.json" ]]; then
    target_dir=$(jq -r '.target_dir' "$RUN_DIR/analysis.json")
    if [[ -f "$target_dir" && "$target_dir" =~ \.ya?ml$ ]]; then
      CONFIG_PATH="$target_dir"
    fi
  fi
fi

if [[ -z "$CONFIG_PATH" || ! -f "$CONFIG_PATH" ]]; then
  echo "forge-ingest: config not found (looked at \$RUN_DIR/config.yaml + analyze target)" >&2
  exit 1
fi

# Load creds for env: refs in DB sources etc.
[[ -f "$CREDS_FILE" ]] && set -a && source "$CREDS_FILE" && set +a

# Ensure venv + deps
VENV="${FORGE_VENV:-/tmp/forge-venv}"
if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV" >&2
fi
"$VENV/bin/pip" install --quiet pyyaml 2>&1 | tail -1 >&2 || true

# If any hf_dataset source, install datasets
if grep -q "kind: *hf_dataset" "$CONFIG_PATH" 2>/dev/null; then
  "$VENV/bin/pip" install --quiet datasets 2>&1 | tail -1 >&2 || true
fi

FANOUT="${SCRIPT_DIR}/fanout.py"
if [[ -n "$DRY_RUN" ]]; then
  echo "[forge-ingest] DRY-RUN — planning only, no downloads or writes" >&2
fi
echo "[forge-ingest] dispatching $CONFIG_PATH..." >&2
"$VENV/bin/python" "$FANOUT" "$RUN_ID" "$CONFIG_PATH" $DRY_RUN || {
  echo "[forge-ingest] fanout failed" >&2
  exit 1
}
