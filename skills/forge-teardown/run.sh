#!/usr/bin/env bash
# skills/forge-teardown/run.sh — TEARDOWN phase implementation.
#
# Reads:
#   - manifest.compute_target.{instance_id, ec2_launch_time, cost_per_hour_usd}
# Writes:
#   - manifest.cost_tracking.cost_to_date_usd  (reconciled estimate)
#   - manifest.cost_tracking.cost_by_phase_usd
#   - manifest.cost_tracking.last_reconciled_at
#   - manifest.cost_tracking.reconciliation_source
#   - manifest.compute_target = null  (cleared on success)
#   - Advances phase to DONE.
#
# Modes:
#   --terminate  (default after successful registration; deletes EBS)
#   --stop       (preserves EBS for resume)
#
# When invoked from the dispatcher's normal phase advancement we default
# to terminate; when invoked via /slm-forge abort we default to terminate
# regardless of the current phase.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../../lib"

# shellcheck source=../../lib/manifest.sh
source "${LIB}/manifest.sh"
# shellcheck source=../../lib/compute_aws.sh
source "${LIB}/compute_aws.sh"

FORGE_ID=""
MODE="terminate"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --terminate) MODE="terminate"; shift ;;
    --stop)      MODE="stop"; shift ;;
    -*)
      echo "forge-teardown: unknown flag '$1'" >&2; exit 64 ;;
    *)
      FORGE_ID="$1"; shift ;;
  esac
done

if [[ -z "$FORGE_ID" ]]; then
  echo "forge-teardown: forge-id required" >&2
  exit 64
fi

MANIFEST=$(manifest_load "$FORGE_ID" 2>/dev/null)
INSTANCE_ID=$(echo "$MANIFEST" | jq -r '.compute_target.instance_id // ""')

# Idempotency: nothing to tear down if no compute_target
if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "null" ]]; then
  echo "forge-teardown: no compute_target.instance_id — already torn down or never provisioned" >&2
  manifest_patch "$FORGE_ID" "
    .phase = \"DONE\"
    | .phase_history[-1].exited_at = (now | todate)
    | .phase_history[-1].status = \"completed\"
    | .phase_history += [{
        phase: \"DONE\",
        entered_at: (now | todate),
        exited_at: (now | todate),
        status: \"completed\"
      }]
  " >/dev/null
  jq -n --arg fid "$FORGE_ID" '{
    status: "completed",
    next_phase: "DONE",
    skill: "forge-teardown",
    forge_id: $fid,
    idempotent: true
  }'
  exit 0
fi

# ---- 1. Compute fast-estimate cost BEFORE teardown --------------------
# (so we have at least one cost number even if Cost Explorer is rate-limited)

FAST_COST=$(compute_aws_cost_to_date "$FORGE_ID" || echo "0.00")
echo "[teardown] fast-estimate cost so far: \$${FAST_COST}" >&2

# ---- 2. Tear down -----------------------------------------------------

echo "[teardown] $MODE instance $INSTANCE_ID..." >&2
compute_aws_teardown "$INSTANCE_ID" "$MODE"

# Wait for state confirmation (best-effort; not fatal if slow)
echo "[teardown] waiting for instance state confirmation..." >&2
DEADLINE=$(( SECONDS + 180 ))
TARGET_STATE="terminated"
[[ "$MODE" == "stop" ]] && TARGET_STATE="stopped"

while (( SECONDS < DEADLINE )); do
  STATE=$(_compute_aws_cli ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "unknown")
  if [[ "$STATE" == "$TARGET_STATE" ]]; then
    echo "[teardown] instance $INSTANCE_ID state=$STATE ✓" >&2
    break
  fi
  if [[ "$STATE" == "shutting-down" || "$STATE" == "stopping" ]]; then
    echo "[teardown] state=$STATE — waiting..." >&2
  fi
  sleep 10
done

# ---- 3. Cost Explorer reconciliation (best-effort) --------------------
# Cost Explorer typically has 8-24 hour lag for fresh tagged resources,
# so for short-lived smoke runs the fast-estimate is the best we'll have.
# Try CE; fall back to fast-estimate.

RECON_SOURCE="fast-estimate"
RECON_COST="$FAST_COST"

CE_TOTAL=$(_compute_aws_cli ce get-cost-and-usage \
  --time-period "Start=$(date -u -d '2 days ago' +%Y-%m-%d),End=$(date -u +%Y-%m-%d)" \
  --granularity DAILY \
  --metrics UnblendedCost \
  --filter "{\"Tags\":{\"Key\":\"forge-id\",\"Values\":[\"$FORGE_ID\"]}}" \
  --query 'ResultsByTime[].Total.UnblendedCost.Amount' \
  --output text 2>/dev/null | tr '\t' '\n' | awk 'BEGIN{s=0} /^[0-9.eE+-]+$/{s+=$1} END{printf "%.4f", s}')

if [[ -n "$CE_TOTAL" ]] && awk -v v="$CE_TOTAL" 'BEGIN{exit !(v > 0)}'; then
  RECON_SOURCE="aws-cost-explorer"
  RECON_COST="$CE_TOTAL"
  echo "[teardown] Cost Explorer reconciled: \$${RECON_COST}" >&2
else
  echo "[teardown] Cost Explorer returned 0 or stale (lag is 8-24h for new tagged resources) — using fast-estimate \$${FAST_COST}" >&2
fi

# ---- 4. Update manifest ----------------------------------------------

manifest_patch "$FORGE_ID" "
  .cost_tracking.cost_to_date_usd = ${RECON_COST}
  | .cost_tracking.last_reconciled_at = (now | todate)
  | .cost_tracking.reconciliation_source = \"${RECON_SOURCE}\"
  | .cost_tracking.cost_by_phase_usd.TEARDOWN = 0
  | .compute_target = null
  | .phase = \"DONE\"
  | .phase_history[-1].exited_at = (now | todate)
  | .phase_history[-1].status = \"completed\"
  | .phase_history += [{
      phase: \"DONE\",
      entered_at: (now | todate),
      exited_at: (now | todate),
      status: \"completed\"
    }]
" >/dev/null

# ---- 5. Summary -------------------------------------------------------

FINAL=$(manifest_load "$FORGE_ID" 2>/dev/null)
DURATION=""
START_TIME=$(echo "$FINAL" | jq -r '.created_at')
END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START_EPOCH=$(date -u -d "$START_TIME" +%s 2>/dev/null || echo 0)
END_EPOCH=$(date -u -d "$END_TIME" +%s)
DURATION_S=$(( END_EPOCH - START_EPOCH ))
DURATION_M=$(( DURATION_S / 60 ))

echo "" >&2
echo "═══════════════════════════════════════════════════════════════════" >&2
echo "  FORGE COMPLETE" >&2
echo "    forge_id:   $FORGE_ID" >&2
echo "    duration:   ${DURATION_M} min" >&2
echo "    teardown:   $MODE  (instance $INSTANCE_ID)" >&2
echo "    cost:       \$${RECON_COST}  (source: $RECON_SOURCE)" >&2
echo "═══════════════════════════════════════════════════════════════════" >&2

jq -n \
  --arg fid "$FORGE_ID" \
  --arg iid "$INSTANCE_ID" \
  --arg mode "$MODE" \
  --argjson cost "$RECON_COST" \
  --arg src "$RECON_SOURCE" \
  --argjson dur "$DURATION_M" \
  '{
    status: "completed",
    next_phase: "DONE",
    skill: "forge-teardown",
    forge_id: $fid,
    instance_id: $iid,
    teardown_mode: $mode,
    cost_to_date_usd: $cost,
    reconciliation_source: $src,
    duration_minutes: $dur
  }'
