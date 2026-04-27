#!/usr/bin/env bash
# slm-forge/scripts/dispatch.sh
#
# Walks the phase table for a forge. Used by smoke tests and by the master
# skill's auto-advance mode. Invokes each phase's run.sh in sequence,
# capturing its JSON result and advancing per next_phase.
#
# Usage:
#   dispatch.sh <forge-id> [--until <phase>] [--auto-approve-gates]
#                          [--auto-spec <path>]
#
# --until PHASE: stop advancing after the named phase is entered (not
#                after it completes; useful for partial runs).
# --auto-approve-gates: skip the inline BUDGET_GATE / QUALITY_GATE prompts,
#                      setting status=passed. Smoke-only; interactive mode
#                      prompts the user.
# --auto-spec PATH: passed through to forge-intake for non-interactive spec.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB="${ROOT}/lib"
SKILLS="${ROOT}/skills"

# shellcheck source=../lib/manifest.sh
source "${LIB}/manifest.sh"

FORGE_ID=""
UNTIL_PHASE=""
AUTO_APPROVE_GATES=""
AUTO_SPEC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --until)                UNTIL_PHASE="$2"; shift 2 ;;
    --auto-approve-gates)   AUTO_APPROVE_GATES="yes"; shift ;;
    --auto-spec)            AUTO_SPEC="$2"; shift 2 ;;
    --help|-h)
      sed -n '3,16p' "$0"; exit 0 ;;
    -*)
      echo "dispatch: unknown flag '$1'" >&2; exit 64 ;;
    *)
      FORGE_ID="$1"; shift ;;
  esac
done

if [[ -z "$FORGE_ID" ]]; then
  echo "dispatch: forge-id required" >&2
  exit 64
fi

# ---- Phase → sub-skill map --------------------------------------------
# Mirrors slm-forge-brief/architecture/PHASE_TABLE.md.

phase_to_skill() {
  case "$1" in
    INTAKE)       echo "forge-intake" ;;
    ARCHITECT)    echo "forge-architect" ;;
    ESTIMATE)     echo "forge-estimate" ;;
    BUDGET_GATE)  echo "__GATE__" ;;
    SOURCE)       echo "forge-source" ;;
    CURATE)       echo "forge-curate" ;;
    SHAPE)        echo "forge-shape" ;;
    PROVISION)    echo "forge-provision" ;;
    BOOTSTRAP)    echo "forge-bootstrap" ;;
    TRAIN)        echo "forge-train" ;;
    MONITOR)      echo "forge-monitor" ;;
    EVAL)         echo "forge-eval" ;;
    QUALITY_GATE) echo "__GATE__" ;;
    QUANTIZE)     echo "forge-quantize" ;;
    REGISTER)     echo "forge-register" ;;
    TEARDOWN)     echo "forge-teardown" ;;
    DONE|INIT)    echo "" ;;
    *)            echo "?" ;;
  esac
}

# ---- Gate handler -----------------------------------------------------

handle_gate() {
  local gate_key="$1"   # budget_gate | quality_gate
  local next_phase="$2"

  local manifest
  manifest=$(manifest_load "$FORGE_ID" 2>/dev/null)

  if [[ "$gate_key" == "budget_gate" ]]; then
    local total cap conf instance
    total=$(echo "$manifest" | jq -r '.estimate.estimated_total_cost_usd // 0')
    cap=$(echo "$manifest" | jq -r '.spec.constraints.budget_cap_usd // 0')
    conf=$(echo "$manifest" | jq -r '.estimate.confidence // "unknown"')
    instance=$(echo "$manifest" | jq -r '.estimate.instance_type // "?"')
    echo "[gate:budget] estimated total \$${total} / cap \$${cap} (confidence=${conf}, instance=${instance})" >&2
  else
    echo "[gate:quality] review eval reports" >&2
  fi

  local approve="no"
  if [[ -n "$AUTO_APPROVE_GATES" ]]; then
    approve="yes"
    echo "[gate] --auto-approve-gates is set → passing gate" >&2
  else
    read -rp "Approve $gate_key? [yes/no]: " ans
    case "${ans,,}" in yes|y) approve="yes" ;; esac
  fi

  if [[ "$approve" != "yes" ]]; then
    echo "[gate] $gate_key not approved — stopping dispatch" >&2
    manifest_patch "$FORGE_ID" "
      .gates.${gate_key}.status = \"rejected\"
      | .gates.${gate_key}.passed_at = null
      | .gates.${gate_key}.passed_by_user = false
    " >/dev/null
    return 1
  fi

  manifest_patch "$FORGE_ID" "
    .gates.${gate_key}.status = \"passed\"
    | .gates.${gate_key}.passed_at = (now | todate)
    | .gates.${gate_key}.passed_by_user = true
    | .phase = \"${next_phase}\"
    | .phase_history[-1].exited_at = (now | todate)
    | .phase_history[-1].status = \"completed\"
    | .phase_history += [{
        phase: \"${next_phase}\",
        entered_at: (now | todate),
        exited_at: null,
        status: \"in-progress\"
      }]
  " >/dev/null
}

# ---- Dispatch loop ----------------------------------------------------

# Initialize if manifest not yet created
if ! manifest_load "$FORGE_ID" >/dev/null 2>&1; then
  echo "dispatch: forge $FORGE_ID not found — call manifest_init first" >&2
  exit 1
fi

MAX_ITER=20
iter=0
while (( iter < MAX_ITER )); do
  iter=$((iter + 1))
  manifest=$(manifest_load "$FORGE_ID" 2>/dev/null)
  phase=$(echo "$manifest" | jq -r .phase)

  echo "[dispatch] iter=$iter phase=$phase" >&2

  if [[ -n "$UNTIL_PHASE" && "$phase" == "$UNTIL_PHASE" ]]; then
    # The --until target was just entered. We stop BEFORE running its skill
    # when the caller asked for "go as far as PHASE then stop BEFORE". But
    # the common smoke-test intent is "run THROUGH phase". Here we run the
    # phase's skill (if any) and then stop. Adjust this if semantics change.
    :
  fi

  case "$phase" in
    DONE)
      echo "[dispatch] DONE — forge complete" >&2
      break
      ;;
    INIT)
      # Move to INTAKE
      manifest_patch "$FORGE_ID" "
        .phase = \"INTAKE\"
        | .phase_history[-1].exited_at = (now | todate)
        | .phase_history[-1].status = \"completed\"
        | .phase_history += [{
            phase: \"INTAKE\",
            entered_at: (now | todate),
            exited_at: null,
            status: \"in-progress\"
          }]
      " >/dev/null
      continue
      ;;
    BUDGET_GATE)
      handle_gate "budget_gate" "SOURCE" || exit 1
      ;;
    QUALITY_GATE)
      handle_gate "quality_gate" "QUANTIZE" || exit 1
      ;;
    *)
      skill=$(phase_to_skill "$phase")
      if [[ -z "$skill" || "$skill" == "?" ]]; then
        echo "dispatch: unknown phase '$phase'" >&2
        exit 1
      fi

      run_sh="${SKILLS}/${skill}/run.sh"
      if [[ ! -x "$run_sh" ]]; then
        # Skill not yet implemented — stop gracefully (M2 stops after SHAPE).
        echo "[dispatch] skill $skill not yet implemented (no run.sh) — stopping" >&2
        break
      fi

      # Build args per skill
      args=( "$FORGE_ID" )
      if [[ "$skill" == "forge-intake" && -n "$AUTO_SPEC" ]]; then
        args+=( --auto-spec "$AUTO_SPEC" )
      fi

      echo "[dispatch] invoke $skill" >&2
      result=$(bash "$run_sh" "${args[@]}")
      echo "$result" | jq .
      status=$(echo "$result" | jq -r .status)
      if [[ "$status" != "completed" ]]; then
        echo "[dispatch] skill $skill returned status=$status — stopping" >&2
        exit 1
      fi
      ;;
  esac

  # Check --until after processing (so we stop AFTER the target phase completes)
  if [[ -n "$UNTIL_PHASE" ]]; then
    new_phase=$(manifest_load "$FORGE_ID" 2>/dev/null | jq -r .phase)
    # Stop when the current phase (not yet entered) would be past the target.
    # Convention: --until SHAPE means "advance through SHAPE's completion,
    # stop before entering PROVISION."
    case "$UNTIL_PHASE:$new_phase" in
      INTAKE:ARCHITECT|ARCHITECT:ESTIMATE|ESTIMATE:BUDGET_GATE| \
      SOURCE:CURATE|CURATE:SHAPE|SHAPE:PROVISION|PROVISION:BOOTSTRAP| \
      BOOTSTRAP:TRAIN|TRAIN:MONITOR|MONITOR:EVAL|EVAL:QUALITY_GATE| \
      QUANTIZE:REGISTER|REGISTER:TEARDOWN|TEARDOWN:DONE)
        echo "[dispatch] --until $UNTIL_PHASE reached (next would be $new_phase) — stopping" >&2
        break
        ;;
    esac
  fi
done

if (( iter >= MAX_ITER )); then
  echo "dispatch: hit MAX_ITER=$MAX_ITER — possible loop" >&2
  exit 1
fi

final=$(manifest_load "$FORGE_ID" 2>/dev/null | jq -c '{forge_id, phase, artifacts, estimate}')
echo "[dispatch] final state: $final" >&2
