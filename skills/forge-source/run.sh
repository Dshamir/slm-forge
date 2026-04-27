#!/usr/bin/env bash
# skills/forge-source/run.sh — SOURCE phase implementation.
#
# Reads:
#   - manifest.spec.corpus_ref
# Writes:
#   - s3://FORGE_BUCKET/forge/<id>/data/raw/*
#   - manifest.artifacts.raw_corpus_s3
#   - manifest.artifacts.raw_corpus_manifest (file list, sizes, checksums)
#   - Advances phase to CURATE.
#
# Corpus-ref dispatch:
#   local:/abs/path      — copy file or directory to S3
#   s3://bucket/prefix   — server-side copy (same region)
#   hf://dataset-id      — HF dataset snapshot → S3
#   https://... / http://— curl the URL, upload to S3
#
# M2 smoke: local mode only is required. s3/hf/http are stubbed with
# clear "not yet implemented" errors.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../../lib"

# shellcheck source=../../lib/manifest.sh
source "${LIB}/manifest.sh"
# shellcheck source=../../lib/s3.sh
source "${LIB}/s3.sh"

FORGE_ID="${1:-}"
if [[ -z "$FORGE_ID" ]]; then
  echo "forge-source: forge-id required" >&2
  exit 64
fi

MANIFEST=$(manifest_load "$FORGE_ID" 2>/dev/null)
CORPUS_REF=$(echo "$MANIFEST" | jq -r '.spec.corpus_ref // ""')

if [[ -z "$CORPUS_REF" ]]; then
  echo "forge-source: spec.corpus_ref is empty" >&2
  exit 1
fi

# ---- Size guard (per S3_LAYOUT.md cap) ---------------------------------

PER_FORGE_CAP_GB="${FORGE_PER_FORGE_CAP_GB:-500}"

check_size_cap_local() {
  local local_path="$1"
  local bytes
  bytes=$(du -sb "$local_path" 2>/dev/null | awk '{print $1}')
  local cap_bytes=$(( PER_FORGE_CAP_GB * 1024 * 1024 * 1024 ))
  if (( bytes > cap_bytes )); then
    echo "forge-source: corpus size (${bytes}B) exceeds per-forge cap (${PER_FORGE_CAP_GB}GB)" >&2
    return 1
  fi
}

# ---- Dispatch by scheme ------------------------------------------------

source_local() {
  local local_path="$1"
  if [[ ! -e "$local_path" ]]; then
    echo "forge-source: local path does not exist: $local_path" >&2
    return 1
  fi
  check_size_cap_local "$local_path"

  # Record a raw-corpus shard manifest before uploading
  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' RETURN

  if [[ -d "$local_path" ]]; then
    # Directory: sync whole tree
    export FORGE_PHASE="SOURCE"
    s3_sync_to "$FORGE_ID" "$local_path" "data/raw"
    # Build shard list from local files
    (cd "$local_path" && find . -type f) > "$tmpdir/shards.list"
  else
    # Single file: put + record
    export FORGE_PHASE="SOURCE"
    local base_name
    base_name=$(basename "$local_path")
    s3_put "$FORGE_ID" "$local_path" "data/raw/$base_name"
    echo "./$base_name" > "$tmpdir/shards.list"
  fi

  # Build shard manifest
  local shards_json
  shards_json=$(jq -R -s \
    --arg local_path "$local_path" \
    '
      split("\n")
      | map(select(length > 0))
      | map({path: ., size_bytes: null})
    ' "$tmpdir/shards.list")

  # Write raw-corpus-manifest to S3
  local manifest_path="$tmpdir/raw-corpus-manifest.json"
  jq -n \
    --arg source_type "local" \
    --arg source_ref "$local_path" \
    --arg fetched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson shards "$shards_json" \
    '{
      source_type: $source_type,
      source_ref: $source_ref,
      fetched_at: $fetched_at,
      shards: $shards
    }' > "$manifest_path"
  s3_put "$FORGE_ID" "$manifest_path" "data/raw/_raw-corpus-manifest.json"
}

source_s3() {
  echo "forge-source: s3:// corpus-ref not yet implemented (M2+ hardening)" >&2
  return 78
}

source_hf() {
  echo "forge-source: hf:// corpus-ref not yet implemented (M2+ hardening)" >&2
  return 78
}

source_url() {
  echo "forge-source: URL corpus-ref not yet implemented (M2+ hardening)" >&2
  return 78
}

# ---- Idempotency check -------------------------------------------------

EXISTING=$(echo "$MANIFEST" | jq -r '.artifacts.raw_corpus_s3 // ""')
if [[ -n "$EXISTING" && "$EXISTING" != "null" ]]; then
  echo "forge-source: raw_corpus_s3 already populated; skipping" >&2
  jq -n --arg fid "$FORGE_ID" '{
    status: "completed",
    next_phase: "CURATE",
    skill: "forge-source",
    forge_id: $fid,
    idempotent: true
  }'
  exit 0
fi

# ---- Dispatch ----------------------------------------------------------

case "$CORPUS_REF" in
  local:*)
    source_local "${CORPUS_REF#local:}"
    ;;
  s3://*)
    source_s3 "$CORPUS_REF"
    ;;
  hf://*)
    source_hf "${CORPUS_REF#hf://}"
    ;;
  http://*|https://*)
    source_url "$CORPUS_REF"
    ;;
  *)
    echo "forge-source: unrecognized corpus_ref scheme: '$CORPUS_REF'" >&2
    exit 1
    ;;
esac

RAW_S3_URI=$(s3_uri_for "$FORGE_ID" "data/raw/")

manifest_patch "$FORGE_ID" "
  .artifacts.raw_corpus_s3 = \"${RAW_S3_URI}\"
  | .phase = \"CURATE\"
  | .phase_history[-1].exited_at = (now | todate)
  | .phase_history[-1].status = \"completed\"
  | .phase_history += [{
      phase: \"CURATE\",
      entered_at: (now | todate),
      exited_at: null,
      status: \"in-progress\"
    }]
" >/dev/null

jq -n \
  --arg fid "$FORGE_ID" \
  --arg uri "$RAW_S3_URI" \
  '{
    status: "completed",
    next_phase: "CURATE",
    skill: "forge-source",
    forge_id: $fid,
    raw_corpus_s3: $uri
  }'
