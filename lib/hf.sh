#!/usr/bin/env bash
# slm-forge/lib/hf.sh
#
# HuggingFace Hub API wrappers. Reads HF_TOKEN from env (vault-client
# pattern — secrets live in /admin/credentials and .env, never in code).
#
# Operations:
#   hf_whoami                              -> prints {name, type, role}
#   hf_create_repo <repo-id> [model|dataset|space] [private|public]
#   hf_upload_folder <local-dir> <repo-id> [path-in-repo]
#   hf_create_space <repo-id> <sdk> [private|public]
#       sdk: gradio | streamlit | docker | static
#   hf_dataset_download <dataset-id> <local-dir>
#   hf_repo_exists <repo-id> [model|dataset|space]
#
# Implementation notes:
#   - Uses curl + the HF REST API for whoami / repo existence / repo create.
#   - Uses huggingface-cli (Python package) for upload + download. Container
#     fallback when not installed natively.

set -euo pipefail

HF_API_BASE="${HF_API_BASE:-https://huggingface.co}"
HF_PYTHON_IMAGE="${HF_PYTHON_IMAGE:-python:3.11-slim}"

_hf_token() {
  if [[ -n "${HF_TOKEN:-}" ]]; then
    echo "$HF_TOKEN"
    return 0
  fi
  echo "hf.sh: HF_TOKEN must be set (export from /admin/credentials or .env)" >&2
  return 64
}

_hf_curl() {
  local token
  token=$(_hf_token) || return 1
  curl -sS -H "Authorization: Bearer $token" "$@"
}

# ---- whoami ------------------------------------------------------------

hf_whoami() {
  _hf_curl "${HF_API_BASE}/api/whoami-v2" | jq '{name, type, role: (.auth.accessToken.role // .accessToken.role // "unknown"), orgs: [.orgs[]?.name]}'
}

# ---- repo existence ----------------------------------------------------

# hf_repo_exists <repo-id> [model|dataset|space]
hf_repo_exists() {
  local repo_id="$1"
  local kind="${2:-model}"
  local path
  case "$kind" in
    model)   path="api/models/${repo_id}" ;;
    dataset) path="api/datasets/${repo_id}" ;;
    space)   path="api/spaces/${repo_id}" ;;
    *) echo "hf_repo_exists: unknown kind '$kind'" >&2; return 64 ;;
  esac
  local code
  code=$(_hf_curl -o /dev/null -w "%{http_code}" "${HF_API_BASE}/${path}")
  [[ "$code" == "200" ]]
}

# ---- create repo -------------------------------------------------------

# hf_create_repo <repo-id> [model|dataset|space] [private|public]
hf_create_repo() {
  local repo_id="$1"
  local kind="${2:-model}"
  local visibility="${3:-private}"

  case "$kind" in
    model|dataset|space) ;;
    *) echo "hf_create_repo: unknown kind '$kind'" >&2; return 64 ;;
  esac
  case "$visibility" in
    private|public) ;;
    *) echo "hf_create_repo: unknown visibility '$visibility'" >&2; return 64 ;;
  esac

  local private_bool
  if [[ "$visibility" == "private" ]]; then private_bool="true"; else private_bool="false"; fi

  local namespace name
  namespace="${repo_id%%/*}"
  name="${repo_id#*/}"

  local payload
  payload=$(jq -n \
    --arg name "$name" \
    --arg org "$namespace" \
    --arg type "$kind" \
    --argjson priv "$private_bool" \
    '{name: $name, organization: $org, type: $type, private: $priv}')

  local resp
  resp=$(_hf_curl -X POST -H "Content-Type: application/json" \
    -d "$payload" "${HF_API_BASE}/api/repos/create")
  echo "$resp"
}

# ---- create space (SDK-aware) ------------------------------------------

# hf_create_space <repo-id> <sdk: gradio|streamlit|docker|static> [private|public]
hf_create_space() {
  local repo_id="$1"
  local sdk="$2"
  local visibility="${3:-private}"

  case "$sdk" in
    gradio|streamlit|docker|static) ;;
    *) echo "hf_create_space: unknown sdk '$sdk'" >&2; return 64 ;;
  esac

  local private_bool
  if [[ "$visibility" == "private" ]]; then private_bool="true"; else private_bool="false"; fi

  local namespace name
  namespace="${repo_id%%/*}"
  name="${repo_id#*/}"

  local payload
  payload=$(jq -n \
    --arg name "$name" --arg org "$namespace" \
    --arg sdk "$sdk" --argjson priv "$private_bool" \
    '{name: $name, organization: $org, type: "space", sdk: $sdk, private: $priv}')

  _hf_curl -X POST -H "Content-Type: application/json" \
    -d "$payload" "${HF_API_BASE}/api/repos/create"
}

# ---- upload + download (huggingface-cli wrapper) -----------------------

_hf_cli() {
  local token
  token=$(_hf_token) || return 1
  local mount_dir="$1"; shift
  # The `huggingface-cli` binary was deprecated in huggingface_hub ≥ 1.0
  # in favor of `hf`. We use `hf` directly.
  if command -v hf >/dev/null 2>&1; then
    HF_TOKEN="$token" hf "$@"
  elif command -v huggingface-cli >/dev/null 2>&1; then
    HF_TOKEN="$token" huggingface-cli "$@"
  else
    # Running --user (non-root) in the python image: pip can't write to
    # /.local or /.cache. Set HOME=/tmp and use --user so pip installs
    # under /tmp/.local/, which is writable.
    docker run --rm --user "$(id -u):$(id -g)" \
      -e HF_TOKEN="$token" \
      -e HOME=/tmp \
      -e PATH=/tmp/.local/bin:/usr/local/bin:/usr/bin:/bin \
      -v "$(cd "$mount_dir" && pwd):/work" \
      -w /work \
      "$HF_PYTHON_IMAGE" \
      bash -c "pip install --quiet --user huggingface_hub hf_xet && hf $*"
  fi
}

# hf_upload_folder <local-dir> <repo-id> [path-in-repo] [model|dataset|space]
hf_upload_folder() {
  local local_dir="$1" repo_id="$2"
  local path_in_repo="${3:-}"
  local kind="${4:-model}"
  local args=( upload "$repo_id" "/work" )
  if [[ -n "$path_in_repo" ]]; then
    args+=( "$path_in_repo" )
  fi
  args+=( --repo-type "$kind" )
  _hf_cli "$local_dir" "${args[@]}"
}

# hf_dataset_download <dataset-id> <local-dir>
hf_dataset_download() {
  local dataset_id="$1" local_dir="$2"
  mkdir -p "$local_dir"
  _hf_cli "$local_dir" download "$dataset_id" --repo-type dataset --local-dir /work
}

# hf_delete_repo <repo-id> [model|dataset|space]
# Used by smoke tests to clean up throwaway repos.
hf_delete_repo() {
  local repo_id="$1"
  local kind="${2:-model}"
  local payload
  payload=$(jq -n --arg name "${repo_id#*/}" --arg org "${repo_id%%/*}" --arg type "$kind" \
    '{name: $name, organization: $org, type: $type}')
  _hf_curl -X DELETE -H "Content-Type: application/json" \
    -d "$payload" "${HF_API_BASE}/api/repos/delete"
}

# hf_space_status <repo-id>
# Returns the current build/runtime stage of a Space (NO_APP | BUILDING |
# RUNNING | STOPPED | ERROR | ...). Used to confirm forge-register's
# Space upload actually produced a working Space.
hf_space_status() {
  local repo_id="$1"
  _hf_curl "${HF_API_BASE}/api/spaces/${repo_id}/runtime" \
    | jq -r '.stage // "unknown"'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-help}"
  shift || true
  case "$cmd" in
    whoami|repo_exists|create_repo|create_space|upload_folder|dataset_download|delete_repo|space_status)
      "hf_${cmd}" "$@"
      ;;
    help|*)
      cat <<EOF
Usage: $0 <command> [args...]
  whoami
  repo_exists <repo-id> [model|dataset|space]
  create_repo <repo-id> [model|dataset|space] [private|public]
  create_space <repo-id> <gradio|streamlit|docker|static> [private|public]
  upload_folder <local-dir> <repo-id> [path-in-repo] [model|dataset|space]
  dataset_download <dataset-id> <local-dir>

Environment:
  HF_TOKEN          required (from /admin/credentials or .env)
  HF_API_BASE       (default: https://huggingface.co)
  HF_PYTHON_IMAGE   (default: python:3.11-slim, used when huggingface-cli not native)
EOF
      ;;
  esac
fi
