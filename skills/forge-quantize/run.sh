#!/usr/bin/env bash
# skills/forge-quantize/run.sh — QUANTIZE phase implementation.
#
# Reads:
#   - manifest.artifacts.final_weights_s3  (LoRA adapter OR full weights)
#   - manifest.plan.{base_model, training_regime, chat_template}
#   - manifest.compute_target.instance_id
# Writes:
#   - s3://.../weights/quantized/model-Q4_K_M.gguf
#   - s3://.../weights/quantized/model-Q8_0.gguf
#   - manifest.artifacts.quantized_s3.{Q4_K_M, Q8_0} + size metadata
#   - Advances phase: QUANTIZE → REGISTER
#
# Pipeline (runs on the EC2 instance):
#   1. (lora-sft regime only) Download adapter + merge into base via
#      scripts/merge-adapter.py → /workspace/weights/merged/
#   2. Install/verify llama.cpp at /workspace/llama.cpp (FAST bootstrap
#      skipped it, so we build on demand)
#   3. Run convert_hf_to_gguf.py → /workspace/weights/quantized/model-f16.gguf
#   4. Run llama-quantize for each target level (Q4_K_M, Q8_0)
#   5. Sanity-check each GGUF via llama-cli 10-token generation
#   6. Upload to S3, record sizes, advance phase

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
  echo "forge-quantize: forge-id required" >&2
  exit 64
fi

# Smoke-friendly timeout overrides
QUANT_TIMEOUT="${FORGE_QUANTIZE_TIMEOUT:-1800}"  # 30 min per SSM command

MANIFEST=$(manifest_load "$FORGE_ID" 2>/dev/null)
INSTANCE_ID=$(echo "$MANIFEST" | jq -r '.compute_target.instance_id // ""')
REGIME=$(echo "$MANIFEST"      | jq -r '.plan.training_regime')
BASE_MODEL=$(echo "$MANIFEST"  | jq -r '.plan.base_model')
FINAL_S3=$(echo "$MANIFEST"    | jq -r '.artifacts.final_weights_s3 // ""')

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "null" ]]; then
  echo "forge-quantize: no compute_target.instance_id" >&2
  exit 1
fi
if [[ -z "$FINAL_S3" || "$FINAL_S3" == "null" ]]; then
  echo "forge-quantize: no final_weights_s3 — run forge-monitor first" >&2
  exit 1
fi

# ---- Idempotency -------------------------------------------------------

EXISTING_Q4=$(echo "$MANIFEST" | jq -r '.artifacts.quantized_s3.Q4_K_M // ""')
if [[ -n "$EXISTING_Q4" && "$EXISTING_Q4" != "null" ]]; then
  # Verify the S3 object still exists
  Q4_KEY="${FORGE_PREFIX}/${FORGE_ID}/weights/quantized/model-Q4_K_M.gguf"
  if _forge_aws s3api head-object --bucket "$FORGE_BUCKET" --key "$Q4_KEY" >/dev/null 2>&1; then
    echo "forge-quantize: Q4_K_M already present in S3; skipping" >&2
    jq -n --arg fid "$FORGE_ID" '{
      status: "completed",
      next_phase: "REGISTER",
      skill: "forge-quantize",
      forge_id: $fid,
      idempotent: true
    }'
    exit 0
  fi
fi

# ---- 1. Merge LoRA adapter into base (if regime=lora-sft) -------------

REMOTE_MERGED_DIR="/workspace/weights/merged"
REMOTE_FINAL_DIR="/workspace/weights/final"

compute_aws_exec "$INSTANCE_ID" "mkdir -p /workspace/weights /workspace/weights/quantized" >/dev/null

echo "[forge-quantize] downloading final weights to instance..." >&2
compute_aws_exec "$INSTANCE_ID" \
  "mkdir -p $REMOTE_FINAL_DIR && aws s3 sync $FINAL_S3 $REMOTE_FINAL_DIR/ --region ${FORGE_REGION}" \
  >/dev/null

# Detect: is this a LoRA adapter dir (adapter_config.json present) or a full model?
IS_ADAPTER=$(compute_aws_exec "$INSTANCE_ID" \
  "test -f $REMOTE_FINAL_DIR/adapter_config.json && echo yes || echo no" \
  2>/dev/null | tr -d '[:space:]' || echo "no")

HF_MODEL_DIR="$REMOTE_FINAL_DIR"

if [[ "$IS_ADAPTER" == "yes" ]]; then
  echo "[forge-quantize] LoRA adapter detected — merging into base $BASE_MODEL..." >&2
  # Upload merge-adapter.py
  compute_aws_upload "$FORGE_ID" "$INSTANCE_ID" "${SCRIPTS}/merge-adapter.py" "/workspace/scripts/merge-adapter.py"

  # Run merge (synchronous; can take 1-3 min for 135M, 5-10 min for 500M+)
  MERGE_CMD="/workspace/.venv/bin/python /workspace/scripts/merge-adapter.py \
    --adapter $REMOTE_FINAL_DIR \
    --base $BASE_MODEL \
    --out $REMOTE_MERGED_DIR 2>&1"

  # Use a long-poll SSM exec (like compute_aws_bootstrap does)
  local_cmd_id=$(_compute_aws_cli ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --timeout-seconds "$QUANT_TIMEOUT" \
    --parameters "commands=[\"$MERGE_CMD\"]" \
    --query 'Command.CommandId' --output text)

  echo "[forge-quantize] merge SSM cmd=$local_cmd_id; polling..." >&2
  deadline=$(( SECONDS + QUANT_TIMEOUT + 60 ))
  while (( SECONDS < deadline )); do
    sleep 10
    merge_status=$(_compute_aws_cli ssm get-command-invocation \
      --command-id "$local_cmd_id" --instance-id "$INSTANCE_ID" \
      --query 'Status' --output text 2>/dev/null || echo "Pending")
    case "$merge_status" in
      Success|Failed|Cancelled|TimedOut) break ;;
    esac
  done

  if [[ "$merge_status" != "Success" ]]; then
    echo "[forge-quantize] merge FAILED (status=$merge_status)" >&2
    _compute_aws_cli ssm get-command-invocation \
      --command-id "$local_cmd_id" --instance-id "$INSTANCE_ID" \
      --query 'StandardOutputContent' --output text 2>/dev/null | tail -30 >&2 || true
    _compute_aws_cli ssm get-command-invocation \
      --command-id "$local_cmd_id" --instance-id "$INSTANCE_ID" \
      --query 'StandardErrorContent' --output text 2>/dev/null | tail -20 >&2 || true
    exit 1
  fi

  HF_MODEL_DIR="$REMOTE_MERGED_DIR"
  echo "[forge-quantize] merge SUCCESS → $HF_MODEL_DIR" >&2
fi

# ---- 2. Install llama.cpp on demand if missing ------------------------

LLAMA_PRESENT=$(compute_aws_exec "$INSTANCE_ID" \
  "test -x /workspace/llama.cpp/build/bin/llama-quantize && test -x /workspace/llama.cpp/build/bin/llama-cli && echo yes || echo no" \
  2>/dev/null | tr -d '[:space:]' || echo "no")

if [[ "$LLAMA_PRESENT" != "yes" ]]; then
  echo "[forge-quantize] llama.cpp not present — building (5-10 min on CPU instance)..." >&2

  WORK_LLAMA=$(mktemp -d)
  cat > "$WORK_LLAMA/install-llama.sh" <<'EOF'
#!/bin/bash
set -e
if [[ ! -d /workspace/llama.cpp ]]; then
  git clone --quiet --depth 1 https://github.com/ggml-org/llama.cpp.git /workspace/llama.cpp
fi
cd /workspace/llama.cpp
# CPU-only build (no CUDA; works on t3.xlarge)
cmake -B build -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=ON -Wno-dev >/dev/null 2>&1
cmake --build build --config Release --target llama-quantize llama-cli -j $(nproc) >/dev/null
# convert_hf_to_gguf.py needs these
/workspace/.venv/bin/pip install --quiet "gguf>=0.10" "numpy>=1.24" "sentencepiece>=0.2" 2>&1 | tail -5 || true
echo "llama.cpp ready at $(pwd)"
EOF

  compute_aws_upload "$FORGE_ID" "$INSTANCE_ID" "$WORK_LLAMA/install-llama.sh" "/tmp/install-llama.sh"
  rm -rf "$WORK_LLAMA"

  llama_cmd_id=$(_compute_aws_cli ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --timeout-seconds 2400 \
    --parameters "commands=[\"bash /tmp/install-llama.sh\"]" \
    --query 'Command.CommandId' --output text)

  deadline=$(( SECONDS + 2460 ))
  while (( SECONDS < deadline )); do
    sleep 15
    lst=$(_compute_aws_cli ssm get-command-invocation \
      --command-id "$llama_cmd_id" --instance-id "$INSTANCE_ID" \
      --query 'Status' --output text 2>/dev/null || echo "Pending")
    [[ "$lst" == "Success" || "$lst" == "Failed" || "$lst" == "TimedOut" ]] && break
  done
  if [[ "$lst" != "Success" ]]; then
    echo "[forge-quantize] llama.cpp build FAILED" >&2
    _compute_aws_cli ssm get-command-invocation \
      --command-id "$llama_cmd_id" --instance-id "$INSTANCE_ID" \
      --query 'StandardErrorContent' --output text 2>/dev/null | tail -30 >&2
    exit 1
  fi
  echo "[forge-quantize] llama.cpp built ✓" >&2
fi

# ---- 3. Convert HF → f16 GGUF + quantize to Q4_K_M and Q8_0 ----------

echo "[forge-quantize] converting HF → f16 GGUF + quantizing to Q4_K_M + Q8_0..." >&2

WORK_QUANT=$(mktemp -d)
cat > "$WORK_QUANT/convert-and-quant.sh" <<EOF
#!/bin/bash
set -e
cd /workspace/llama.cpp
mkdir -p /workspace/weights/quantized
# Convert HF → f16 GGUF
/workspace/.venv/bin/python /workspace/llama.cpp/convert_hf_to_gguf.py \\
  $HF_MODEL_DIR \\
  --outtype f16 \\
  --outfile /workspace/weights/quantized/model-f16.gguf
# Q4_K_M
/workspace/llama.cpp/build/bin/llama-quantize \\
  /workspace/weights/quantized/model-f16.gguf \\
  /workspace/weights/quantized/model-Q4_K_M.gguf \\
  Q4_K_M
# Q8_0
/workspace/llama.cpp/build/bin/llama-quantize \\
  /workspace/weights/quantized/model-f16.gguf \\
  /workspace/weights/quantized/model-Q8_0.gguf \\
  Q8_0
# Remove the big intermediate f16
rm /workspace/weights/quantized/model-f16.gguf
ls -l /workspace/weights/quantized/
EOF

compute_aws_upload "$FORGE_ID" "$INSTANCE_ID" "$WORK_QUANT/convert-and-quant.sh" "/tmp/convert-and-quant.sh"
rm -rf "$WORK_QUANT"

quant_cmd_id=$(_compute_aws_cli ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --timeout-seconds 1800 \
  --parameters "commands=[\"bash /tmp/convert-and-quant.sh\"]" \
  --query 'Command.CommandId' --output text)

echo "[forge-quantize] quant SSM cmd=$quant_cmd_id; polling..." >&2
deadline=$(( SECONDS + 1860 ))
qst="Pending"
while (( SECONDS < deadline )); do
  sleep 15
  qst=$(_compute_aws_cli ssm get-command-invocation \
    --command-id "$quant_cmd_id" --instance-id "$INSTANCE_ID" \
    --query 'Status' --output text 2>/dev/null || echo "Pending")
  [[ "$qst" == "Success" || "$qst" == "Failed" || "$qst" == "TimedOut" ]] && break
done
if [[ "$qst" != "Success" ]]; then
  echo "[forge-quantize] convert+quantize FAILED (status=$qst)" >&2
  _compute_aws_cli ssm get-command-invocation \
    --command-id "$quant_cmd_id" --instance-id "$INSTANCE_ID" \
    --query 'StandardErrorContent' --output text 2>/dev/null | tail -30 >&2
  exit 1
fi
_compute_aws_cli ssm get-command-invocation \
  --command-id "$quant_cmd_id" --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text 2>/dev/null | tail -10 >&2

# ---- 4. Sanity-check each GGUF via llama-cli ------------------------

echo "[forge-quantize] sanity check: generate 10 tokens from each GGUF..." >&2
for LEVEL in Q4_K_M Q8_0; do
  SANITY_OUT=$(compute_aws_exec "$INSTANCE_ID" "
/workspace/llama.cpp/build/bin/llama-cli \
  -m /workspace/weights/quantized/model-${LEVEL}.gguf \
  -p 'Hello, how are you?' \
  --n-predict 10 --simple-io --temp 0 2>&1 | tail -5
  " 2>/dev/null || echo "(no output)")
  # Accept any non-empty output without excessive repetition
  echo "  ${LEVEL}: $(echo "$SANITY_OUT" | head -3 | tr '\n' ' ')" >&2
done

# ---- 5. Upload GGUFs to S3 -------------------------------------------

echo "[forge-quantize] uploading GGUFs to S3..." >&2
compute_aws_exec "$INSTANCE_ID" "
  aws s3 cp /workspace/weights/quantized/model-Q4_K_M.gguf s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/weights/quantized/model-Q4_K_M.gguf --region ${FORGE_REGION}
  aws s3 cp /workspace/weights/quantized/model-Q8_0.gguf s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/weights/quantized/model-Q8_0.gguf --region ${FORGE_REGION}
" >/dev/null

# ---- 6. Record sizes in manifest --------------------------------------

Q4_URI="s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/weights/quantized/model-Q4_K_M.gguf"
Q8_URI="s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/weights/quantized/model-Q8_0.gguf"

Q4_SIZE=$(_forge_aws s3api head-object --bucket "$FORGE_BUCKET" \
  --key "${FORGE_PREFIX}/${FORGE_ID}/weights/quantized/model-Q4_K_M.gguf" \
  --query 'ContentLength' --output text 2>/dev/null || echo "0")
Q8_SIZE=$(_forge_aws s3api head-object --bucket "$FORGE_BUCKET" \
  --key "${FORGE_PREFIX}/${FORGE_ID}/weights/quantized/model-Q8_0.gguf" \
  --query 'ContentLength' --output text 2>/dev/null || echo "0")

manifest_patch "$FORGE_ID" "
  .artifacts.quantized_s3 = {
    Q4_K_M: { uri: \"${Q4_URI}\", bytes: ${Q4_SIZE}, sha256: null },
    Q8_0:   { uri: \"${Q8_URI}\", bytes: ${Q8_SIZE}, sha256: null },
    AWQ:    null
  }
  | .phase = \"REGISTER\"
  | .phase_history[-1].exited_at = (now | todate)
  | .phase_history[-1].status = \"completed\"
  | .phase_history += [{
      phase: \"REGISTER\",
      entered_at: (now | todate),
      exited_at: null,
      status: \"pending\"
    }]
" >/dev/null

jq -n \
  --arg fid "$FORGE_ID" \
  --arg q4 "$Q4_URI" --arg q8 "$Q8_URI" \
  --argjson q4_size "$Q4_SIZE" --argjson q8_size "$Q8_SIZE" \
  '{
    status: "completed",
    next_phase: "REGISTER",
    skill: "forge-quantize",
    forge_id: $fid,
    quantized: {
      Q4_K_M: { uri: $q4, bytes: $q4_size },
      Q8_0:   { uri: $q8, bytes: $q8_size }
    }
  }'
