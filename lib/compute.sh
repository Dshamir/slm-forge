#!/usr/bin/env bash
# slm-forge/lib/compute.sh
#
# ComputeTarget provider dispatcher. Reads manifest.compute_target.provider
# (default "aws") and routes to the matching impl. Today AWS is the only
# provider. Future stubs (vast.ai, gcp, torii) slot in here without touching
# any sub-skill.
#
# Usage:
#   source "$(dirname "$0")/../lib/compute.sh"
#   compute provision <spec-json>
#   compute exec <forge-id> <cmd>
#   compute teardown <forge-id>

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./compute_aws.sh
source "${LIB_DIR}/compute_aws.sh"

# compute <op> <forge-id> [args...]
# Resolves provider from the manifest and dispatches to compute_<provider>_<op>.
compute() {
  local op="$1"; shift
  local forge_id="${1:-}"

  local provider
  if [[ -n "${forge_id:-}" && "$forge_id" != "--provider" ]]; then
    provider=$(_compute_provider_from_manifest "$forge_id")
  elif [[ "$1" == "--provider" ]]; then
    shift; provider="$1"; shift
  else
    provider="aws"
  fi
  provider="${provider:-aws}"

  local fn="compute_${provider}_${op}"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    echo "compute: unknown provider/op combination: $fn" >&2
    return 64
  fi
  "$fn" "$@"
}

_compute_provider_from_manifest() {
  local forge_id="$1"
  local local_path="${FORGE_WORK:-${HOME}/.slm-forge}/manifests/${forge_id}.json"
  if [[ -f "$local_path" ]]; then
    jq -r '.compute_target.provider // "aws"' "$local_path"
  else
    echo "aws"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  compute "$@"
fi
