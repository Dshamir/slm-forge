#!/usr/bin/env bash
# skills/forge-train/run.sh — TRAIN phase implementation.
#
# Reads:
#   - manifest.plan.* (base_model, training_regime, target_params,
#                      training_framework, chat_template, tokenizer_strategy)
#   - manifest.artifacts.shaped_corpus_s3
#   - manifest.compute_target.{instance_id, workdir}
# Writes:
#   - manifest.training_runtime.* (pid, log_path_*, config_yaml_s3, framework, started_at)
#   - Advances phase to MONITOR.
#
# Launch strategy: config YAML generated locally, uploaded via S3 + SSM
# pull on instance. train.py launched detached via `setsid` (dodges the
# M3 dash/disown lesson — nohup+disown doesn't survive AWS-RunShellScript's
# dash shell). PID captured. Log-sync side process rsyncs
# /workspace/logs/train.log → S3 every 30 s.
#
# Smoke-friendly env overrides:
#   FORGE_TRAIN_MAX_STEPS       override training.max_steps in config
#   FORGE_TRAIN_BATCH_SIZE      override per_device_train_batch_size
#   FORGE_TRAIN_MAX_SEQ_LEN     override data.max_seq_len
#   FORGE_TRAIN_LOGGING_STEPS   override training.logging_steps
#   FORGE_TRAIN_SAVE_STEPS      override training.save_steps

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../../lib"
SCRIPTS="${SCRIPT_DIR}/../../scripts"

# shellcheck source=../../lib/manifest.sh
source "${LIB}/manifest.sh"
# shellcheck source=../../lib/compute_aws.sh
source "${LIB}/compute_aws.sh"
# shellcheck source=../../lib/s3.sh
source "${LIB}/s3.sh"

FORGE_ID="${1:-}"
if [[ -z "$FORGE_ID" ]]; then
  echo "forge-train: forge-id required" >&2
  exit 64
fi

MANIFEST=$(manifest_load "$FORGE_ID" 2>/dev/null)
INSTANCE_ID=$(echo "$MANIFEST" | jq -r '.compute_target.instance_id // ""')
BOOTSTRAP_DONE=$(echo "$MANIFEST" | jq -r '.compute_target.bootstrap_completed // false')
SHAPED_URI=$(echo "$MANIFEST" | jq -r '.artifacts.shaped_corpus_s3 // ""')

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "null" ]]; then
  echo "forge-train: no compute_target.instance_id" >&2
  exit 1
fi
if [[ "$BOOTSTRAP_DONE" != "true" ]]; then
  echo "forge-train: bootstrap not complete" >&2
  exit 1
fi
if [[ -z "$SHAPED_URI" || "$SHAPED_URI" == "null" ]]; then
  echo "forge-train: shaped_corpus_s3 not populated" >&2
  exit 1
fi

# ---- Idempotency -------------------------------------------------------

EXISTING_PID=$(echo "$MANIFEST" | jq -r '.training_runtime.pid // ""')
if [[ -n "$EXISTING_PID" && "$EXISTING_PID" != "null" ]]; then
  # Check if PID is still alive on instance
  ALIVE=$(compute_aws_exec "$INSTANCE_ID" \
    "kill -0 $EXISTING_PID 2>/dev/null && echo alive || echo dead" \
    2>/dev/null | tr -d '[:space:]' || echo "unknown")
  if [[ "$ALIVE" == "alive" ]]; then
    echo "forge-train: training PID $EXISTING_PID already alive; skipping re-launch" >&2
    jq -n --arg fid "$FORGE_ID" --arg pid "$EXISTING_PID" '{
      status: "completed",
      next_phase: "MONITOR",
      skill: "forge-train",
      forge_id: $fid,
      pid: ($pid | tonumber),
      idempotent: true
    }'
    exit 0
  fi
fi

# ---- Extract plan fields ----------------------------------------------

BASE_MODEL=$(echo "$MANIFEST"    | jq -r '.plan.base_model')
REGIME=$(echo "$MANIFEST"        | jq -r '.plan.training_regime')
TARGET_PARAMS=$(echo "$MANIFEST" | jq -r '.plan.target_params')
FRAMEWORK=$(echo "$MANIFEST"     | jq -r '.plan.training_framework')
CHAT_TEMPLATE=$(echo "$MANIFEST" | jq -r '.plan.chat_template')
TOK_STRATEGY=$(echo "$MANIFEST"  | jq -r '.plan.tokenizer_strategy')
TRUST_REMOTE=$(echo "$MANIFEST"  | jq -r '.plan.trust_remote_code // false')

# ---- Training hyperparameter defaults + plan.json + env overrides -----
#
# Resolution order (later wins):
#   1. Hardcoded v1 defaults (batch=4, seq=1024, steps=500, etc.)
#   2. plan.json training_overrides (v2 path — dispatcher passes run-id
#      that points at a run dir containing plan.json)
#   3. Env var overrides (always wins — for ad-hoc operator tweaks)
#
# FORGE_ID may be either a legacy forge-id (used by v1 manifest) OR a v2
# run-id pointing at slm-forge/.runs/<run-id>/plan.json.

# Start with hardcoded defaults
P_MAX_STEPS=500
P_BATCH_SIZE=4
P_MAX_SEQ_LEN=1024
P_GRAD_ACCUM=1
P_LR="2e-4"
P_EPOCHS=1
P_LORA_R=8
P_LORA_ALPHA=16
P_GRAD_CKPT=false

# Layer 2: plan.json from v2 run dir. Strip v2- prefix the bridge adds
# so the forge_id "v2-<run-id>" resolves to the on-disk .runs/<run-id>/.
RUN_ID_LOCAL="${FORGE_ID#v2-}"
PLAN_FILE="${SCRIPT_DIR}/../../.runs/${RUN_ID_LOCAL}/plan.json"
if [[ -f "$PLAN_FILE" ]]; then
  echo "[forge-train] merging training_overrides from $PLAN_FILE" >&2
  P_MAX_STEPS=$(jq -r ".training_overrides.max_steps // $P_MAX_STEPS" "$PLAN_FILE")
  P_BATCH_SIZE=$(jq -r ".training_overrides.batch_size // $P_BATCH_SIZE" "$PLAN_FILE")
  P_MAX_SEQ_LEN=$(jq -r ".training_overrides.max_seq_len // $P_MAX_SEQ_LEN" "$PLAN_FILE")
  P_GRAD_ACCUM=$(jq -r ".training_overrides.grad_accum // $P_GRAD_ACCUM" "$PLAN_FILE")
  P_LR=$(jq -r ".training_overrides.learning_rate // \"$P_LR\"" "$PLAN_FILE")
  P_EPOCHS=$(jq -r ".training_overrides.epochs // $P_EPOCHS" "$PLAN_FILE")
  P_LORA_R=$(jq -r ".training_overrides.lora_r // $P_LORA_R" "$PLAN_FILE")
  P_LORA_ALPHA=$(jq -r ".training_overrides.lora_alpha // $P_LORA_ALPHA" "$PLAN_FILE")
  P_GRAD_CKPT=$(jq -r ".training_overrides.grad_ckpt // $P_GRAD_CKPT" "$PLAN_FILE")
fi

# Layer 3: env overrides
MAX_STEPS="${FORGE_TRAIN_MAX_STEPS:-$P_MAX_STEPS}"
BATCH_SIZE="${FORGE_TRAIN_BATCH_SIZE:-$P_BATCH_SIZE}"
MAX_SEQ_LEN="${FORGE_TRAIN_MAX_SEQ_LEN:-$P_MAX_SEQ_LEN}"
LOGGING_STEPS="${FORGE_TRAIN_LOGGING_STEPS:-10}"
SAVE_STEPS="${FORGE_TRAIN_SAVE_STEPS:-100}"
GRAD_ACCUM="${FORGE_TRAIN_GRAD_ACCUM:-$P_GRAD_ACCUM}"
LR="${FORGE_TRAIN_LR:-$P_LR}"
EPOCHS="${FORGE_TRAIN_EPOCHS:-$P_EPOCHS}"
LORA_R="${FORGE_TRAIN_LORA_R:-$P_LORA_R}"
LORA_ALPHA="${FORGE_TRAIN_LORA_ALPHA:-$P_LORA_ALPHA}"
GRAD_CKPT="${FORGE_TRAIN_GRAD_CKPT:-$P_GRAD_CKPT}"

echo "[forge-train] resolved: steps=$MAX_STEPS batch=$BATCH_SIZE×$GRAD_ACCUM seq=$MAX_SEQ_LEN lr=$LR lora_r=$LORA_R grad_ckpt=$GRAD_CKPT" >&2

# ---- Generate training config YAML ------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

CONFIG_FILE="$WORK/config.yaml"
cat > "$CONFIG_FILE" <<YAML
forge_id: ${FORGE_ID}
schema_version: "1.0.0"

base_model:
  hf_repo: ${BASE_MODEL}
  trust_remote_code: ${TRUST_REMOTE}

regime:
  type: ${REGIME}
  lora:
    r: ${LORA_R}
    alpha: ${LORA_ALPHA}
    dropout: 0.05
    target_modules: [q_proj, k_proj, v_proj, o_proj]

data:
  train_jsonl: /workspace/data/shaped/train.jsonl
  val_jsonl:   /workspace/data/shaped/val.jsonl
  test_jsonl:  /workspace/data/shaped/test.jsonl
  max_seq_len: ${MAX_SEQ_LEN}
  pack_sequences: false
  chat_template: ${CHAT_TEMPLATE}

training:
  output_dir: /workspace/checkpoints
  num_train_epochs: ${EPOCHS}
  max_steps: ${MAX_STEPS}
  per_device_train_batch_size: ${BATCH_SIZE}
  gradient_accumulation_steps: ${GRAD_ACCUM}
  learning_rate: ${LR}
  warmup_ratio: 0.03
  lr_scheduler_type: cosine
  weight_decay: 0.01
  bf16: true
  fp16: false
  gradient_checkpointing: ${GRAD_CKPT}
  save_strategy: steps
  save_steps: ${SAVE_STEPS}
  save_total_limit: 3
  logging_steps: ${LOGGING_STEPS}
  evaluation_strategy: "no"
  seed: 42
  report_to: []

tokenizer:
  strategy: ${TOK_STRATEGY}
  add_special_tokens: false

resume:
  from_checkpoint: null

framework: ${FRAMEWORK}

logging:
  remote_log_path: /workspace/logs/train.log
YAML

# ---- Upload config + train.py to instance -----------------------------

echo "[forge-train] uploading training config + train.py + dataset..." >&2

# Config YAML (→ S3 → instance)
export FORGE_PHASE="TRAIN"
s3_put "$FORGE_ID" "$CONFIG_FILE" "training/config.yaml"
compute_aws_exec "$INSTANCE_ID" \
  "mkdir -p /workspace/training && aws s3 cp s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/training/config.yaml /workspace/training/config.yaml --region ${FORGE_REGION}" \
  >/dev/null

# train.py
compute_aws_upload "$FORGE_ID" "$INSTANCE_ID" "${SCRIPTS}/train.py" "/workspace/scripts/train.py"

# Pull shaped dataset onto instance
compute_aws_exec "$INSTANCE_ID" \
  "mkdir -p /workspace/data/shaped && aws s3 sync s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/data/shaped/ /workspace/data/shaped/ --region ${FORGE_REGION}" \
  >/dev/null

# ---- Config validation probe (no training yet) -------------------------

echo "[forge-train] validating config via train.py --validate-config-only..." >&2
if ! compute_aws_exec "$INSTANCE_ID" \
     "/workspace/.venv/bin/python /workspace/scripts/train.py --config /workspace/training/config.yaml --validate-config-only" \
     >"$WORK/validate.out" 2>&1; then
  echo "[forge-train] validate-config-only FAILED:" >&2
  head -20 "$WORK/validate.out" >&2
  manifest_patch "$FORGE_ID" "
    .errors += [{
      skill: \"forge-train\",
      phase: \"TRAIN\",
      timestamp: (now | todate),
      error_type: \"config_invalid\",
      message: \"train.py --validate-config-only rejected the generated config\",
      recoverable: true,
      recovery_hint: \"inspect /workspace/training/config.yaml on the instance and manifest.plan for mismatches\"
    }]
  " >/dev/null
  jq -n --arg fid "$FORGE_ID" '{
    status: "failed",
    next_phase: "TRAIN",
    skill: "forge-train",
    forge_id: $fid,
    recoverable: true,
    error: "config validation failed"
  }'
  exit 1
fi
cat "$WORK/validate.out" | tail -3 >&2

# ---- Launch training detached via setsid ------------------------------
# AWS-RunShellScript uses dash. dash doesn't support bash's `disown`. We
# use setsid which detaches reliably across shells. Also redirect stdin
# from /dev/null so the SSM session closing doesn't send SIGHUP.

echo "[forge-train] launching train.py detached (setsid + /dev/null stdin)..." >&2
LAUNCH_SCRIPT=$(cat <<'LAUNCH'
#!/bin/bash
set -e
mkdir -p /workspace/logs /workspace/checkpoints
# Kill any stale side processes from earlier failed runs
pkill -f 'train\.py' 2>/dev/null || true
pkill -f 'forge-log-sync' 2>/dev/null || true
sleep 1

# Train
setsid /workspace/.venv/bin/python /workspace/scripts/train.py \
  --config /workspace/training/config.yaml \
  </dev/null >/workspace/logs/train.log 2>&1 &
TRAIN_PID=$!
echo $TRAIN_PID > /workspace/.forge-train.pid
disown 2>/dev/null || true

# Log-sync side process (rsync train.log to S3 every 30 s).
# Identified by a marker argv for pkill.
setsid bash -c 'exec -a forge-log-sync bash -c "
  while sleep 30; do
    aws s3 cp /workspace/logs/train.log \
      s3://__BUCKET__/forge/__FORGE_ID__/logs/train.log \
      --region __REGION__ 2>/dev/null || true
  done"' </dev/null >/dev/null 2>&1 &
echo $! > /workspace/.forge-log-sync.pid
disown 2>/dev/null || true

echo "train_pid=$TRAIN_PID log_sync_pid=$(cat /workspace/.forge-log-sync.pid)"
LAUNCH
)

# Substitute the forge-specific values into the launch script.
LAUNCH_SCRIPT="${LAUNCH_SCRIPT//__BUCKET__/$FORGE_BUCKET}"
LAUNCH_SCRIPT="${LAUNCH_SCRIPT//__FORGE_ID__/$FORGE_ID}"
LAUNCH_SCRIPT="${LAUNCH_SCRIPT//__REGION__/$FORGE_REGION}"

# Upload the launch script + run it via SSM
echo "$LAUNCH_SCRIPT" > "$WORK/launch.sh"
compute_aws_upload "$FORGE_ID" "$INSTANCE_ID" "$WORK/launch.sh" "/tmp/forge-train-launch.sh"

LAUNCH_OUT=$(compute_aws_exec "$INSTANCE_ID" "chmod +x /tmp/forge-train-launch.sh && bash /tmp/forge-train-launch.sh" 2>&1)
echo "$LAUNCH_OUT" | tail -3 >&2

# Extract PIDs
PID=$(compute_aws_exec "$INSTANCE_ID" "cat /workspace/.forge-train.pid 2>/dev/null" | tr -d '[:space:]')
LOG_SYNC_PID=$(compute_aws_exec "$INSTANCE_ID" "cat /workspace/.forge-log-sync.pid 2>/dev/null" | tr -d '[:space:]')

if [[ -z "$PID" || ! "$PID" =~ ^[0-9]+$ ]]; then
  echo "[forge-train] ERROR: could not capture training PID" >&2
  exit 1
fi

echo "[forge-train] launched train_pid=$PID log_sync_pid=${LOG_SYNC_PID:-?}" >&2

# ---- 30-second health probe ------------------------------------------

echo "[forge-train] health probe (30 s)..." >&2
sleep 30
ALIVE=$(compute_aws_exec "$INSTANCE_ID" "kill -0 $PID 2>/dev/null && echo alive || echo dead" 2>/dev/null | tr -d '[:space:]')

if [[ "$ALIVE" != "alive" ]]; then
  echo "[forge-train] PID $PID died within 30 s of launch" >&2
  # Pull first 50 lines of log for diagnosis
  FIRST_LINES=$(compute_aws_exec "$INSTANCE_ID" "head -50 /workspace/logs/train.log 2>/dev/null" 2>/dev/null || echo "(log unreadable)")
  echo "$FIRST_LINES" | head -30 >&2

  manifest_patch "$FORGE_ID" "
    .errors += [{
      skill: \"forge-train\",
      phase: \"TRAIN\",
      timestamp: (now | todate),
      error_type: \"early_crash\",
      message: \"training PID died within 30s of launch\",
      recoverable: true,
      recovery_hint: \"read s3://.../logs/train.log first 50 lines; common: OOM (reduce batch), wrong dataset path, missing HF model access\"
    }]
  " >/dev/null

  jq -n --arg fid "$FORGE_ID" --arg pid "$PID" '{
    status: "failed",
    next_phase: "TRAIN",
    skill: "forge-train",
    forge_id: $fid,
    recoverable: true,
    error: "training crashed within 30s health probe",
    pid: ($pid | tonumber)
  }'
  exit 1
fi

echo "[forge-train] health probe PASS ✓" >&2

# ---- Write training_runtime + advance phase --------------------------

LOG_PATH_S3="s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/logs/train.log"
CONFIG_S3="s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/training/config.yaml"

manifest_patch "$FORGE_ID" "
  .training_runtime = {
    pid: ${PID},
    log_sync_pid: $([[ -n "$LOG_SYNC_PID" && "$LOG_SYNC_PID" =~ ^[0-9]+$ ]] && echo "$LOG_SYNC_PID" || echo "null"),
    log_path_remote: \"/workspace/logs/train.log\",
    log_path_s3: \"${LOG_PATH_S3}\",
    config_yaml_s3: \"${CONFIG_S3}\",
    framework: \"${FRAMEWORK}\",
    started_at: (now | todate),
    last_heartbeat: (now | todate),
    last_loss: null,
    last_loss_step: null,
    last_checkpoint_step: null,
    last_checkpoint_s3: null,
    eta_remaining_minutes: null
  }
  | .phase = \"MONITOR\"
  | .phase_history[-1].exited_at = (now | todate)
  | .phase_history[-1].status = \"completed\"
  | .phase_history += [{
      phase: \"MONITOR\",
      entered_at: (now | todate),
      exited_at: null,
      status: \"in-progress\"
    }]
" >/dev/null

jq -n \
  --arg fid "$FORGE_ID" \
  --arg iid "$INSTANCE_ID" \
  --arg pid "$PID" \
  --arg log_s3 "$LOG_PATH_S3" \
  '{
    status: "completed",
    next_phase: "MONITOR",
    skill: "forge-train",
    forge_id: $fid,
    instance_id: $iid,
    pid: ($pid | tonumber),
    log_path_s3: $log_s3
  }'
