#!/usr/bin/env bash
# skills/forge-provision/run.sh — PROVISION phase implementation.
#
# Reads:
#   - manifest.estimate.instance_type (from forge-estimate)
#   - manifest.spec.constraints.* (for envelope checks)
# Writes:
#   - manifest.compute_target.* (provider, region, instance_id,
#     instance_type, ami_id, ec2_launch_time, cost_per_hour_usd,
#     auth_method, launched_by, workdir, persistent_volume_path)
#   - Advances phase to BOOTSTRAP.
#
# Dispatches through lib/compute_aws.sh which handles the actual
# RunInstances call + SSM wait.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../../lib"
CONFIG="${SCRIPT_DIR}/../../config"

# shellcheck source=../../lib/manifest.sh
source "${LIB}/manifest.sh"
# shellcheck source=../../lib/compute_aws.sh
source "${LIB}/compute_aws.sh"

FORGE_ID="${1:-}"
if [[ -z "$FORGE_ID" ]]; then
  echo "forge-provision: forge-id required" >&2
  exit 64
fi

MANIFEST=$(manifest_load "$FORGE_ID" 2>/dev/null)
INSTANCE_TYPE=$(echo "$MANIFEST" | jq -r '.estimate.instance_type // "g5.xlarge"')

# Smoke-test override: lets the M3 lifecycle smoke run on t3.micro when
# the G/VT vCPU quota is saturated. Skip in production.
if [[ -n "${FORGE_INSTANCE_TYPE_OVERRIDE:-}" ]]; then
  echo "[forge-provision] FORGE_INSTANCE_TYPE_OVERRIDE=${FORGE_INSTANCE_TYPE_OVERRIDE} (was ${INSTANCE_TYPE})" >&2
  INSTANCE_TYPE="$FORGE_INSTANCE_TYPE_OVERRIDE"
fi
BUDGET_CAP=$(echo "$MANIFEST" | jq -r '.spec.constraints.budget_cap_usd // 100')
COST_TO_DATE=$(echo "$MANIFEST" | jq -r '.cost_tracking.cost_to_date_usd // 0')
ESTIMATED_PHASE_COST=$(echo "$MANIFEST" | jq -r '.estimate.estimated_compute_cost_usd // 0')

# ---- Cost gate (D-017) -------------------------------------------------
# Every phase that incurs cost verifies cost_to_date + estimated_phase_cost
# <= budget_cap. Refuse to launch if we'd blow the budget.
PROJECTED=$(awk -v c="$COST_TO_DATE" -v p="$ESTIMATED_PHASE_COST" 'BEGIN{printf "%.2f", c+p}')
if awk -v p="$PROJECTED" -v b="$BUDGET_CAP" 'BEGIN{exit !(p > b)}'; then
  echo "forge-provision: projected cost \$${PROJECTED} > budget cap \$${BUDGET_CAP} — refusing launch" >&2
  exit 1
fi

# ---- Idempotency: skip if instance already live -----------------------
EXISTING_INSTANCE=$(echo "$MANIFEST" | jq -r '.compute_target.instance_id // ""')
if [[ -n "$EXISTING_INSTANCE" && "$EXISTING_INSTANCE" != "null" ]]; then
  # Verify the instance is still reachable; if so, skip.
  if compute_aws_reattach "$EXISTING_INSTANCE" 2>/dev/null; then
    echo "forge-provision: instance $EXISTING_INSTANCE already live + SSM online; skipping" >&2
    jq -n --arg fid "$FORGE_ID" --arg iid "$EXISTING_INSTANCE" '{
      status: "completed",
      next_phase: "BOOTSTRAP",
      skill: "forge-provision",
      forge_id: $fid,
      instance_id: $iid,
      idempotent: true
    }'
    exit 0
  else
    echo "forge-provision: previous instance $EXISTING_INSTANCE not reachable — will re-provision" >&2
  fi
fi

# ---- Launch ------------------------------------------------------------
SPEC=$(jq -n \
  --arg it "$INSTANCE_TYPE" \
  --arg fid "$FORGE_ID" \
  --arg ebs "${FORGE_DEFAULT_EBS_GB:-200}" \
  --arg ami "${FORGE_DEFAULT_AMI}" \
  '{instance_type: $it, forge_id: $fid, ebs_gb: ($ebs|tonumber), ami_id: $ami}')

echo "[forge-provision] launching $INSTANCE_TYPE (ami=$FORGE_DEFAULT_AMI) for forge $FORGE_ID..." >&2
PROVISION_RESULT=$(compute_aws_provision "$SPEC")

INSTANCE_ID=$(echo "$PROVISION_RESULT" | jq -r .instance_id)
LAUNCH_TIME=$(echo "$PROVISION_RESULT" | jq -r .ec2_launch_time)
AMI_ID=$(echo "$PROVISION_RESULT" | jq -r .ami_id)
SUBNET_ID=$(echo "$PROVISION_RESULT" | jq -r .subnet_id)
SG_IDS=$(echo "$PROVISION_RESULT" | jq -c .security_group_ids)

# Look up cost_per_hour from pricing snapshot
PRICING="${CONFIG}/pricing.json"
COST_PER_HOUR=$(jq -r --arg it "$INSTANCE_TYPE" \
  '.ec2_on_demand[$it].rate_usd_hr // 1.212' "$PRICING")

manifest_patch "$FORGE_ID" "
  .compute_target = {
    provider: \"aws\",
    region: \"${FORGE_REGION}\",
    instance_type: \"${INSTANCE_TYPE}\",
    instance_id: \"${INSTANCE_ID}\",
    ssm_target_id: \"${INSTANCE_ID}\",
    ec2_launch_time: \"${LAUNCH_TIME}\",
    ami_id: \"${AMI_ID}\",
    subnet_id: \"${SUBNET_ID}\",
    security_group_ids: ${SG_IDS},
    workdir: \"/workspace\",
    persistent_volume_path: \"/workspace\",
    ebs_volume_id: null,
    auth_method: \"ssm\",
    cost_per_hour_usd: ${COST_PER_HOUR},
    launched_by: \"forge-provision@v1\",
    bootstrap_completed: false
  }
  | .phase = \"BOOTSTRAP\"
  | .phase_history[-1].exited_at = (now | todate)
  | .phase_history[-1].status = \"completed\"
  | .phase_history += [{
      phase: \"BOOTSTRAP\",
      entered_at: (now | todate),
      exited_at: null,
      status: \"in-progress\"
    }]
" >/dev/null

jq -n \
  --arg fid "$FORGE_ID" \
  --arg iid "$INSTANCE_ID" \
  --arg it "$INSTANCE_TYPE" \
  --arg ami "$AMI_ID" \
  --arg lt "$LAUNCH_TIME" \
  --argjson rate "$COST_PER_HOUR" \
  '{
    status: "completed",
    next_phase: "BOOTSTRAP",
    skill: "forge-provision",
    forge_id: $fid,
    instance_id: $iid,
    instance_type: $it,
    ami_id: $ami,
    ec2_launch_time: $lt,
    cost_per_hour_usd: $rate
  }'
