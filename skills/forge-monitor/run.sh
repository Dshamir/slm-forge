#!/usr/bin/env bash
# skills/forge-monitor/run.sh — MONITOR phase implementation.
#
# Single-shot poll. The master dispatcher re-invokes this skill until
# it returns either next_phase=EVAL (training done) or status=failed.
#
# Reads:
#   - manifest.training_runtime.{pid, log_path_remote, log_path_s3,
#                                 started_at}
#   - manifest.compute_target.instance_id
# Writes:
#   - training_runtime heartbeat (last_loss, last_loss_step, last_heartbeat,
#     last_checkpoint_step, last_checkpoint_s3, eta_remaining_minutes)
#   - On completion: artifacts.{final_weights_s3, checkpoints_s3}
#     + phase MONITOR → EVAL.
#
# Decision matrix:
#   alive + no final/      → in-progress (master loops)
#   alive + final present  → training finishing, wait one more
#   dead  + final present  → success; sync final weights, advance to EVAL
#   dead  + no final       → crash; return failed recoverable

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../../lib"

# shellcheck source=../../lib/manifest.sh
source "${LIB}/manifest.sh"
# shellcheck source=../../lib/compute_aws.sh
source "${LIB}/compute_aws.sh"

FORGE_ID="${1:-}"
if [[ -z "$FORGE_ID" ]]; then
  echo "forge-monitor: forge-id required" >&2
  exit 64
fi

MANIFEST=$(manifest_load "$FORGE_ID" 2>/dev/null)
INSTANCE_ID=$(echo "$MANIFEST" | jq -r '.compute_target.instance_id // ""')
PID=$(echo "$MANIFEST"          | jq -r '.training_runtime.pid // ""')
STARTED_AT=$(echo "$MANIFEST"   | jq -r '.training_runtime.started_at // ""')

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "null" ]]; then
  echo "forge-monitor: no compute_target.instance_id" >&2
  exit 1
fi
if [[ -z "$PID" || "$PID" == "null" ]]; then
  echo "forge-monitor: no training_runtime.pid — run forge-train first" >&2
  exit 1
fi

# ---- Liveness probe ---------------------------------------------------

ALIVE=$(compute_aws_exec "$INSTANCE_ID" \
  "kill -0 $PID 2>/dev/null && echo alive || echo dead" \
  2>/dev/null | tr -d '[:space:]' || echo "unknown")

echo "[forge-monitor] pid=$PID state=$ALIVE" >&2

# ---- Log tail + parse loss/step ---------------------------------------

LOG_TAIL=$(compute_aws_exec "$INSTANCE_ID" \
  "tail -200 /workspace/logs/train.log 2>/dev/null" \
  2>/dev/null || echo "")

# HF Trainer prints lines like:
#   {'loss': 1.234, 'grad_norm': 0.5, 'learning_rate': 0.0002, 'epoch': 0.12}
# Sometimes also:
#   {'loss': 1.234, 'learning_rate': 0.0002, 'epoch': 0.12, 'step': 100}
# Trainer's tqdm line: "  5%|▌     | 10/200 [00:12<04:20,  1.37s/it]"
# Our train.py logs: [train.py] starting Trainer.train()... etc.

LAST_LOSS=""
LAST_STEP=""

# Parse last loss value from a Trainer log line
if [[ -n "$LOG_TAIL" ]]; then
  LAST_LOSS=$(echo "$LOG_TAIL" | \
    grep -oE "'(loss|train_loss)':\s*[0-9]+\.[0-9]+" | \
    tail -1 | grep -oE "[0-9]+\.[0-9]+" || true)
  # Extract step from the most recent progress line
  LAST_STEP=$(echo "$LOG_TAIL" | \
    grep -oE "[0-9]+/[0-9]+ \[[0-9:]+<" | \
    tail -1 | grep -oE "^[0-9]+" || true)
  # Alternate: step field in a dict
  if [[ -z "$LAST_STEP" ]]; then
    LAST_STEP=$(echo "$LOG_TAIL" | \
      grep -oE "'step':\s*[0-9]+" | tail -1 | grep -oE "[0-9]+" || true)
  fi
fi

[[ -z "$LAST_LOSS" ]] && LAST_LOSS="null"
[[ -z "$LAST_STEP" ]] && LAST_STEP="null"

echo "[forge-monitor] loss=$LAST_LOSS step=$LAST_STEP" >&2

# ---- 60s health check (catches silent OOM / hang) --------------------
# If the training PID has been alive for >60s but produced NO loss line and
# NO step counter advance, something is wrong (typical pattern: PEFT +
# grad_ckpt without enable_input_require_grads — model loaded, GPU alloc'd,
# 0% util, no exception, just hangs forever).
#
# We hard-fail here rather than let monitor poll forever.
HEALTH_CHECK_DEADLINE_SEC="${FORGE_MONITOR_HEALTH_DEADLINE:-60}"
if [[ "$ALIVE" == "alive" && -n "$STARTED_AT" && "$LAST_LOSS" == "null" && "$LAST_STEP" == "null" ]]; then
  # How long has training been alive?
  STARTED_EPOCH=$(date -d "$STARTED_AT" +%s 2>/dev/null || echo 0)
  NOW_EPOCH=$(date +%s)
  ALIVE_SEC=$((NOW_EPOCH - STARTED_EPOCH))
  if (( ALIVE_SEC > HEALTH_CHECK_DEADLINE_SEC )); then
    echo "[forge-monitor] HEALTH FAIL: PID alive ${ALIVE_SEC}s with no loss/step output" >&2
    echo "[forge-monitor] killing PID $PID — likely silent OOM or PEFT+grad_ckpt hang" >&2
    compute_aws_exec "$INSTANCE_ID" "kill -9 $PID 2>/dev/null; pkill -9 -f train.py 2>/dev/null; true" >/dev/null 2>&1 || true

    manifest_patch "$FORGE_ID" "
      .errors += [{
        skill: \"forge-monitor\",
        phase: \"MONITOR\",
        timestamp: (now | todate),
        error_type: \"training_started_but_silent\",
        message: \"Training PID alive ${ALIVE_SEC}s with no loss/step output — killed.\",
        recoverable: true,
        recovery_hint: \"Likely PEFT+grad_ckpt without enable_input_require_grads(), CUDA OOM at first forward, or Unsloth segfault on this base+regime combo. Check /workspace/logs/train.log for the last line; usually 0%|...|0/N just before death.\"
      }]
    " >/dev/null

    jq -n --arg fid "$FORGE_ID" '{
      status: "failed",
      next_phase: "MONITOR",
      skill: "forge-monitor",
      forge_id: $fid,
      error: "training_started_but_silent",
      recoverable: true
    }'
    exit 1
  fi
fi

# ---- Check for final weights marker -----------------------------------

FINAL_PRESENT=$(compute_aws_exec "$INSTANCE_ID" \
  "test -d /workspace/checkpoints/final && ls /workspace/checkpoints/final/*.safetensors 2>/dev/null | head -1 | grep -q . && echo yes || echo no" \
  2>/dev/null | tr -d '[:space:]' || echo "no")

echo "[forge-monitor] final_weights_present=$FINAL_PRESENT" >&2

# ---- Checkpoint discovery (for heartbeat metadata) --------------------

HIGHEST_CKPT=$(compute_aws_exec "$INSTANCE_ID" \
  "ls -d /workspace/checkpoints/checkpoint-* 2>/dev/null | sed 's#.*checkpoint-##' | sort -n | tail -1" \
  2>/dev/null | tr -d '[:space:]' || echo "")

[[ -z "$HIGHEST_CKPT" || ! "$HIGHEST_CKPT" =~ ^[0-9]+$ ]] && HIGHEST_CKPT="null"

# ---- ETA computation --------------------------------------------------

ETA="null"
if [[ "$LAST_STEP" != "null" && "$STARTED_AT" != "null" && "$STARTED_AT" != "" ]]; then
  # Extract max_steps from the config (stored in training_runtime)
  MAX_STEPS=$(compute_aws_exec "$INSTANCE_ID" \
    "grep -oE 'max_steps:\s*[0-9]+' /workspace/training/config.yaml 2>/dev/null | grep -oE '[0-9]+'" \
    2>/dev/null | tr -d '[:space:]' || echo "")
  if [[ -n "$MAX_STEPS" && "$MAX_STEPS" =~ ^[0-9]+$ && "$MAX_STEPS" -gt 0 ]]; then
    STARTED_EPOCH=$(date -u -d "$STARTED_AT" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date -u +%s)
    ELAPSED_MIN=$(awk -v s="$STARTED_EPOCH" -v n="$NOW_EPOCH" 'BEGIN{printf "%.2f", (n-s)/60}')
    if (( LAST_STEP > 0 )); then
      ETA=$(awk -v el="$ELAPSED_MIN" -v st="$LAST_STEP" -v max="$MAX_STEPS" \
        'BEGIN{printf "%.1f", (max-st) * (el/st) * 1.10}')
    fi
  fi
fi

# ---- Heartbeat write --------------------------------------------------

manifest_patch "$FORGE_ID" "
  .training_runtime.last_heartbeat = (now | todate)
  | .training_runtime.last_loss = $LAST_LOSS
  | .training_runtime.last_loss_step = $LAST_STEP
  | .training_runtime.last_checkpoint_step = $HIGHEST_CKPT
  | .training_runtime.eta_remaining_minutes = $ETA
" >/dev/null

# ---- Decision matrix -------------------------------------------------

if [[ "$ALIVE" == "alive" && "$FINAL_PRESENT" == "no" ]]; then
  # Still training
  jq -n \
    --arg fid "$FORGE_ID" \
    --arg loss "$LAST_LOSS" \
    --arg step "$LAST_STEP" \
    --arg eta "$ETA" \
    '{
      status: "in-progress",
      next_phase: "MONITOR",
      skill: "forge-monitor",
      forge_id: $fid,
      heartbeat: {
        loss: $loss,
        step: $step,
        eta_minutes: $eta
      }
    }'
  exit 0
fi

if [[ "$ALIVE" == "alive" && "$FINAL_PRESENT" == "yes" ]]; then
  # Training is saving final; one more poll cycle
  echo "[forge-monitor] final weights present but PID still alive (saving); wait one more cycle" >&2
  jq -n --arg fid "$FORGE_ID" '{
    status: "in-progress",
    next_phase: "MONITOR",
    skill: "forge-monitor",
    forge_id: $fid,
    heartbeat: { note: "saving final checkpoint" }
  }'
  exit 0
fi

if [[ "$ALIVE" == "dead" && "$FINAL_PRESENT" == "yes" ]]; then
  # Success path — sync final weights to S3, advance
  echo "[forge-monitor] ✓ training completed — syncing final weights to S3..." >&2
  compute_aws_exec "$INSTANCE_ID" \
    "aws s3 sync /workspace/checkpoints/final/ s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/weights/final/ --region ${FORGE_REGION}" \
    >/dev/null
  # Also sync intermediate checkpoints for resume-from-older if needed later
  compute_aws_exec "$INSTANCE_ID" \
    "aws s3 sync /workspace/checkpoints/ s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/checkpoints/ --region ${FORGE_REGION} --exclude 'final/*'" \
    >/dev/null 2>&1 || true
  # Final log flush
  compute_aws_exec "$INSTANCE_ID" \
    "aws s3 cp /workspace/logs/train.log s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/logs/train.log --region ${FORGE_REGION}" \
    >/dev/null || true
  # Kill the log-sync side process (it's no longer needed)
  compute_aws_exec "$INSTANCE_ID" \
    "pkill -f 'forge-log-sync' 2>/dev/null || true; rm -f /workspace/.forge-log-sync.pid" \
    >/dev/null 2>&1 || true

  FINAL_URI="s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/weights/final/"
  CKPTS_URI="s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/checkpoints/"

  manifest_patch "$FORGE_ID" "
    .artifacts.final_weights_s3 = \"${FINAL_URI}\"
    | .artifacts.checkpoints_s3 = \"${CKPTS_URI}\"
    | .phase = \"EVAL\"
    | .phase_history[-1].exited_at = (now | todate)
    | .phase_history[-1].status = \"completed\"
    | .phase_history += [{
        phase: \"EVAL\",
        entered_at: (now | todate),
        exited_at: null,
        status: \"pending\"
      }]
  " >/dev/null

  jq -n \
    --arg fid "$FORGE_ID" \
    --arg final "$FINAL_URI" \
    '{
      status: "completed",
      next_phase: "EVAL",
      skill: "forge-monitor",
      forge_id: $fid,
      final_weights_s3: $final
    }'
  exit 0
fi

# Remaining case: dead + no final = crash
echo "[forge-monitor] ✗ training died without producing final weights" >&2
# Pull last 50 log lines for diagnostic
LAST_LINES=$(compute_aws_exec "$INSTANCE_ID" "tail -50 /workspace/logs/train.log 2>/dev/null" 2>/dev/null || echo "(unreadable)")
echo "$LAST_LINES" | tail -20 >&2

# Detect common failure signatures for hint
HINT="forge-resume from last checkpoint"
if echo "$LAST_LINES" | grep -qi "OOM\|CUDA out of memory\|OutOfMemoryError"; then
  HINT="OOM during training — reduce per_device_train_batch_size in plan or resume with smaller batch"
elif echo "$LAST_LINES" | grep -qi "Traceback\|Error"; then
  HINT="python exception in train.py — inspect s3://.../logs/train.log"
elif echo "$LAST_LINES" | grep -qi "killed\|SIGTERM\|SIGKILL"; then
  HINT="process killed (likely system OOM-killer or manual) — re-provision with bigger instance or resume"
fi

# Always sync the log so the user can read it
compute_aws_exec "$INSTANCE_ID" \
  "aws s3 cp /workspace/logs/train.log s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/logs/train.log --region ${FORGE_REGION}" \
  >/dev/null 2>&1 || true

manifest_patch "$FORGE_ID" "
  .errors += [{
    skill: \"forge-monitor\",
    phase: \"MONITOR\",
    timestamp: (now | todate),
    error_type: \"training_crash\",
    message: \"training PID died without final weights\",
    recoverable: true,
    recovery_hint: \"${HINT}\"
  }]
" >/dev/null

jq -n \
  --arg fid "$FORGE_ID" \
  --arg hint "$HINT" \
  '{
    status: "failed",
    next_phase: "MONITOR",
    skill: "forge-monitor",
    forge_id: $fid,
    recoverable: true,
    error: "training crashed without producing final weights",
    recovery_hint: $hint
  }'
exit 1
