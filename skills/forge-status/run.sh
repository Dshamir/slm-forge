#!/usr/bin/env bash
# skills/forge-status/run.sh
#
# Read-only status helper. Renders a human-readable report for a forge.
# Never mutates state. Safe to call at any time on any forge regardless
# of phase (including DONE, failed, or never-started).
#
# Usage:
#   run.sh [<forge-id>]       # defaults to current-forge pointer
#   run.sh --json [<forge-id>]  # machine-readable JSON instead of pretty
#   run.sh --no-liveness [<forge-id>]  # skip SSM liveness probe (faster)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../../lib"

# shellcheck source=../../lib/manifest.sh
source "${LIB}/manifest.sh"
# shellcheck source=../../lib/compute_aws.sh
source "${LIB}/compute_aws.sh"

FORGE_ID=""
OUTPUT_FORMAT="pretty"
LIVENESS="yes"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)         OUTPUT_FORMAT="json"; shift ;;
    --no-liveness)  LIVENESS="no"; shift ;;
    -*)
      echo "forge-status: unknown flag '$1'" >&2; exit 64 ;;
    *)
      FORGE_ID="$1"; shift ;;
  esac
done

if [[ -z "$FORGE_ID" ]]; then
  FORGE_ID=$(manifest_current_forge 2>/dev/null || echo "")
  if [[ -z "$FORGE_ID" ]]; then
    echo "forge-status: no forge-id provided and no current-forge pointer" >&2
    echo "  Set one: bash slm-forge/lib/manifest.sh set-current <forge-id>" >&2
    echo "  Or pass: bash skills/forge-status/run.sh <forge-id>" >&2
    exit 64
  fi
fi

# ---- Load manifest -----------------------------------------------------

MANIFEST=$(manifest_load "$FORGE_ID" 2>/dev/null)
if [[ -z "$MANIFEST" ]]; then
  echo "forge-status: could not load manifest for $FORGE_ID" >&2
  exit 1
fi

# ---- JSON mode (short-circuit) ----------------------------------------

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  # Enrich with a computed cost + liveness, emit full JSON.
  COST_NOW=$(compute_aws_cost_to_date "$FORGE_ID" 2>/dev/null || echo "0.00")
  echo "$MANIFEST" | jq \
    --arg cost "$COST_NOW" \
    '. + { computed: { cost_to_date_fast_estimate: ($cost | tonumber) } }'
  exit 0
fi

# ---- Pretty format helpers --------------------------------------------

hr() { printf '%.0s=' {1..65}; echo; }

fmt_dt() {
  local iso="$1"
  [[ -z "$iso" || "$iso" == "null" ]] && echo "(never)" && return
  echo "$iso"
}

fmt_age() {
  local iso="$1"
  [[ -z "$iso" || "$iso" == "null" ]] && echo "" && return
  local epoch_then epoch_now diff
  epoch_then=$(date -u -d "$iso" +%s 2>/dev/null || echo 0)
  epoch_now=$(date -u +%s)
  diff=$((epoch_now - epoch_then))
  if (( diff < 60 )); then echo "${diff}s ago"
  elif (( diff < 3600 )); then echo "$((diff/60))m ago"
  elif (( diff < 86400 )); then echo "$((diff/3600))h $(( (diff%3600)/60 ))m ago"
  else echo "$((diff/86400))d ago"
  fi
}

fmt_duration() {
  local start="$1" end="$2"
  [[ -z "$start" || "$start" == "null" ]] && echo "" && return
  local epoch_s epoch_e diff
  epoch_s=$(date -u -d "$start" +%s 2>/dev/null || echo 0)
  if [[ -n "$end" && "$end" != "null" ]]; then
    epoch_e=$(date -u -d "$end" +%s 2>/dev/null || echo 0)
  else
    epoch_e=$(date -u +%s)
  fi
  diff=$((epoch_e - epoch_s))
  if (( diff < 60 )); then echo "${diff}s"
  elif (( diff < 3600 )); then echo "$((diff/60))m"
  else echo "$((diff/3600))h $(( (diff%3600)/60 ))m"
  fi
}

phase_symbol() {
  case "$1" in
    completed) echo "✓" ;;
    in-progress) echo "…" ;;
    failed) echo "✗" ;;
    skipped) echo "↷" ;;
    pending) echo "·" ;;
    *) echo "?" ;;
  esac
}

# ---- Sections ---------------------------------------------------------

hr
echo "Forge: $(echo "$MANIFEST" | jq -r .forge_id)"
hr

echo "  created:    $(fmt_dt "$(echo "$MANIFEST" | jq -r .created_at)")  (by $(echo "$MANIFEST" | jq -r .created_by))"
echo "  phase:      $(echo "$MANIFEST" | jq -r .phase)"
echo "  updated:    $(fmt_dt "$(echo "$MANIFEST" | jq -r .updated_at)")  ($(fmt_age "$(echo "$MANIFEST" | jq -r .updated_at)"))"

echo ""
echo "Spec:"
spec=$(echo "$MANIFEST" | jq -c .spec)
if [[ "$spec" == "null" || "$spec" == "{}" ]]; then
  echo "  (empty — forge-intake not yet run)"
else
  echo "  goal:        $(echo "$spec" | jq -r '.goal // "(unset)"')"
  echo "  domain:      $(echo "$spec" | jq -r '.domain // "(unset)"')"
  echo "  target_use:  $(echo "$spec" | jq -r '.target_use // "(unset)"')"
  echo "  max_params:  $(echo "$spec" | jq -r '.constraints.max_params // "(unset)" | if . == "(unset)" then . else tostring end')"
  echo "  budget_cap:  \$$(echo "$spec" | jq -r '.constraints.budget_cap_usd // 0')"
  echo "  max_wall:    $(echo "$spec" | jq -r '.constraints.max_wall_clock_hours // 0')h"
fi

echo ""
echo "Plan:"
plan=$(echo "$MANIFEST" | jq -c '.plan // null')
if [[ "$plan" == "null" ]]; then
  echo "  (empty — forge-architect not yet run)"
else
  echo "  base_model:    $(echo "$plan" | jq -r .base_model)"
  echo "  regime:        $(echo "$plan" | jq -r .training_regime)"
  echo "  target_params: $(echo "$plan" | jq -r .target_params)"
  echo "  framework:     $(echo "$plan" | jq -r .training_framework)"
  echo "  chat_template: $(echo "$plan" | jq -r .chat_template)"
fi

echo ""
echo "Estimate:"
est=$(echo "$MANIFEST" | jq -c '.estimate // null')
if [[ "$est" == "null" ]]; then
  echo "  (empty — forge-estimate not yet run)"
else
  echo "  instance:     $(echo "$est" | jq -r .instance_type)  @ \$$(echo "$est" | jq -r .instance_cost_per_hour_usd)/hr"
  echo "  gpu_hours:    $(echo "$est" | jq -r .gpu_hours)  (confidence=$(echo "$est" | jq -r .confidence))"
  echo "  total_est:    \$$(echo "$est" | jq -r .estimated_total_cost_usd)"
fi

echo ""
echo "Phase history:"
echo "$MANIFEST" | jq -r '.phase_history[] | "\(.phase)\t\(.status)\t\(.entered_at)\t\(.exited_at // "")"' | \
  while IFS=$'\t' read -r phase status entered exited; do
    sym=$(phase_symbol "$status")
    dur=$(fmt_duration "$entered" "$exited")
    status_suffix=""
    [[ "$status" != "completed" ]] && status_suffix="  ($status)"
    printf "  %s  %-14s  %s%s\n" "$sym" "$phase" "$dur" "$status_suffix"
  done

echo ""
echo "Artifacts:"
echo "$MANIFEST" | jq -r '
  .artifacts | [
    ["raw_corpus",     .raw_corpus_s3],
    ["curated_corpus", .curated_corpus_s3],
    ["shaped_corpus",  .shaped_corpus_s3],
    ["checkpoints",    .checkpoints_s3],
    ["final_weights",  .final_weights_s3],
    ["eval_reports",   .eval_reports_s3],
    ["gguf_Q4_K_M",    .quantized_s3.Q4_K_M],
    ["gguf_Q8_0",      .quantized_s3.Q8_0],
    ["hf_repo",        .hf_repo],
    ["hf_space",       .hf_space]
  ][] | "  \(.[0]):\t\(.[1] // "(not yet)")"
' | column -t -s $'\t'

echo ""
echo "Compute:"
ct=$(echo "$MANIFEST" | jq -c '.compute_target // null')
if [[ "$ct" == "null" ]]; then
  echo "  (no active instance — not yet provisioned or already torn down)"
else
  iid=$(echo "$ct" | jq -r .instance_id)
  lt=$(echo "$ct" | jq -r .ec2_launch_time)
  it=$(echo "$ct" | jq -r .instance_type)
  echo "  instance:     $iid ($it)"
  echo "  launched:     $(fmt_dt "$lt")  ($(fmt_age "$lt"))"
  echo "  ebs_volume:   $(echo "$ct" | jq -r '.ebs_volume_id // "(root only)"')"
  echo "  auth_method:  $(echo "$ct" | jq -r .auth_method)"
  echo "  bootstrap:    $(echo "$ct" | jq -r '.bootstrap_completed // false | if . then "completed" else "pending" end')"

  if [[ "$LIVENESS" == "yes" ]]; then
    # One lightweight SSM check — skip if --no-liveness
    state=$(_compute_aws_cli ec2 describe-instances --instance-ids "$iid" \
      --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "?")
    ssm=$(_compute_aws_cli ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$iid" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "?")
    echo "  ec2_state:    $state"
    echo "  ssm_status:   $ssm"
  fi
fi

echo ""
echo "Training runtime:"
tr=$(echo "$MANIFEST" | jq -c '.training_runtime // null')
if [[ "$tr" == "null" ]]; then
  echo "  (no active training)"
else
  echo "  pid:            $(echo "$tr" | jq -r .pid)"
  echo "  last_loss:      $(echo "$tr" | jq -r '.last_loss // "(none)"') @ step $(echo "$tr" | jq -r '.last_loss_step // "?"')"
  echo "  last_heartbeat: $(fmt_age "$(echo "$tr" | jq -r '.last_heartbeat // ""')")"
  eta=$(echo "$tr" | jq -r '.eta_remaining_minutes // empty')
  [[ -n "$eta" && "$eta" != "null" ]] && echo "  eta:            ~${eta} min"
fi

echo ""
echo "Cost:"
cost_now=$(compute_aws_cost_to_date "$FORGE_ID" 2>/dev/null || echo "0.00")
cap=$(echo "$MANIFEST" | jq -r '.spec.constraints.budget_cap_usd // 0')
recorded=$(echo "$MANIFEST" | jq -r '.cost_tracking.cost_to_date_usd // 0')
headroom=$(awk -v c="$cost_now" -v b="$cap" 'BEGIN{printf "%.2f", b-c}')
echo "  fast_estimate_now:  \$${cost_now}"
echo "  recorded_in_manifest: \$${recorded}"
echo "  cap:                \$${cap}"
echo "  headroom:           \$${headroom}"
echo "  by_phase:"
echo "$MANIFEST" | jq -r '.cost_tracking.cost_by_phase_usd // {} | to_entries[] | "    \(.key):\t$\(.value)"' | column -t -s $'\t' || true

echo ""
echo "Gates:"
bg=$(echo "$MANIFEST" | jq -r '.gates.budget_gate.status')
qg=$(echo "$MANIFEST" | jq -r '.gates.quality_gate.status')
bg_passed_at=$(echo "$MANIFEST" | jq -r '.gates.budget_gate.passed_at // empty')
qg_passed_at=$(echo "$MANIFEST" | jq -r '.gates.quality_gate.passed_at // empty')
echo "  budget_gate:   $bg${bg_passed_at:+  (at $bg_passed_at)}"
echo "  quality_gate:  $qg${qg_passed_at:+  (at $qg_passed_at)}"

echo ""
errors=$(echo "$MANIFEST" | jq -c '.errors // []')
err_count=$(echo "$errors" | jq 'length')
if (( err_count > 0 )); then
  echo "Errors: ($err_count)"
  echo "$errors" | jq -r '.[] | "  [\(.timestamp // "?")] \(.skill // "?"): \(.message // .error_type // "?")"'
else
  echo "Errors:  (none)"
fi

notes=$(echo "$MANIFEST" | jq -c '.notes // []')
note_count=$(echo "$notes" | jq 'length')
if (( note_count > 0 )); then
  echo "Notes: ($note_count)"
  echo "$notes" | jq -r '.[] | "  [\(.at // "?")] \(.text // "?")"'
else
  echo "Notes:   (none)"
fi

hr
