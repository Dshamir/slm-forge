#!/usr/bin/env bash
# slm-forge/lib/manifest.sh
#
# Manifest reader/writer for forge.state.json. The manifest is the single
# source of truth for a forge run (D-002). Canonical copy lives at
# s3://<YOUR_S3_BUCKET>/forge/<forge-id>/manifest.json with S3
# versioning enabled. Active session mirrors locally to
# $FORGE_WORK/manifest.json.
#
# This library is sourced by sub-skills, not invoked directly:
#   source "$(dirname "$0")/../lib/manifest.sh"
#
# Operations:
#   manifest_init <spec-json>         -> prints forge_id, writes manifest to S3
#   manifest_load <forge-id>          -> prints manifest JSON to stdout
#   manifest_save <forge-id> <json> [version-id]
#                                      -> optimistic write with --if-match
#   manifest_patch <forge-id> <jq-filter>
#                                      -> load -> jq mutate -> save with retry
#   manifest_validate <json>          -> exit 0 if valid, prints errors to stderr
#   manifest_sync_local <forge-id>    -> writes to $FORGE_WORK/manifest.json
#   manifest_current_forge            -> reads $FORGE_WORK/current-forge.txt
#   manifest_set_current <forge-id>   -> writes current-forge.txt pointer
#
# Conventions:
#   - All JSON via jq (no python). bash + jq + aws s3api is sufficient for v1.
#   - All AWS calls go through `forge_aws` from lib/compute_aws.sh OR fall
#     back to direct `aws s3api` if FORGE_AWS_* env vars are present.
#   - Errors print to stderr; functions return non-zero.

set -euo pipefail

# ---- Constants ---------------------------------------------------------

FORGE_BUCKET="${FORGE_BUCKET:-<YOUR_S3_BUCKET>}"
FORGE_REGION="${FORGE_REGION:-ca-central-1}"
FORGE_KMS_ALIAS="${FORGE_KMS_ALIAS:-alias/<YOUR_S3_BUCKET>}"
FORGE_PREFIX="${FORGE_PREFIX:-forge}"
FORGE_WORK="${FORGE_WORK:-${HOME}/.slm-forge}"
FORGE_SCHEMA_VERSION="1.0.0"

# ---- AWS shim ----------------------------------------------------------

# Minimal AWS CLI wrapper. Reads FORGE_AWS_* (preferred) or falls back to
# AWS_* (less safe; uses <YOUR_IAM_USER> scope). Uses Docker when no native cli.
_forge_aws() {
  local key_id="${FORGE_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
  local key_secret="${FORGE_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
  if [[ -z "$key_id" || -z "$key_secret" ]]; then
    echo "manifest.sh: FORGE_AWS_ACCESS_KEY_ID + FORGE_AWS_SECRET_ACCESS_KEY required" >&2
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

# AWS CLI with a Docker volume mount for file I/O. Use when the call
# needs --body <path> or writes to a local path. $1 is the host directory
# to mount as /work in the container; the rest are aws CLI args.
_forge_aws_mount() {
  local mount_dir="$1"; shift
  local key_id="${FORGE_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
  local key_secret="${FORGE_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
  if [[ -z "$key_id" || -z "$key_secret" ]]; then
    echo "manifest.sh: FORGE_AWS_ACCESS_KEY_ID + FORGE_AWS_SECRET_ACCESS_KEY required" >&2
    return 64
  fi
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
      -v "$(cd "$mount_dir" && pwd):/work" \
      amazon/aws-cli:latest "$@"
  fi
}

# ---- Path helpers ------------------------------------------------------

_forge_id_to_s3() {
  echo "s3://${FORGE_BUCKET}/${FORGE_PREFIX}/$1/manifest.json"
}

_forge_id_to_key() {
  echo "${FORGE_PREFIX}/$1/manifest.json"
}

_local_manifest_path() {
  echo "${FORGE_WORK}/manifests/$1.json"
}

# ---- Forge ID generation -----------------------------------------------

# forge-YYYY-MM-DD-<slug>-<6char>
_generate_forge_id() {
  local slug="${1:-forge}"
  slug=$(echo "$slug" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -E 's/-+/-/g; s/^-|-$//g')
  [[ -z "$slug" ]] && slug="forge"
  local date_part suffix
  date_part=$(date -u +%Y-%m-%d)
  suffix=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)
  echo "forge-${date_part}-${slug}-${suffix}"
}

# ---- Validation --------------------------------------------------------

# Minimal schema validation: required top-level fields present.
# Per slm-forge-brief/architecture/MANIFEST_SCHEMA.md.
manifest_validate() {
  local json="$1"
  local errors=""
  local field
  for field in schema_version forge_id created_at updated_at created_by spec phase phase_history cost_tracking gates logs_s3_prefix errors notes; do
    if ! echo "$json" | jq -e "has(\"$field\")" >/dev/null 2>&1; then
      errors+="missing field: $field\n"
    fi
  done
  if [[ -n "$errors" ]]; then
    echo -e "manifest_validate failed:\n$errors" >&2
    return 1
  fi
  return 0
}

# ---- Init --------------------------------------------------------------

# manifest_init [<slug>] [<spec-json>]
# Prints the new forge_id to stdout. Writes initial manifest to S3 + local.
manifest_init() {
  local slug="${1:-}"
  local spec_json="${2:-{\}}"
  local forge_id created_at created_by

  forge_id=$(_generate_forge_id "$slug")
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  created_by="${USER:-unknown}@$(hostname -s)"

  local manifest
  manifest=$(jq -n \
    --arg sv "$FORGE_SCHEMA_VERSION" \
    --arg fid "$forge_id" \
    --arg ts "$created_at" \
    --arg by "$created_by" \
    --arg bucket "$FORGE_BUCKET" \
    --arg prefix "$FORGE_PREFIX" \
    --argjson spec "$spec_json" \
    '{
      schema_version: $sv,
      forge_id: $fid,
      created_at: $ts,
      updated_at: $ts,
      created_by: $by,
      spec: $spec,
      plan: null,
      estimate: null,
      phase: "INIT",
      phase_history: [
        { phase: "INIT", entered_at: $ts, exited_at: null, status: "in-progress" }
      ],
      compute_target: null,
      artifacts: {
        raw_corpus_s3: null,
        curated_corpus_s3: null,
        shaped_corpus_s3: null,
        checkpoints_s3: null,
        final_weights_s3: null,
        quantized_s3: { Q4_K_M: null, Q8_0: null, AWQ: null },
        eval_reports_s3: null,
        model_card_s3: null,
        hf_repo: null,
        hf_space: null
      },
      training_runtime: null,
      cost_tracking: {
        budget_cap_usd: null,
        cost_to_date_usd: 0,
        cost_by_phase_usd: {},
        last_reconciled_at: null,
        reconciliation_source: null
      },
      gates: {
        budget_gate: { required_at: "post-ESTIMATE", status: "pending", passed_at: null, passed_by_user: false },
        quality_gate:{ required_at: "post-EVAL",    status: "pending", passed_at: null, passed_by_user: false }
      },
      logs_s3_prefix: ("s3://" + $bucket + "/" + $prefix + "/" + $fid + "/logs/"),
      errors: [],
      notes: []
    }')

  manifest_validate "$manifest" || return 1

  mkdir -p "$(dirname "$(_local_manifest_path "$forge_id")")"
  echo "$manifest" | jq . > "$(_local_manifest_path "$forge_id")"

  # Push to S3 (versioning is enabled on the bucket; SSE-KMS via bucket policy).
  # Write to a tempfile in the local manifest dir so the Docker mount
  # already covers it; --body needs a real path inside the container.
  local local_path mount_dir base_name
  local_path=$(_local_manifest_path "$forge_id")
  mount_dir=$(dirname "$local_path")
  base_name=$(basename "$local_path")

  _forge_aws_mount "$mount_dir" s3api put-object \
    --bucket "$FORGE_BUCKET" \
    --key "$(_forge_id_to_key "$forge_id")" \
    --content-type "application/json" \
    --tagging "Project=slm-forge&forge-id=$forge_id&phase=INIT" \
    --body "/work/$base_name" >/dev/null

  manifest_set_current "$forge_id"
  echo "$forge_id"
}

# ---- Load --------------------------------------------------------------

# manifest_load <forge-id> [version-id]
# Prints manifest JSON to stdout. Writes the S3 VersionId to stderr as
# "version-id: X" so callers (manifest_save) can use it for --if-match.
manifest_load() {
  local forge_id="$1"
  local version_id="${2:-}"
  local key
  key=$(_forge_id_to_key "$forge_id")

  # Stage the download in a per-call temp dir we can mount.
  local tmp_dir tmp_file meta_file version
  tmp_dir=$(mktemp -d)
  tmp_file="${tmp_dir}/manifest.json"
  meta_file="${tmp_dir}/.meta.json"

  local args=( s3api get-object
    --bucket "$FORGE_BUCKET"
    --key "$key" )
  if [[ -n "$version_id" ]]; then
    args+=( --version-id "$version_id" )
  fi
  args+=( "/work/manifest.json" )

  if ! _forge_aws_mount "$tmp_dir" "${args[@]}" >"$meta_file" 2>"${tmp_dir}/.err"; then
    echo "manifest_load: failed to fetch s3://${FORGE_BUCKET}/${key}" >&2
    cat "${tmp_dir}/.err" >&2 || true
    rm -rf "$tmp_dir"
    return 1
  fi

  version=$(jq -r '.VersionId // empty' "$meta_file" 2>/dev/null || echo "")
  if [[ -n "$version" ]]; then
    echo "version-id: $version" >&2
  fi

  cat "$tmp_file"
  rm -rf "$tmp_dir"
}

# ---- Save --------------------------------------------------------------

# manifest_save <forge-id> <json> [expected-version-id]
# Optimistic concurrency: if expected-version-id is supplied, use --if-match
# to fail when S3 has a newer version.
manifest_save() {
  local forge_id="$1"
  local json="$2"
  local expected_version="${3:-}"

  manifest_validate "$json" || return 1

  json=$(echo "$json" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.updated_at = $ts')

  # Mirror local first; reuse that file as the --body path so we don't
  # need a second tempfile for the upload.
  local local_path mount_dir base_name
  local_path=$(_local_manifest_path "$forge_id")
  mkdir -p "$(dirname "$local_path")"
  echo "$json" | jq . > "$local_path"
  mount_dir=$(dirname "$local_path")
  base_name=$(basename "$local_path")

  local args=( s3api put-object
    --bucket "$FORGE_BUCKET"
    --key "$(_forge_id_to_key "$forge_id")"
    --content-type "application/json"
    --tagging "Project=slm-forge&forge-id=$forge_id"
    --body "/work/$base_name" )

  if [[ -n "$expected_version" ]]; then
    args+=( --if-match "$expected_version" )
  fi

  _forge_aws_mount "$mount_dir" "${args[@]}" >/dev/null
}

# ---- Patch (load + jq mutate + save with retry) ------------------------

# manifest_patch <forge-id> <jq-filter>
# Loads the manifest, applies the jq filter, saves with optimistic
# concurrency. Retries up to 3 times on version mismatch.
manifest_patch() {
  local forge_id="$1"
  local jq_filter="$2"
  local attempt
  for attempt in 1 2 3; do
    local manifest version
    manifest=$(manifest_load "$forge_id" 2> >(grep '^version-id:' >/tmp/.forge-vid-$$ ))
    version=$(awk -F': ' '/^version-id:/ {print $2}' /tmp/.forge-vid-$$ 2>/dev/null || echo "")
    rm -f /tmp/.forge-vid-$$

    local mutated
    mutated=$(echo "$manifest" | jq "$jq_filter")

    if manifest_save "$forge_id" "$mutated" "$version" 2>/dev/null; then
      return 0
    fi
    echo "manifest_patch: version conflict on attempt $attempt; retrying" >&2
    sleep $((attempt * 2))
  done
  echo "manifest_patch: failed after 3 attempts" >&2
  return 1
}

# ---- Local mirror ------------------------------------------------------

manifest_sync_local() {
  local forge_id="$1"
  local local_path
  local_path=$(_local_manifest_path "$forge_id")
  mkdir -p "$(dirname "$local_path")"
  manifest_load "$forge_id" 2>/dev/null > "$local_path"
  echo "$local_path"
}

manifest_current_forge() {
  local pointer="${FORGE_WORK}/current-forge.txt"
  if [[ -f "$pointer" ]]; then
    cat "$pointer"
  else
    return 1
  fi
}

manifest_set_current() {
  mkdir -p "$FORGE_WORK"
  echo "$1" > "${FORGE_WORK}/current-forge.txt"
}

# ---- CLI dispatch (when invoked directly, not sourced) -----------------

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-help}"
  shift || true
  case "$cmd" in
    init)            manifest_init "$@" ;;
    load)            manifest_load "$@" ;;
    save)            manifest_save "$@" ;;
    patch)           manifest_patch "$@" ;;
    validate)        manifest_validate "$@" ;;
    sync-local)      manifest_sync_local "$@" ;;
    current)         manifest_current_forge ;;
    set-current)     manifest_set_current "$@" ;;
    help|*)
      cat <<EOF
Usage: $0 <command> [args...]

  init [slug] [spec-json]    Create new forge, print forge_id
  load <forge-id>            Print manifest JSON to stdout
  save <forge-id> <json> [expected-version-id]
                              Save manifest (optimistic concurrency)
  patch <forge-id> <jq-filter>
                              Load + mutate + save with retry
  validate <json>            Validate manifest schema
  sync-local <forge-id>      Pull S3 copy to local mirror
  current                    Print current forge_id (from \$FORGE_WORK/current-forge.txt)
  set-current <forge-id>     Update current-forge pointer

Environment:
  FORGE_BUCKET        (default: <YOUR_S3_BUCKET>)
  FORGE_REGION        (default: ca-central-1)
  FORGE_PREFIX        (default: forge)
  FORGE_KMS_ALIAS     (default: alias/<YOUR_S3_BUCKET>)
  FORGE_WORK          (default: ~/.slm-forge)
  FORGE_AWS_ACCESS_KEY_ID
  FORGE_AWS_SECRET_ACCESS_KEY
EOF
      ;;
  esac
fi
