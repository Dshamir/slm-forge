#!/usr/bin/env bash
# skills/forge-eval/run.sh — EVAL phase implementation.
#
# Runs perplexity + sample generation on the forged model (merged
# weights if lora-sft) on the live EC2 instance. Syncs reports to S3.
# Advances phase to QUALITY_GATE.
#
# M5 v1 scope:
#   - Perplexity on test.jsonl (merged model + baseline diff)
#   - 10 sample generations
#   - JSON summary + 3 Markdown reports
# M5+ hardening:
#   - lm-eval-harness tasks (hellaswag/arc_easy/winogrande)
#   - Domain-specific eval sets per router

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../../lib"
SCRIPTS="${SCRIPT_DIR}/../../scripts"
EVAL_SETS="${SCRIPT_DIR}/../../eval-sets"

# shellcheck source=../../lib/manifest.sh
source "${LIB}/manifest.sh"
# shellcheck source=../../lib/compute_aws.sh
source "${LIB}/compute_aws.sh"

FORGE_ID="${1:-}"
if [[ -z "$FORGE_ID" ]]; then
  echo "forge-eval: forge-id required" >&2
  exit 64
fi

EVAL_TIMEOUT="${FORGE_EVAL_TIMEOUT:-1800}"

MANIFEST=$(manifest_load "$FORGE_ID" 2>/dev/null)
INSTANCE_ID=$(echo "$MANIFEST" | jq -r '.compute_target.instance_id // ""')
BASE_MODEL=$(echo "$MANIFEST"  | jq -r '.plan.base_model')
REGIME=$(echo "$MANIFEST"      | jq -r '.plan.training_regime')
DOMAIN=$(echo "$MANIFEST"      | jq -r '.spec.domain // ""')
FINAL_S3=$(echo "$MANIFEST"    | jq -r '.artifacts.final_weights_s3 // ""')

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "null" ]]; then
  echo "forge-eval: no compute_target.instance_id" >&2
  exit 1
fi

# ---- Idempotency -------------------------------------------------------

EXISTING=$(echo "$MANIFEST" | jq -r '.artifacts.eval_reports_s3 // ""')
if [[ -n "$EXISTING" && "$EXISTING" != "null" ]]; then
  echo "forge-eval: eval_reports_s3 already populated; skipping" >&2
  jq -n --arg fid "$FORGE_ID" '{
    status: "completed",
    next_phase: "QUALITY_GATE",
    skill: "forge-eval",
    forge_id: $fid,
    idempotent: true
  }'
  exit 0
fi

# ---- Locate merged/final model on the instance ------------------------

# If lora-sft, forge-quantize's merge step already wrote /workspace/weights/merged/
# But M5 v1 runs EVAL before QUANTIZE (per phase table), so we may need to
# merge the adapter here too.
MERGED_DIR="/workspace/weights/merged"
EVAL_MODEL_DIR="$MERGED_DIR"

IS_ADAPTER=$(compute_aws_exec "$INSTANCE_ID" \
  "test -f /workspace/weights/final/adapter_config.json && echo yes || echo no" \
  2>/dev/null | tr -d '[:space:]' || echo "no")

MERGED_PRESENT=$(compute_aws_exec "$INSTANCE_ID" \
  "test -f $MERGED_DIR/config.json && ls $MERGED_DIR/*.safetensors 2>/dev/null | head -1 | grep -q . && echo yes || echo no" \
  2>/dev/null | tr -d '[:space:]' || echo "no")

if [[ "$IS_ADAPTER" == "yes" && "$MERGED_PRESENT" != "yes" ]]; then
  echo "[forge-eval] merging LoRA adapter into base (needed for eval)..." >&2
  # Ensure final weights are on the instance
  compute_aws_exec "$INSTANCE_ID" \
    "mkdir -p /workspace/weights/final && aws s3 sync $FINAL_S3 /workspace/weights/final/ --region ${FORGE_REGION}" \
    >/dev/null
  # Upload merge-adapter.py if not already
  compute_aws_upload "$FORGE_ID" "$INSTANCE_ID" "${SCRIPTS}/merge-adapter.py" "/workspace/scripts/merge-adapter.py"

  MERGE_CMD="/workspace/.venv/bin/python /workspace/scripts/merge-adapter.py \
    --adapter /workspace/weights/final \
    --base $BASE_MODEL \
    --out $MERGED_DIR 2>&1"
  mcmd=$(_compute_aws_cli ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --timeout-seconds "$EVAL_TIMEOUT" \
    --parameters "commands=[\"$MERGE_CMD\"]" \
    --query 'Command.CommandId' --output text)
  deadline=$(( SECONDS + EVAL_TIMEOUT + 60 ))
  while (( SECONDS < deadline )); do
    sleep 10
    mst=$(_compute_aws_cli ssm get-command-invocation --command-id "$mcmd" \
      --instance-id "$INSTANCE_ID" --query 'Status' --output text 2>/dev/null || echo "Pending")
    [[ "$mst" == "Success" || "$mst" == "Failed" || "$mst" == "TimedOut" ]] && break
  done
  if [[ "$mst" != "Success" ]]; then
    echo "[forge-eval] merge FAILED (status=$mst)" >&2
    _compute_aws_cli ssm get-command-invocation --command-id "$mcmd" \
      --instance-id "$INSTANCE_ID" --query 'StandardErrorContent' --output text 2>/dev/null | tail -20 >&2
    exit 1
  fi
elif [[ "$IS_ADAPTER" != "yes" ]]; then
  # Full weights path (not lora-sft)
  EVAL_MODEL_DIR="/workspace/weights/final"
  compute_aws_exec "$INSTANCE_ID" \
    "mkdir -p /workspace/weights/final && aws s3 sync $FINAL_S3 /workspace/weights/final/ --region ${FORGE_REGION}" \
    >/dev/null
fi

# ---- Upload eval.py + prompts to instance ----------------------------

compute_aws_upload "$FORGE_ID" "$INSTANCE_ID" "${SCRIPTS}/eval.py" "/workspace/scripts/eval.py"

# Pick the sample prompt set via domain router (v1: just generic fallback)
PROMPTS_FILE="/workspace/eval-sets/generic-prompts.txt"
compute_aws_exec "$INSTANCE_ID" "mkdir -p /workspace/eval-sets" >/dev/null
compute_aws_upload "$FORGE_ID" "$INSTANCE_ID" "${EVAL_SETS}/generic-prompts.txt" "$PROMPTS_FILE"

# Ensure test.jsonl is present (data/shaped was sync'd by forge-train)
compute_aws_exec "$INSTANCE_ID" \
  "test -f /workspace/data/shaped/test.jsonl || aws s3 cp s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/data/shaped/test.jsonl /workspace/data/shaped/test.jsonl --region ${FORGE_REGION}" \
  >/dev/null

# ---- Run eval.py ------------------------------------------------------

echo "[forge-eval] running perplexity + samples (baseline=$BASE_MODEL)..." >&2

WORK_EVAL=$(mktemp -d)
cat > "$WORK_EVAL/run-eval.sh" <<EOF
#!/bin/bash
set -e
mkdir -p /workspace/eval
/workspace/.venv/bin/python /workspace/scripts/eval.py \\
  --model-dir $EVAL_MODEL_DIR \\
  --baseline $BASE_MODEL \\
  --test-jsonl /workspace/data/shaped/test.jsonl \\
  --samples-prompts $PROMPTS_FILE \\
  --out-dir /workspace/eval \\
  --max-test-docs 100 \\
  --num-samples 10 2>&1
EOF

compute_aws_upload "$FORGE_ID" "$INSTANCE_ID" "$WORK_EVAL/run-eval.sh" "/tmp/run-eval.sh"
rm -rf "$WORK_EVAL"

ecmd=$(_compute_aws_cli ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --timeout-seconds "$EVAL_TIMEOUT" \
  --parameters "commands=[\"bash /tmp/run-eval.sh\"]" \
  --query 'Command.CommandId' --output text)

echo "[forge-eval] eval SSM cmd=$ecmd; polling..." >&2
deadline=$(( SECONDS + EVAL_TIMEOUT + 60 ))
est="Pending"
while (( SECONDS < deadline )); do
  sleep 15
  est=$(_compute_aws_cli ssm get-command-invocation --command-id "$ecmd" \
    --instance-id "$INSTANCE_ID" --query 'Status' --output text 2>/dev/null || echo "Pending")
  [[ "$est" == "Success" || "$est" == "Failed" || "$est" == "TimedOut" ]] && break
done
if [[ "$est" != "Success" ]]; then
  echo "[forge-eval] eval FAILED (status=$est)" >&2
  _compute_aws_cli ssm get-command-invocation --command-id "$ecmd" \
    --instance-id "$INSTANCE_ID" --query 'StandardErrorContent' --output text 2>/dev/null | tail -30 >&2
  exit 1
fi
# Print the summary JSON emitted by eval.py
_compute_aws_cli ssm get-command-invocation --command-id "$ecmd" \
  --instance-id "$INSTANCE_ID" --query 'StandardOutputContent' --output text 2>/dev/null | tail -20 >&2

# ---- Sync reports to S3 -----------------------------------------------

echo "[forge-eval] syncing /workspace/eval → S3..." >&2
compute_aws_exec "$INSTANCE_ID" \
  "aws s3 sync /workspace/eval/ s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/eval/reports/ --region ${FORGE_REGION}" \
  >/dev/null

# Also pull the summary back locally so we can surface it in the return value
SUMMARY=$(compute_aws_exec "$INSTANCE_ID" "cat /workspace/eval/perplexity.json 2>/dev/null" 2>/dev/null || echo "{}")

REPORTS_URI="s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/eval/reports/"

manifest_patch "$FORGE_ID" "
  .artifacts.eval_reports_s3 = \"${REPORTS_URI}\"
  | .phase = \"QUALITY_GATE\"
  | .phase_history[-1].exited_at = (now | todate)
  | .phase_history[-1].status = \"completed\"
  | .phase_history += [{
      phase: \"QUALITY_GATE\",
      entered_at: (now | todate),
      exited_at: null,
      status: \"in-progress\"
    }]
" >/dev/null

# ---- Automated artifact detection on samples (v2 quality gate replacement)
# Pull samples.md and check for degeneration patterns. If > FORGE_EVAL_MAX_ARTIFACT_PCT
# of samples show artifacts, mark as soft-fail in the JSON output (the v2
# dispatcher decides whether to abort).
SAMPLES_LOCAL=$(mktemp)
compute_aws_exec "$INSTANCE_ID" "cat /workspace/eval/samples.md 2>/dev/null" 2>/dev/null > "$SAMPLES_LOCAL" || true

ARTIFACT_PCT="0"
ARTIFACT_DETAILS="[]"
if [[ -s "$SAMPLES_LOCAL" ]]; then
  # Each sample is a "## N. Prompt" block. Count blocks + count those with artifacts.
  N_SAMPLES=$(grep -c "^## " "$SAMPLES_LOCAL" 2>/dev/null || echo 0)
  if (( N_SAMPLES > 0 )); then
    # Triple-word repetition
    N_TRIPLE=$(grep -cE '\b(\w{3,})\s+\1\s+\1\b' "$SAMPLES_LOCAL" 2>/dev/null || echo 0)
    # Run-together / GGUF detokenize artifacts
    N_GGUF=$(grep -cE 'tti(user|assistant)' "$SAMPLES_LOCAL" 2>/dev/null || echo 0)
    # Paragraph loops (same long substring 3+ times — heuristic via awk)
    N_LOOP=$(awk '
      /^### Response/,/^---/{
        if ($0 != "" && $0 !~ /^#/ && $0 !~ /^---/) { freq[$0]++ }
      }
      END {
        n=0; for (l in freq) if (freq[l]>=3 && length(l)>40) n++; print n
      }
    ' "$SAMPLES_LOCAL" 2>/dev/null || echo 0)
    N_BAD=$((N_TRIPLE + N_GGUF + N_LOOP))
    ARTIFACT_PCT=$(echo "scale=2; $N_BAD * 100 / $N_SAMPLES" | bc -l)
    ARTIFACT_DETAILS=$(jq -n --argjson tr "$N_TRIPLE" --argjson gg "$N_GGUF" --argjson lp "$N_LOOP" --argjson n "$N_SAMPLES" \
      '{n_samples:$n, triple_word:$tr, gguf_artifacts:$gg, paragraph_loops:$lp}')
  fi
fi
rm -f "$SAMPLES_LOCAL"

MAX_ARTIFACT_PCT="${FORGE_EVAL_MAX_ARTIFACT_PCT:-30}"
ARTIFACTS_PASS=true
if [[ $(echo "$ARTIFACT_PCT > $MAX_ARTIFACT_PCT" | bc -l) -eq 1 ]]; then
  ARTIFACTS_PASS=false
fi

jq -n \
  --arg fid "$FORGE_ID" \
  --arg uri "$REPORTS_URI" \
  --argjson summary "$SUMMARY" \
  --arg ap "$ARTIFACT_PCT" \
  --argjson ad "$ARTIFACT_DETAILS" \
  --arg pass "$ARTIFACTS_PASS" \
  '{
    status: "completed",
    next_phase: "QUALITY_GATE",
    skill: "forge-eval",
    forge_id: $fid,
    eval_reports_s3: $uri,
    summary: $summary,
    artifact_check: {
      passes: ($pass == "true"),
      artifact_pct: ($ap | tonumber),
      max_allowed_pct: '"$MAX_ARTIFACT_PCT"',
      details: $ad
    }
  }'

# v2 hard gate: if FORGE_EVAL_HARD_FAIL_ON_ARTIFACTS=1, exit non-zero
if [[ "${FORGE_EVAL_HARD_FAIL_ON_ARTIFACTS:-1}" == "1" && "$ARTIFACTS_PASS" == "false" ]]; then
  echo "[forge-eval] ${ARTIFACT_PCT}% of samples show artifact patterns (max ${MAX_ARTIFACT_PCT}%) — failing eval" >&2
  exit 1
fi
