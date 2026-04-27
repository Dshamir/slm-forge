#!/usr/bin/env bash
# skills/forge-intake/run.sh — INTAKE phase implementation.
#
# Two modes:
#   Interactive (default):  interviews the user via stdin. Use when Claude
#                           is driving the master dispatch loop.
#   Auto-spec mode:         reads a pre-canned spec JSON from file. Used by
#                           tests/smoke-test.sh so the pipeline can run
#                           end-to-end without human input.
#
# Exit code 0 + prints JSON result; non-zero on failure.
#
# Usage:
#   run.sh <forge-id> [--auto-spec <path-to-spec.json>]
#
# On success, prints one JSON line to stdout:
#   {"status":"completed","next_phase":"ARCHITECT","skill":"forge-intake",
#    "forge_id":"<id>"}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../../lib"

# shellcheck source=../../lib/manifest.sh
source "${LIB}/manifest.sh"

FORGE_ID=""
AUTO_SPEC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-spec) AUTO_SPEC="$2"; shift 2 ;;
    --help|-h)
      sed -n '3,14p' "$0"; exit 0 ;;
    -*)
      echo "forge-intake: unknown flag '$1'" >&2; exit 64 ;;
    *)
      FORGE_ID="$1"; shift ;;
  esac
done

if [[ -z "$FORGE_ID" ]]; then
  echo "forge-intake: forge-id required" >&2
  exit 64
fi

# ---- Spec assembly -----------------------------------------------------

build_spec_from_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "forge-intake: --auto-spec file not found: $path" >&2
    return 1
  fi
  if ! jq empty "$path" 2>/dev/null; then
    echo "forge-intake: --auto-spec file is not valid JSON" >&2
    return 1
  fi
  cat "$path"
}

build_spec_interactively() {
  # Minimal v1: prompt for each field. In practice, Claude (the master
  # skill's dispatcher) will drive this by parsing the prompts and
  # providing answers — this script's stdout becomes the conversation.
  local goal domain corpus_ref target_use target_latency target_quality \
        license lang max_params budget_cap max_hours

  read -rp "1/11 Goal, one sentence (Train a small model that...): " goal
  read -rp "2/11 Domain (e.g. dental.radiology, legal.contracts): " domain
  read -rp "3/11 Corpus location (s3://.., hf://dataset, https://..., local:/path): " corpus_ref
  read -rp "4/11 Target use (local-laptop | api-serving | mobile): " target_use
  read -rp "5/11 Target latency ms [500]: " target_latency
  read -rp "6/11 Quality target (e.g. 'comparable-to-llama-3.2-1b-on-domain-evals'): " target_quality
  read -rp "7/11 License preference [apache-2.0]: " license
  read -rp "8/11 Language [en]: " lang
  read -rp "9/11 Max params [300000000]: " max_params
  read -rp "10/11 Budget cap USD [100]: " budget_cap
  read -rp "11/11 Max wall-clock hours [24]: " max_hours

  target_latency="${target_latency:-500}"
  license="${license:-apache-2.0}"
  lang="${lang:-en}"
  max_params="${max_params:-300000000}"
  budget_cap="${budget_cap:-100}"
  max_hours="${max_hours:-24}"

  jq -n \
    --arg goal "$goal" \
    --arg domain "$domain" \
    --arg corpus_ref "$corpus_ref" \
    --arg target_use "$target_use" \
    --argjson target_latency_ms "$target_latency" \
    --arg target_quality "$target_quality" \
    --arg license "$license" \
    --arg lang "$lang" \
    --argjson max_params "$max_params" \
    --argjson budget_cap "$budget_cap" \
    --argjson max_hours "$max_hours" \
    '{
      goal: $goal,
      domain: $domain,
      corpus_ref: $corpus_ref,
      target_use: $target_use,
      target_latency_ms: $target_latency_ms,
      target_quality: $target_quality,
      license_preference: $license,
      language: $lang,
      constraints: {
        max_params: $max_params,
        budget_cap_usd: $budget_cap,
        max_wall_clock_hours: $max_hours
      }
    }'
}

# ---- Validation --------------------------------------------------------

validate_spec() {
  local spec="$1"
  local missing=""
  for field in goal domain corpus_ref target_use license_preference language constraints; do
    if ! echo "$spec" | jq -e "has(\"$field\")" >/dev/null 2>&1; then
      missing+="  - $field\n"
    fi
  done
  for cfield in max_params budget_cap_usd; do
    if ! echo "$spec" | jq -e ".constraints | has(\"$cfield\")" >/dev/null 2>&1; then
      missing+="  - constraints.$cfield\n"
    fi
  done
  if [[ -n "$missing" ]]; then
    echo -e "forge-intake: spec missing required fields:\n$missing" >&2
    return 1
  fi

  # Honor the 300M ceiling (D-005).
  local max_params
  max_params=$(echo "$spec" | jq -r '.constraints.max_params // 0')
  if (( max_params > 300000000 )); then
    echo "forge-intake: constraints.max_params ($max_params) exceeds D-005 ceiling (300M)" >&2
    return 1
  fi
}

# ---- Main --------------------------------------------------------------

if [[ -n "$AUTO_SPEC" ]]; then
  SPEC=$(build_spec_from_file "$AUTO_SPEC")
else
  SPEC=$(build_spec_interactively)
fi

validate_spec "$SPEC"

# Idempotency: if this forge already has a non-empty spec, short-circuit.
EXISTING_SPEC=$(manifest_load "$FORGE_ID" 2>/dev/null | jq -c '.spec // {}')
if [[ "$EXISTING_SPEC" != "{}" && "$EXISTING_SPEC" != "null" ]]; then
  # Only bail if the user isn't trying to overwrite — in auto-spec mode
  # we simply skip (idempotent re-run). Interactive mode would re-ask if
  # it reaches here.
  if [[ -n "$AUTO_SPEC" ]]; then
    echo "forge-intake: spec already populated; skipping (idempotent re-run)" >&2
    jq -n --arg fid "$FORGE_ID" '{
      status: "completed",
      next_phase: "ARCHITECT",
      skill: "forge-intake",
      forge_id: $fid,
      idempotent: true
    }'
    exit 0
  fi
fi

# Write spec + advance phase to ARCHITECT. manifest_patch handles
# optimistic concurrency + retry.
manifest_patch "$FORGE_ID" "
  .spec = ${SPEC}
  | .phase = \"ARCHITECT\"
  | .phase_history[-1].exited_at = (now | todate)
  | .phase_history[-1].status = \"completed\"
  | .phase_history += [{
      phase: \"ARCHITECT\",
      entered_at: (now | todate),
      exited_at: null,
      status: \"in-progress\"
    }]
" >/dev/null

jq -n --arg fid "$FORGE_ID" '{
  status: "completed",
  next_phase: "ARCHITECT",
  skill: "forge-intake",
  forge_id: $fid
}'
