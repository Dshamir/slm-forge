#!/usr/bin/env bash
# slm-forge/lib/s3.sh
#
# S3 helpers for the SLM-Forge skill tree. Concept ported from
# backend/src/services/burst/cas-store.ts (gzipped tarball + SSE-KMS +
# checksum + presign-with-unhoistableHeaders), simplified to the four
# operations the forge actually needs.
#
# Bucket: <YOUR_S3_BUCKET> (override via FORGE_BUCKET env)
# Encryption: SSE-KMS via alias/<YOUR_S3_BUCKET> (bucket policy enforces)
# Sub-prefix: forge/<forge-id>/  (and _forge-global/ for shared assets)
#
# Operations:
#   s3_put <forge-id> <local-path> <relative-key>   [extra-tags=k=v,...]
#   s3_get <forge-id> <relative-key> <local-path>
#   s3_sync_to <forge-id> <local-dir> <relative-prefix>
#   s3_sync_from <forge-id> <relative-prefix> <local-dir>
#   s3_ls <forge-id> [relative-prefix]
#   s3_check_bucket
#   s3_tag <forge-id> <relative-key> <k=v,...>
#   s3_uri_for <forge-id> <relative-key>     -> prints s3:// URI
#   s3_global_put / s3_global_get             -> _forge-global/ helpers
#
# Sub-skills source this file:
#   source "$(dirname "$0")/../lib/s3.sh"

set -euo pipefail

FORGE_BUCKET="${FORGE_BUCKET:-<YOUR_S3_BUCKET>}"
FORGE_REGION="${FORGE_REGION:-ca-central-1}"
FORGE_PREFIX="${FORGE_PREFIX:-forge}"
FORGE_GLOBAL_PREFIX="${FORGE_GLOBAL_PREFIX:-_forge-global}"
FORGE_KMS_ALIAS="${FORGE_KMS_ALIAS:-alias/<YOUR_S3_BUCKET>}"

# Use the same AWS shim as manifest.sh / compute_aws.sh for consistency.
_s3_aws() {
  local key_id="${FORGE_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
  local key_secret="${FORGE_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
  if [[ -z "$key_id" || -z "$key_secret" ]]; then
    echo "s3.sh: FORGE_AWS_ACCESS_KEY_ID + FORGE_AWS_SECRET_ACCESS_KEY required" >&2
    return 64
  fi
  if command -v aws >/dev/null 2>&1; then
    AWS_ACCESS_KEY_ID="$key_id" \
    AWS_SECRET_ACCESS_KEY="$key_secret" \
    AWS_DEFAULT_REGION="$FORGE_REGION" \
      aws "$@"
  else
    docker run --rm -i \
      -e AWS_ACCESS_KEY_ID="$key_id" \
      -e AWS_SECRET_ACCESS_KEY="$key_secret" \
      -e AWS_DEFAULT_REGION="$FORGE_REGION" \
      amazon/aws-cli:latest "$@"
  fi
}

# Same shim, but with a docker volume mount for file I/O (s3 cp / sync).
_s3_aws_mount() {
  local local_dir="$1"; shift
  local key_id="${FORGE_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
  local key_secret="${FORGE_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
  if command -v aws >/dev/null 2>&1; then
    AWS_ACCESS_KEY_ID="$key_id" \
    AWS_SECRET_ACCESS_KEY="$key_secret" \
    AWS_DEFAULT_REGION="$FORGE_REGION" \
      aws "$@"
  else
    docker run --rm --user "$(id -u):$(id -g)" \
      -e AWS_ACCESS_KEY_ID="$key_id" \
      -e AWS_SECRET_ACCESS_KEY="$key_secret" \
      -e AWS_DEFAULT_REGION="$FORGE_REGION" \
      -v "$(cd "$local_dir" && pwd):/work" \
      amazon/aws-cli:latest "$@"
  fi
}

# ---- URI helpers -------------------------------------------------------

_forge_key() {
  local forge_id="$1" relative="$2"
  echo "${FORGE_PREFIX}/${forge_id}/${relative}"
}

s3_uri_for() {
  local forge_id="$1" relative="$2"
  echo "s3://${FORGE_BUCKET}/$(_forge_key "$forge_id" "$relative")"
}

# ---- Tagging -----------------------------------------------------------

# Tags every uploaded object with: Project, forge-id, phase (if FORGE_PHASE set),
# plus any caller-supplied tags. Per S3_LAYOUT.md "Cost tracking" section.
_build_tag_set() {
  local forge_id="$1"
  local extra="${2:-}"
  local base="Project=slm-forge&forge-id=${forge_id}"
  if [[ -n "${FORGE_PHASE:-}" ]]; then
    base+="&phase=${FORGE_PHASE}"
  fi
  if [[ -n "$extra" ]]; then
    base+="&${extra}"
  fi
  echo "$base"
}

# ---- Put / Get individual objects -------------------------------------

# s3_put <forge-id> <local-file> <relative-key> [extra-tags]
s3_put() {
  local forge_id="$1" local_file="$2" relative="$3" extra_tags="${4:-}"
  local key tags abs_dir base_name
  key=$(_forge_key "$forge_id" "$relative")
  tags=$(_build_tag_set "$forge_id" "$extra_tags")

  if [[ ! -f "$local_file" ]]; then
    echo "s3_put: not a regular file: $local_file" >&2
    return 1
  fi

  abs_dir=$(cd "$(dirname "$local_file")" && pwd)
  base_name=$(basename "$local_file")

  if command -v aws >/dev/null 2>&1; then
    _s3_aws s3api put-object \
      --bucket "$FORGE_BUCKET" --key "$key" \
      --body "$local_file" --tagging "$tags" >/dev/null
  else
    docker run --rm --user "$(id -u):$(id -g)" \
      -e AWS_ACCESS_KEY_ID="${FORGE_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}" \
      -e AWS_SECRET_ACCESS_KEY="${FORGE_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}" \
      -e AWS_DEFAULT_REGION="$FORGE_REGION" \
      -v "$abs_dir:/work" \
      amazon/aws-cli:latest s3api put-object \
      --bucket "$FORGE_BUCKET" --key "$key" \
      --body "/work/$base_name" --tagging "$tags" >/dev/null
  fi
}

# s3_get <forge-id> <relative-key> <local-file>
s3_get() {
  local forge_id="$1" relative="$2" local_file="$3"
  local key abs_dir base_name
  key=$(_forge_key "$forge_id" "$relative")
  mkdir -p "$(dirname "$local_file")"
  abs_dir=$(cd "$(dirname "$local_file")" && pwd)
  base_name=$(basename "$local_file")

  if command -v aws >/dev/null 2>&1; then
    _s3_aws s3api get-object \
      --bucket "$FORGE_BUCKET" --key "$key" "$local_file" >/dev/null
  else
    docker run --rm --user "$(id -u):$(id -g)" \
      -e AWS_ACCESS_KEY_ID="${FORGE_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}" \
      -e AWS_SECRET_ACCESS_KEY="${FORGE_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}" \
      -e AWS_DEFAULT_REGION="$FORGE_REGION" \
      -v "$abs_dir:/work" \
      amazon/aws-cli:latest s3api get-object \
      --bucket "$FORGE_BUCKET" --key "$key" "/work/$base_name" >/dev/null
  fi
}

# ---- Bulk sync ---------------------------------------------------------

# s3_sync_to <forge-id> <local-dir> <relative-prefix>
s3_sync_to() {
  local forge_id="$1" local_dir="$2" relative="$3"
  local s3_uri
  s3_uri="s3://${FORGE_BUCKET}/$(_forge_key "$forge_id" "$relative")"
  if command -v aws >/dev/null 2>&1; then
    _s3_aws s3 sync "$local_dir" "$s3_uri" --no-progress
  else
    docker run --rm --user "$(id -u):$(id -g)" \
      -e AWS_ACCESS_KEY_ID="${FORGE_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}" \
      -e AWS_SECRET_ACCESS_KEY="${FORGE_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}" \
      -e AWS_DEFAULT_REGION="$FORGE_REGION" \
      -v "$(cd "$local_dir" && pwd):/work" \
      amazon/aws-cli:latest s3 sync /work "$s3_uri" --no-progress
  fi
}

# s3_sync_from <forge-id> <relative-prefix> <local-dir>
s3_sync_from() {
  local forge_id="$1" relative="$2" local_dir="$3"
  local s3_uri
  s3_uri="s3://${FORGE_BUCKET}/$(_forge_key "$forge_id" "$relative")"
  mkdir -p "$local_dir"
  if command -v aws >/dev/null 2>&1; then
    _s3_aws s3 sync "$s3_uri" "$local_dir" --no-progress
  else
    docker run --rm --user "$(id -u):$(id -g)" \
      -e AWS_ACCESS_KEY_ID="${FORGE_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}" \
      -e AWS_SECRET_ACCESS_KEY="${FORGE_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}" \
      -e AWS_DEFAULT_REGION="$FORGE_REGION" \
      -v "$(cd "$local_dir" && pwd):/work" \
      amazon/aws-cli:latest s3 sync "$s3_uri" /work --no-progress
  fi
}

# ---- List + tag --------------------------------------------------------

s3_ls() {
  local forge_id="$1" relative="${2:-}"
  local s3_uri
  s3_uri="s3://${FORGE_BUCKET}/$(_forge_key "$forge_id" "$relative")"
  _s3_aws s3 ls "$s3_uri" --recursive 2>/dev/null || true
}

# s3_tag <forge-id> <relative-key> <tag-set k1=v1&k2=v2...>
s3_tag() {
  local forge_id="$1" relative="$2" tags="$3"
  local key
  key=$(_forge_key "$forge_id" "$relative")
  local pairs
  pairs=$(echo "$tags" | awk -F'&' '{
    for (i=1; i<=NF; i++) {
      n=split($i, kv, "=")
      printf "%s{\"Key\":\"%s\",\"Value\":\"%s\"}", (i>1?",":""), kv[1], kv[2]
    }
  }')
  _s3_aws s3api put-object-tagging \
    --bucket "$FORGE_BUCKET" --key "$key" \
    --tagging "{\"TagSet\":[$pairs]}" >/dev/null
}

# ---- Bucket sanity -----------------------------------------------------

s3_check_bucket() {
  # Use a prefix-bound list-objects (the forge user's policy permits
  # s3:ListBucket only when s3:prefix matches forge/ or _forge-global/).
  # This lets us reach the bucket without unconditional bucket-level ops.
  if ! _s3_aws s3api list-objects-v2 \
        --bucket "$FORGE_BUCKET" \
        --prefix "${FORGE_PREFIX}/" \
        --max-keys 1 \
        --query 'KeyCount' --output text >/dev/null 2>&1; then
    echo "s3_check_bucket: bucket $FORGE_BUCKET prefix ${FORGE_PREFIX}/ not accessible" >&2
    return 1
  fi
  # Versioning check is best-effort — get-bucket-versioning is bucket-level
  # and may not be in the forge policy. Skip silently if forbidden.
  local versioning
  versioning=$(_s3_aws s3api get-bucket-versioning \
    --bucket "$FORGE_BUCKET" --query Status --output text 2>/dev/null || echo "unknown")
  if [[ "$versioning" == "unknown" ]]; then
    echo "OK $FORGE_BUCKET prefix ${FORGE_PREFIX}/ accessible (versioning check skipped — bucket-level perms not granted to forge user)"
  elif [[ "$versioning" != "Enabled" ]]; then
    echo "s3_check_bucket: WARNING bucket $FORGE_BUCKET versioning is '$versioning' (need Enabled for manifest concurrency)" >&2
    return 2
  else
    echo "OK $FORGE_BUCKET versioning=Enabled region=$FORGE_REGION prefix=${FORGE_PREFIX}/"
  fi
}

# ---- _forge-global helpers --------------------------------------------

s3_global_put() {
  local local_file="$1" relative="$2"
  local key
  key="${FORGE_GLOBAL_PREFIX}/${relative}"
  local abs_dir base_name
  abs_dir=$(cd "$(dirname "$local_file")" && pwd)
  base_name=$(basename "$local_file")

  if command -v aws >/dev/null 2>&1; then
    _s3_aws s3api put-object \
      --bucket "$FORGE_BUCKET" --key "$key" \
      --body "$local_file" \
      --tagging "Project=slm-forge&scope=global" >/dev/null
  else
    docker run --rm --user "$(id -u):$(id -g)" \
      -e AWS_ACCESS_KEY_ID="${FORGE_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}" \
      -e AWS_SECRET_ACCESS_KEY="${FORGE_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}" \
      -e AWS_DEFAULT_REGION="$FORGE_REGION" \
      -v "$abs_dir:/work" \
      amazon/aws-cli:latest s3api put-object \
      --bucket "$FORGE_BUCKET" --key "$key" \
      --body "/work/$base_name" \
      --tagging "Project=slm-forge&scope=global" >/dev/null
  fi
}

s3_global_get() {
  local relative="$1" local_file="$2"
  local key abs_dir base_name
  key="${FORGE_GLOBAL_PREFIX}/${relative}"
  mkdir -p "$(dirname "$local_file")"
  abs_dir=$(cd "$(dirname "$local_file")" && pwd)
  base_name=$(basename "$local_file")

  if command -v aws >/dev/null 2>&1; then
    _s3_aws s3api get-object \
      --bucket "$FORGE_BUCKET" --key "$key" "$local_file" >/dev/null
  else
    docker run --rm --user "$(id -u):$(id -g)" \
      -e AWS_ACCESS_KEY_ID="${FORGE_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}" \
      -e AWS_SECRET_ACCESS_KEY="${FORGE_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}" \
      -e AWS_DEFAULT_REGION="$FORGE_REGION" \
      -v "$abs_dir:/work" \
      amazon/aws-cli:latest s3api get-object \
      --bucket "$FORGE_BUCKET" --key "$key" "/work/$base_name" >/dev/null
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-help}"
  shift || true
  case "$cmd" in
    put|get|sync_to|sync_from|ls|tag|check_bucket|global_put|global_get|uri_for)
      "s3_${cmd}" "$@"
      ;;
    help|*)
      cat <<EOF
Usage: $0 <command> [args...]
  put <forge-id> <local-file> <relative-key> [extra-tags]
  get <forge-id> <relative-key> <local-file>
  sync_to <forge-id> <local-dir> <relative-prefix>
  sync_from <forge-id> <relative-prefix> <local-dir>
  ls <forge-id> [relative-prefix]
  tag <forge-id> <relative-key> <k=v&k=v>
  check_bucket
  global_put <local-file> <relative-key>
  global_get <relative-key> <local-file>
  uri_for <forge-id> <relative-key>
EOF
      ;;
  esac
fi
