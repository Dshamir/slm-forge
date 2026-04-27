#!/usr/bin/env bash
# skills/forge-resume/run.sh — recovery skill (NOT a phase).
#
# Re-enters a forge after Claude CLI session loss, EC2 spot interruption,
# or training crash. Detects instance state, picks the right recovery
# path, restarts training from last checkpoint.
#
# State matrix (per skills/forge-resume/DESIGN.md):
#   A  alive + SSM Online  → re-attach; if PID dead, restart training
#   B  stopped + EBS intact → start-instances + restart training
#   C  terminated / not-found → re-provision + re-bootstrap + restore + restart
#   D  snapshot present → not implemented yet (M6+ hardening)
#
# Usage:
#   run.sh <forge-id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../../lib"
SKILLS="${SCRIPT_DIR}/.."

# shellcheck source=../../lib/manifest.sh
source "${LIB}/manifest.sh"
# shellcheck source=../../lib/compute_aws.sh
source "${LIB}/compute_aws.sh"

FORGE_ID="${1:-}"
if [[ -z "$FORGE_ID" ]]; then
  echo "forge-resume: forge-id required" >&2
  exit 64
fi

MANIFEST=$(manifest_load "$FORGE_ID" 2>/dev/null)
INSTANCE_ID=$(echo "$MANIFEST"     | jq -r '.compute_target.instance_id // ""')
PID=$(echo "$MANIFEST"             | jq -r '.training_runtime.pid // ""')
LAST_CKPT_S3=$(echo "$MANIFEST"    | jq -r '.training_runtime.last_checkpoint_s3 // ""')
LAST_CKPT_STEP=$(echo "$MANIFEST"  | jq -r '.training_runtime.last_checkpoint_step // ""')
COST_TO_DATE=$(echo "$MANIFEST"    | jq -r '.cost_tracking.cost_to_date_usd // 0')
BUDGET_CAP=$(echo "$MANIFEST"      | jq -r '.spec.constraints.budget_cap_usd // 100')

# ---- Detect state ----------------------------------------------------

STATE="C"
if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "null" ]]; then
  EC2_STATE=$(_compute_aws_cli ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "not-found")
  case "$EC2_STATE" in
    running)
      # Check SSM
      SSM=$(_compute_aws_cli ssm describe-instance-information \
        --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
        --query 'InstanceInformationList[0].PingStatus' \
        --output text 2>/dev/null || echo "")
      [[ "$SSM" == "Online" ]] && STATE="A" || STATE="A-no-ssm"
      ;;
    stopped)
      STATE="B"
      ;;
    terminated|not-found|None|"")
      STATE="C"
      ;;
    *)
      STATE="wait"
      ;;
  esac
fi

echo "[forge-resume] state=$STATE  instance=$INSTANCE_ID  ec2_state=${EC2_STATE:-(none)}" >&2

# ---- restart_training_subprocedure -----------------------------------

# Used by states A-dead, B, C. Patches resume.from_checkpoint into the
# config and re-launches via forge-train (which is itself idempotent).
restart_training() {
  local resume_from="$1"   # path on instance to checkpoint dir, or empty

  echo "[forge-resume] restart_training: resume_from='${resume_from:-fresh}'" >&2

  # Pull the existing config from S3 (saved by forge-train)
  local cfg_uri="s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/training/config.yaml"
  local local_cfg="/tmp/.forge-resume-config-$$.yaml"
  if ! _forge_aws_mount /tmp s3api get-object \
       --bucket "$FORGE_BUCKET" \
       --key "${FORGE_PREFIX}/${FORGE_ID}/training/config.yaml" \
       "/work/.forge-resume-config-$$.yaml" >/dev/null 2>&1; then
    echo "[forge-resume] WARN: no saved config in S3; rerunning forge-train fresh" >&2
    bash "${SKILLS}/forge-train/run.sh" "$FORGE_ID"
    return $?
  fi

  # Patch resume.from_checkpoint
  if [[ -n "$resume_from" ]]; then
    sed -i "s#^resume:.*#resume:\\n  from_checkpoint: ${resume_from}#" "$local_cfg" 2>/dev/null || true
    # Simpler: just append override at the end (last definition wins in YAML)
    cat >> "$local_cfg" <<EOF

resume:
  from_checkpoint: ${resume_from}
EOF
  fi

  # Re-upload to instance
  _forge_aws_mount /tmp s3api put-object \
    --bucket "$FORGE_BUCKET" \
    --key "${FORGE_PREFIX}/${FORGE_ID}/training/config.yaml" \
    --body "/work/.forge-resume-config-$$.yaml" >/dev/null
  rm -f "$local_cfg"

  compute_aws_exec "$INSTANCE_ID" \
    "aws s3 cp s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/training/config.yaml /workspace/training/config.yaml --region ${FORGE_REGION}" \
    >/dev/null

  # Clear training_runtime.pid so forge-train doesn't think there's a live PID
  manifest_patch "$FORGE_ID" '.training_runtime.pid = null' >/dev/null

  # Move phase back to TRAIN so forge-train will run
  manifest_patch "$FORGE_ID" '.phase = "TRAIN"' >/dev/null

  # Delegate to forge-train (idempotent)
  bash "${SKILLS}/forge-train/run.sh" "$FORGE_ID"
}

# ---- Per-state recovery ---------------------------------------------

case "$STATE" in

  A)
    # Alive + SSM. Check if training PID is still kicking.
    if [[ -n "$PID" && "$PID" != "null" ]]; then
      ALIVE=$(compute_aws_exec "$INSTANCE_ID" \
        "kill -0 $PID 2>/dev/null && echo alive || echo dead" \
        2>/dev/null | tr -d '[:space:]' || echo "unknown")
      if [[ "$ALIVE" == "alive" ]]; then
        echo "[forge-resume] state=A  PID=$PID alive — no action needed; advancing to MONITOR" >&2
        manifest_patch "$FORGE_ID" "
          .notes += [{ by: \"forge-resume\", at: (now | todate), text: \"session resumed; training was already running on PID ${PID}\" }]
          | .phase = \"MONITOR\"
        " >/dev/null

        jq -n --arg fid "$FORGE_ID" --arg pid "$PID" '{
          status: "completed",
          next_phase: "MONITOR",
          skill: "forge-resume",
          forge_id: $fid,
          resume_state: "A",
          new_pid: ($pid | tonumber),
          note: "training was already alive; no restart"
        }'
        exit 0
      fi
    fi
    # PID dead: restart training. Look for the latest checkpoint on the
    # instance so we don't restart from step 0.
    LATEST_CKPT=$(compute_aws_exec "$INSTANCE_ID" \
      "ls -d /workspace/checkpoints/checkpoint-* 2>/dev/null | sort -V | tail -1" \
      2>/dev/null | tr -d '[:space:]' || echo "")
    restart_training "$LATEST_CKPT"
    EXIT_CODE=$?
    ;;

  A-no-ssm)
    # Alive but SSM down. Wait + re-check rather than re-provision.
    echo "[forge-resume] state=A but SSM offline; sleeping 60 s + recursing" >&2
    sleep 60
    bash "$0" "$FORGE_ID"
    exit $?
    ;;

  B)
    echo "[forge-resume] state=B (stopped) — starting instance..." >&2
    _compute_aws_cli ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
    # Wait for running + SSM Online (reuses the wait pattern from compute_aws_provision)
    DEADLINE=$(( SECONDS + 300 ))
    while (( SECONDS < DEADLINE )); do
      sleep 10
      EC2_STATE=$(_compute_aws_cli ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)
      SSM=$(_compute_aws_cli ssm describe-instance-information \
        --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
        --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "")
      [[ "$EC2_STATE" == "running" && "$SSM" == "Online" ]] && break
    done
    if [[ "$EC2_STATE" != "running" || "$SSM" != "Online" ]]; then
      echo "[forge-resume] FAILED: instance did not return to running+SSM-online" >&2
      exit 1
    fi
    # Update launch_time (cost reset)
    manifest_patch "$FORGE_ID" "
      .compute_target.ec2_launch_time = (now | todate)
      | .notes += [{ by: \"forge-resume\", at: (now | todate), text: \"resumed from stopped instance\" }]
    " >/dev/null
    LATEST_CKPT=$(compute_aws_exec "$INSTANCE_ID" \
      "ls -d /workspace/checkpoints/checkpoint-* 2>/dev/null | sort -V | tail -1" \
      2>/dev/null | tr -d '[:space:]' || echo "")
    restart_training "$LATEST_CKPT"
    EXIT_CODE=$?
    ;;

  C)
    # Cost-gate before re-provision
    PROVISION_COST_EST=$(echo "$MANIFEST" | jq -r '.estimate.estimated_compute_cost_usd // 5')
    PROJECTED=$(awk -v c="$COST_TO_DATE" -v p="$PROVISION_COST_EST" 'BEGIN{printf "%.2f", c+p}')
    if awk -v p="$PROJECTED" -v b="$BUDGET_CAP" 'BEGIN{exit !(p > b)}'; then
      echo "[forge-resume] cost-gate: projected \$${PROJECTED} > budget cap \$${BUDGET_CAP} — refusing re-provision" >&2
      jq -n --arg fid "$FORGE_ID" '{
        status: "failed",
        next_phase: "TEARDOWN",
        skill: "forge-resume",
        forge_id: $fid,
        recoverable: false,
        error: "would exceed budget on re-provision",
        recovery_hint: "raise spec.constraints.budget_cap_usd or invoke /slm-forge abort"
      }'
      exit 1
    fi

    # No checkpoint in S3 = lost training
    if [[ -z "$LAST_CKPT_S3" || "$LAST_CKPT_S3" == "null" ]]; then
      echo "[forge-resume] state=C and no S3 checkpoint — training lost; restart from PROVISION" >&2
      jq -n --arg fid "$FORGE_ID" '{
        status: "failed",
        next_phase: "PROVISION",
        skill: "forge-resume",
        forge_id: $fid,
        recoverable: false,
        error: "instance terminated and no checkpoint synced — must restart fresh from PROVISION",
        recovery_hint: "consider amending plan to checkpoint earlier (smaller save_steps)"
      }'
      exit 1
    fi

    echo "[forge-resume] state=C — re-provisioning + re-bootstrapping + restoring checkpoint..." >&2
    # Clear stale compute_target so forge-provision will run fresh
    manifest_patch "$FORGE_ID" '
      .compute_target = null
      | .training_runtime = null
      | .phase = "PROVISION"
    ' >/dev/null

    # Re-provision
    bash "${SKILLS}/forge-provision/run.sh" "$FORGE_ID" || {
      echo "[forge-resume] forge-provision failed during state-C recovery" >&2
      exit 1
    }
    # Re-bootstrap
    bash "${SKILLS}/forge-bootstrap/run.sh" "$FORGE_ID" || {
      echo "[forge-resume] forge-bootstrap failed during state-C recovery" >&2
      exit 1
    }

    # Re-load manifest to get the new instance_id
    MANIFEST=$(manifest_load "$FORGE_ID" 2>/dev/null)
    INSTANCE_ID=$(echo "$MANIFEST" | jq -r '.compute_target.instance_id')

    # Restore checkpoint from S3 to the new instance
    echo "[forge-resume] restoring checkpoint from $LAST_CKPT_S3..." >&2
    compute_aws_exec "$INSTANCE_ID" \
      "mkdir -p /workspace/checkpoints/latest && aws s3 sync ${LAST_CKPT_S3} /workspace/checkpoints/latest/ --region ${FORGE_REGION}" \
      >/dev/null

    manifest_patch "$FORGE_ID" "
      .notes += [{ by: \"forge-resume\", at: (now | todate), text: \"state-C recovery complete; restored checkpoint from ${LAST_CKPT_S3}\" }]
    " >/dev/null

    restart_training "/workspace/checkpoints/latest"
    EXIT_CODE=$?
    ;;

  wait)
    echo "[forge-resume] instance in transitional state (pending|stopping); sleeping 30 s + recursing" >&2
    sleep 30
    bash "$0" "$FORGE_ID"
    exit $?
    ;;

  *)
    echo "[forge-resume] unknown state '$STATE'" >&2
    exit 1
    ;;
esac

# Pass through forge-train's exit
exit ${EXIT_CODE:-0}
