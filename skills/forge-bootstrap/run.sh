#!/usr/bin/env bash
# skills/forge-bootstrap/run.sh — BOOTSTRAP phase implementation.
#
# Reads:
#   - manifest.compute_target.instance_id
#   - manifest.plan.training_framework (unsloth → don't skip unsloth install)
# Writes:
#   - /workspace/.forge-bootstrap-complete sentinel on the instance
#   - s3://.../forge/<id>/logs/bootstrap.log
#   - manifest.compute_target.bootstrap_completed = true
#   - Advances phase to TRAIN.
#
# Uses lib/compute_aws.sh compute_aws_bootstrap which handles:
#   - upload to S3 + SSM-pull
#   - launch detached under nohup
#   - poll /workspace/.forge-bootstrap-{complete,failed} sentinels
#   - sync /var/log/forge-bootstrap.log → S3 on completion

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../../lib"
SCRIPTS="${SCRIPT_DIR}/../../scripts"

# shellcheck source=../../lib/manifest.sh
source "${LIB}/manifest.sh"
# shellcheck source=../../lib/compute_aws.sh
source "${LIB}/compute_aws.sh"

FORGE_ID="${1:-}"
if [[ -z "$FORGE_ID" ]]; then
  echo "forge-bootstrap: forge-id required" >&2
  exit 64
fi

TIMEOUT="${FORGE_BOOTSTRAP_TIMEOUT:-1800}"  # 30 min default

MANIFEST=$(manifest_load "$FORGE_ID" 2>/dev/null)
INSTANCE_ID=$(echo "$MANIFEST" | jq -r '.compute_target.instance_id // ""')
BOOTSTRAP_DONE=$(echo "$MANIFEST" | jq -r '.compute_target.bootstrap_completed // false')

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "null" ]]; then
  echo "forge-bootstrap: no compute_target.instance_id — run forge-provision first" >&2
  exit 1
fi

if [[ "$BOOTSTRAP_DONE" == "true" ]]; then
  echo "forge-bootstrap: already completed; skipping" >&2
  jq -n --arg fid "$FORGE_ID" --arg iid "$INSTANCE_ID" '{
    status: "completed",
    next_phase: "TRAIN",
    skill: "forge-bootstrap",
    forge_id: $fid,
    instance_id: $iid,
    idempotent: true
  }'
  exit 0
fi

SCRIPT_PATH="${SCRIPTS}/bootstrap.sh"
if [[ ! -f "$SCRIPT_PATH" ]]; then
  echo "forge-bootstrap: script not found: $SCRIPT_PATH" >&2
  exit 1
fi

echo "[forge-bootstrap] executing bootstrap.sh on $INSTANCE_ID (timeout ${TIMEOUT}s)..." >&2
if compute_aws_bootstrap "$FORGE_ID" "$INSTANCE_ID" "$SCRIPT_PATH" "$TIMEOUT"; then
  # Opportunistic: launch llama.cpp build in the background so it runs
  # during TRAIN (saves ~10 min at QUANTIZE time). Can be disabled with
  # FORGE_BOOTSTRAP_SKIP_LLAMA=1. Failures are non-fatal — forge-quantize
  # will fall back to on-demand build.
  if [[ "${FORGE_BOOTSTRAP_SKIP_LLAMA:-0}" != "1" ]]; then
    echo "[forge-bootstrap] launching llama.cpp build in background (overlaps TRAIN)..." >&2
    compute_aws_exec "$INSTANCE_ID" "
      if [[ ! -x /workspace/llama.cpp/build/bin/llama-quantize || ! -x /workspace/llama.cpp/build/bin/llama-cli ]]; then
        nohup bash -c '
          set -e
          if [[ ! -d /workspace/llama.cpp ]]; then
            git clone --quiet --depth 1 https://github.com/ggml-org/llama.cpp.git /workspace/llama.cpp
          fi
          cd /workspace/llama.cpp
          cmake -B build -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=ON -Wno-dev >/dev/null 2>&1
          cmake --build build --config Release --target llama-quantize llama-cli -j 4 >/dev/null 2>&1
          /workspace/.venv/bin/pip install --quiet gguf>=0.10 numpy>=1.24 sentencepiece>=0.2 2>&1 | tail -2 || true
          touch /workspace/.llama-build-complete
        ' > /workspace/logs/llama-build.log 2>&1 &
        disown
        echo 'llama.cpp build launched (PID='\$!')'
      else
        echo 'llama.cpp already present — skip'
      fi
    " >/dev/null 2>&1 || echo "[forge-bootstrap] llama build launch warning (non-fatal)" >&2
  fi

  manifest_patch "$FORGE_ID" "
    .compute_target.bootstrap_completed = true
    | .phase = \"TRAIN\"
    | .phase_history[-1].exited_at = (now | todate)
    | .phase_history[-1].status = \"completed\"
    | .phase_history += [{
        phase: \"TRAIN\",
        entered_at: (now | todate),
        exited_at: null,
        status: \"pending\"
      }]
  " >/dev/null

  jq -n --arg fid "$FORGE_ID" --arg iid "$INSTANCE_ID" '{
    status: "completed",
    next_phase: "TRAIN",
    skill: "forge-bootstrap",
    forge_id: $fid,
    instance_id: $iid,
    bootstrap_log_s3: ("s3://<YOUR_S3_BUCKET>/forge/" + $fid + "/logs/bootstrap.log")
  }'
else
  rc=$?
  # Persist failure in manifest.errors
  manifest_patch "$FORGE_ID" "
    .errors += [{
      skill: \"forge-bootstrap\",
      phase: \"BOOTSTRAP\",
      timestamp: (now | todate),
      error_type: \"bootstrap_failure\",
      message: \"bootstrap.sh did not write success sentinel within ${TIMEOUT}s\",
      recoverable: true,
      recovery_hint: \"Check s3://.../logs/bootstrap.log for cause. Common: apt lock contention (re-run) or CUDA version mismatch (wrong AMI).\"
    }]
  " >/dev/null

  jq -n --arg fid "$FORGE_ID" --arg iid "$INSTANCE_ID" --argjson rc "$rc" '{
    status: "failed",
    next_phase: "BOOTSTRAP",
    skill: "forge-bootstrap",
    forge_id: $fid,
    instance_id: $iid,
    recoverable: true,
    error: ("bootstrap failed with rc=" + ($rc|tostring)),
    recovery_hint: "Re-run forge-bootstrap; the script is idempotent."
  }'
  exit 1
fi
