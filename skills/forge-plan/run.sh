#!/bin/bash
# forge-plan: takes analysis.json + budget → derives full phase sequence with
# hyperparameters, cost estimates, and acceptance thresholds → emits plan.md
# (the single human gate document) + plan.json (the machine-readable spec
# that dispatch.sh consumes).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../../.."

ANALYSIS_FILE="${1:-}"
BUDGET="${2:-25}"

if [[ -z "$ANALYSIS_FILE" || ! -f "$ANALYSIS_FILE" ]]; then
  echo "usage: $0 <analysis.json> <budget-usd>" >&2
  exit 64
fi

ANALYSIS=$(cat "$ANALYSIS_FILE")
RUN_ID=$(echo "$ANALYSIS" | jq -r '.run_id')
TARGET=$(echo "$ANALYSIS" | jq -r '.target_dir')
EST_TOKENS=$(echo "$ANALYSIS" | jq -r '.input_inventory.estimated_raw_tokens')
DETECTED=$(echo "$ANALYSIS" | jq -r '.detected_format')
DOMAIN=$(echo "$ANALYSIS" | jq -r '.domain_signal.label')
NEEDS=$(echo "$ANALYSIS" | jq -c '.needs')
SKIP=$(echo "$ANALYSIS" | jq -c '.skip_phases')
RUN_DIR="${REPO_ROOT}/slm-forge/.runs/${RUN_ID}"

# --- Choose base model -----------------------------------------------------
# Heuristic on budget (ca-central-1 constraint: 24 GB GPU ceiling):
#   < $5   → Qwen2.5-0.5B (fits, fast, weakest)
#   < $50  → Qwen2.5-1.5B-Instruct (sweet spot for tight budgets)
#   < $100 → Qwen2.5-3B-Instruct + LoRA r=16 (noticeable reasoning jump)
#   ≥ $100 → Qwen2.5-7B-Instruct + QLoRA 4-bit r=32 (clinical-grade tier;
#            requires regime=qlora-sft since fp16 won't fit 24 GB)
if (( $(echo "$BUDGET < 5" | bc -l) )); then
  BASE_MODEL="Qwen/Qwen2.5-0.5B"
  BASE_PARAMS="494M"
  REGIME="lora-sft"
elif (( $(echo "$BUDGET < 50" | bc -l) )); then
  BASE_MODEL="Qwen/Qwen2.5-1.5B-Instruct"
  BASE_PARAMS="1.54B"
  REGIME="lora-sft"
elif (( $(echo "$BUDGET < 100" | bc -l) )); then
  BASE_MODEL="Qwen/Qwen2.5-3B-Instruct"
  BASE_PARAMS="3.09B"
  REGIME="lora-sft"
else
  BASE_MODEL="Qwen/Qwen2.5-7B-Instruct"
  BASE_PARAMS="7.62B"
  REGIME="qlora-sft"
fi

# --- Estimate clean tokens after audit -------------------------------------
# Heuristic: typical research corpus loses ~50% to off-topic + ~5% to slop +
# ~5% to near-dup → 40% retention. For chat-jsonl skipping audit, full retention.
case "$DETECTED" in
  chat-jsonl)
    EST_CLEAN_TOKENS=$EST_TOKENS
    EST_QA_PAIRS=$((EST_TOKENS / 250))   # est_tokens = lines × 250 by analyze
    EST_QA_TOKENS=$EST_TOKENS
    ;;
  pretrain-jsonl)
    EST_CLEAN_TOKENS=$((EST_TOKENS * 60 / 100))
    EST_QA_PAIRS=$((EST_CLEAN_TOKENS * 3 / 700))   # ~700 chars/passage avg, 3 Q/A per passage
    EST_QA_TOKENS=$((EST_QA_PAIRS * 250))           # ~250 tokens/Q/A pair
    ;;
  *)
    # raw-documents or mixed: PDF/DOCX bloat ~3x → after extraction tokens ÷3
    EST_CLEAN_TOKENS=$((EST_TOKENS / 3 * 40 / 100))
    EST_QA_PAIRS=$((EST_CLEAN_TOKENS * 3 / 700))
    EST_QA_TOKENS=$((EST_QA_PAIRS * 250))
    ;;
esac

# --- Hyperparameters + instance -------------------------------------------
# Size-class tuning on 24 GB GPU (A10G / L4 — the ca-central-1 ceiling):
#   0.5B     → g5.xlarge,  batch=4, seq=1024, no grad_ckpt, r=8
#   1.5B     → g5.xlarge,  batch=2, seq=512,  grad_ckpt, r=8
#   3B       → g5.2xlarge, batch=2, seq=1024, grad_ckpt, r=16  (more CPU for dataloader at longer seq)
#   7B QLoRA → g5.2xlarge, batch=2, seq=2048, grad_ckpt, r=32  (4-bit base frees VRAM for longer context)
if [[ "$BASE_MODEL" == *"0.5B"* ]]; then
  INSTANCE_TYPE="g5.xlarge";  INSTANCE_HOURLY="1.212"
  BATCH_SIZE=4; GRAD_ACCUM=2; MAX_SEQ_LEN=1024; GRAD_CKPT=false
  LORA_R=8;  LORA_ALPHA=16
  SEC_PER_STEP=2
elif [[ "$BASE_MODEL" == *"1.5B"* ]]; then
  INSTANCE_TYPE="g5.xlarge";  INSTANCE_HOURLY="1.212"
  BATCH_SIZE=2; GRAD_ACCUM=4; MAX_SEQ_LEN=512;  GRAD_CKPT=true
  LORA_R=8;  LORA_ALPHA=16
  SEC_PER_STEP=4
elif [[ "$BASE_MODEL" == *"3B"* ]]; then
  INSTANCE_TYPE="g5.2xlarge"; INSTANCE_HOURLY="1.456"
  BATCH_SIZE=2; GRAD_ACCUM=4; MAX_SEQ_LEN=1024; GRAD_CKPT=true
  LORA_R=16; LORA_ALPHA=32
  SEC_PER_STEP=7
else   # 7B
  INSTANCE_TYPE="g5.2xlarge"; INSTANCE_HOURLY="1.456"
  BATCH_SIZE=2; GRAD_ACCUM=4; MAX_SEQ_LEN=2048; GRAD_CKPT=true
  LORA_R=32; LORA_ALPHA=64
  SEC_PER_STEP=11
fi
EFFECTIVE_BATCH=$((BATCH_SIZE * GRAD_ACCUM))
LR="1e-4"

# Compute max_steps from corpus size: target 2-3 epochs
TOTAL_EX=$EST_QA_PAIRS
[[ $TOTAL_EX -lt 100 ]] && TOTAL_EX=100
TRAIN_EX=$((TOTAL_EX * 80 / 100))
STEPS_PER_EPOCH=$((TRAIN_EX / EFFECTIVE_BATCH))
[[ $STEPS_PER_EPOCH -lt 1 ]] && STEPS_PER_EPOCH=1
MAX_STEPS=$((STEPS_PER_EPOCH * 25 / 10))  # 2.5 epochs
[[ $MAX_STEPS -lt 300 ]] && MAX_STEPS=300
[[ $MAX_STEPS -gt 1500 ]] && MAX_STEPS=1500   # cap — beyond this, returns diminish + memorization rises

# --- Cost model ------------------------------------------------------------
# Claude SYNTH: per passage ~600 in tokens + ~400 out = 1k tokens
# Haiku 4.5 pricing: $1/M in, $5/M out → ~$0.0026 per passage
# Plan-fit grading: ~50 passages × Sonnet 4.6 ($3/M in, $15/M out) ~$0.30
# GPU train: max_steps × seconds-per-step × hourly-rate
SYNTH_PASSAGES=$((EST_QA_PAIRS / 3))  # roughly
[[ "$DETECTED" == "chat-jsonl" ]] && SYNTH_PASSAGES=0
COST_SYNTH=$(echo "scale=2; $SYNTH_PASSAGES * 0.0026" | bc -l)
COST_PLAN_FIT="0.30"
COST_SMOKETEST="0.05"
# Train time est: size-class-dependent sec/step set with hyperparameters above
TRAIN_SEC=$((MAX_STEPS * SEC_PER_STEP))
TRAIN_HOURS=$(echo "scale=4; $TRAIN_SEC / 3600" | bc -l)
COST_GPU=$(echo "scale=2; ($TRAIN_HOURS + 0.5) * $INSTANCE_HOURLY" | bc -l)  # +30 min for bootstrap+quantize+teardown
COST_TOTAL=$(echo "scale=2; $COST_SYNTH + $COST_PLAN_FIT + $COST_SMOKETEST + $COST_GPU" | bc -l)

# --- Phase timing estimate -------------------------------------------------
# Per-phase wall-clock estimates (minutes)
declare -A PHASE_MIN=(
  [prep]=8 [audit]=3 [synth]=12 [shape]=1 [plan_fit]=3
  [provision]=2 [bootstrap]=7 [train]=$((TRAIN_SEC / 60)) [monitor]=0
  [eval]=5 [quantize]=5 [register]=4 [card_validator]=0
  [smoketest]=1 [publish]=1 [teardown]=2 [report]=1
)
TOTAL_MIN=0
for ph in $(echo "$NEEDS" | jq -r '.[]'); do
  m=${PHASE_MIN[$ph]:-1}
  TOTAL_MIN=$((TOTAL_MIN + m))
done

# --- Build plan.json -------------------------------------------------------
PLAN_JSON=$(jq -n \
  --arg run_id "$RUN_ID" \
  --arg target "$TARGET" \
  --arg domain "$DOMAIN" \
  --arg base "$BASE_MODEL" \
  --arg base_params "$BASE_PARAMS" \
  --arg detected "$DETECTED" \
  --arg instance "$INSTANCE_TYPE" \
  --arg hourly "$INSTANCE_HOURLY" \
  --argjson budget "$BUDGET" \
  --argjson max_steps "$MAX_STEPS" \
  --argjson batch "$BATCH_SIZE" \
  --argjson grad_accum "$GRAD_ACCUM" \
  --argjson seq_len "$MAX_SEQ_LEN" \
  --arg grad_ckpt "$GRAD_CKPT" \
  --argjson lora_r "$LORA_R" \
  --argjson lora_alpha "$LORA_ALPHA" \
  --arg lr "$LR" \
  --argjson clean_tokens "$EST_CLEAN_TOKENS" \
  --argjson qa_pairs "$EST_QA_PAIRS" \
  --arg cost_synth "$COST_SYNTH" \
  --arg cost_plan_fit "$COST_PLAN_FIT" \
  --arg cost_gpu "$COST_GPU" \
  --arg cost_total "$COST_TOTAL" \
  --argjson total_min "$TOTAL_MIN" \
  --argjson needs "$NEEDS" \
  --argjson skip "$SKIP" \
  --arg regime "$REGIME" \
  '{
    run_id: $run_id,
    target_dir: $target,
    domain: $domain,
    detected_format: $detected,
    budget_cap_usd: $budget,
    base_model: { hf_repo: $base, params_label: $base_params },
    regime: $regime,
    framework: "huggingface-trainer",
    chat_template: "qwen2",
    training_overrides: {
      max_steps: $max_steps,
      batch_size: $batch,
      grad_accum: $grad_accum,
      max_seq_len: $seq_len,
      grad_ckpt: ($grad_ckpt == "true"),
      lora_r: $lora_r,
      lora_alpha: $lora_alpha,
      learning_rate: $lr,
      epochs: 1
    },
    compute: {
      instance_type: $instance,
      hourly_usd: ($hourly | tonumber),
      subnet_strategy: "auto-retry-azs",
      max_wall_clock_hours: 4
    },
    estimates: {
      clean_tokens: $clean_tokens,
      qa_pairs: $qa_pairs,
      total_wall_clock_minutes: $total_min,
      cost: {
        synth_usd: ($cost_synth | tonumber),
        plan_fit_usd: ($cost_plan_fit | tonumber),
        gpu_usd: ($cost_gpu | tonumber),
        total_usd: ($cost_total | tonumber)
      }
    },
    phase_sequence: $needs,
    skip_phases: $skip,
    acceptance_thresholds: {
      audit_min_clean_tokens: 500000,
      plan_fit_min_qa_mean: 4.0,
      plan_fit_min_qa_individual: 2.0,
      plan_fit_min_in_domain_pct: 0.95,
      plan_fit_max_type_pct: 0.50,
      eval_max_artifact_pct: 0.30,
      eval_perplexity_must_beat_baseline: true
    }
  }')

echo "$PLAN_JSON" > "$RUN_DIR/plan.json"

# --- Budget guardrail ------------------------------------------------------
# Refuse to plan if estimated cost > budget × 1.2 (20% headroom). Operator
# either increases budget OR caps MAX_STEPS / synth coverage manually.
COST_INT=${COST_TOTAL%.*}
BUDGET_INT=$BUDGET
THRESHOLD=$((BUDGET_INT * 12 / 10))
if (( COST_INT > THRESHOLD )); then
  cat > "$RUN_DIR/plan-refused.md" <<EOF
# 🛑 PLAN REFUSED — over budget

Estimated total: **\$${COST_TOTAL}** (cap: \$${BUDGET})
Cost exceeds budget × 1.2 = \$${THRESHOLD}.

## Why so expensive

- Detected ${EST_QA_PAIRS} Q/A pairs ($(printf "%'d" $EST_CLEAN_TOKENS) clean tokens)
- Claude SYNTH alone: \$${COST_SYNTH} for ${SYNTH_PASSAGES} passages
- GPU train: ${MAX_STEPS} steps × ~4s/step at \$${INSTANCE_HOURLY}/hr = \$${COST_GPU}

## Options

1. **Increase budget**: re-run with larger \$N (e.g. \`/slm-forge ${TARGET} 75\`)
2. **Sample the corpus**: pre-filter to a subset (e.g. only 1 subdirectory)
3. **Cheaper base**: pass an env override \`FORGE_BASE_OVERRIDE=Qwen/Qwen2.5-0.5B\` (smaller, less capacity)
4. **Cap training**: edit \`${RUN_DIR}/plan.json\` to lower \`max_steps\` (proportionally cuts GPU cost)
5. **Skip synth**: if your input is already Q/A, point at a chat-jsonl file directly

The plan.json is preserved — edit it and re-run \`approve-plan.sh ${RUN_ID}\` if you accept the over-budget cost.
EOF
  echo "$RUN_DIR/plan-refused.md"
  exit 2
fi

# --- Generate plan.md (human-readable) -------------------------------------
PLAN_MD="$RUN_DIR/plan.md"

# Build the phase table dynamically
PHASE_ROWS=""
i=1
for ph in $(echo "$NEEDS" | jq -r '.[]'); do
  m=${PHASE_MIN[$ph]:-1}
  case "$ph" in
    prep)           desc="Extract text from raw documents (PDF/DOCX/PPTX/TXT) → unified JSONL" ;;
    audit)          desc="Drop contamination (LLM slop, off-domain, near-dup, safety boilerplate)" ;;
    synth)          desc="Generate Q/A pairs via Claude Haiku (factual + mechanism + clinical)" ;;
    shape)          desc="80/10/10 train/val/test split, deterministic shuffle" ;;
    plan_fit)       desc="🛡️ 7-axis pre-spend validation (Q/A quality + budget headroom — replaces post-train QUALITY_GATE)" ;;
    provision)      desc="Launch ${INSTANCE_TYPE} (auto-retry across AZs)" ;;
    bootstrap)      desc="Install training stack + llama.cpp on instance" ;;
    train)          desc="$( [[ "$REGIME" == "qlora-sft" ]] && echo "QLoRA 4-bit SFT" || echo "LoRA SFT" ), ${MAX_STEPS} steps, batch=${BATCH_SIZE}×${GRAD_ACCUM}, seq=${MAX_SEQ_LEN}" ;;
    monitor)        desc="Poll training PID + sync checkpoints (auto, no human)" ;;
    eval)           desc="Perplexity vs baseline + 10 sample generations + auto artifact checks" ;;
    quantize)       desc="GGUF Q4_K_M + Q8_0 via llama.cpp" ;;
    register)       desc="Push HF model repo + Space + Modelfile (PRIVATE)" ;;
    card_validator) desc="🛡️ D-018 leak grep + template placeholder check" ;;
    smoketest)      desc="🛡️ Live API call to Space, verify response is non-degenerate" ;;
    publish)        desc="Flip both repos PUBLIC + emit final URLs" ;;
    teardown)       desc="Terminate EC2 + reconcile cost via Cost Explorer" ;;
    report)         desc="Emit after-action.md + qa-report.md" ;;
    *)              desc="(undocumented phase)" ;;
  esac
  PHASE_ROWS+="| $i | \`${ph}\` | ${m} min | ${desc} |"$'\n'
  i=$((i + 1))
done

cat > "$PLAN_MD" <<EOF
# 🦷 SLM-Forge plan — ${RUN_ID}

**Generated:** $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Input

- **Target:** \`${TARGET}\`
- **Detected format:** \`${DETECTED}\`
- **Domain (auto):** \`${DOMAIN}\`
- **Estimated raw tokens:** $(printf "%'d" $EST_TOKENS)
- **Estimated clean tokens after audit:** $(printf "%'d" $EST_CLEAN_TOKENS)
- **Estimated Q/A pairs after synth:** $(printf "%'d" $EST_QA_PAIRS)

## Budget

- **Cap:** \$${BUDGET}
- **Estimated total spend:** **\$${COST_TOTAL}** ($(echo "scale=0; ${COST_TOTAL%.*} * 100 / $BUDGET" | bc)% of cap)
  - Claude SYNTH: \$${COST_SYNTH} (Haiku 4.5)
  - Claude PLAN_FIT grading: \$${COST_PLAN_FIT} (Sonnet 4.6)
  - Claude SMOKETEST validator: \$${COST_SMOKETEST}
  - GPU compute: \$${COST_GPU} (${INSTANCE_TYPE} @ \$${INSTANCE_HOURLY}/hr × ~$(echo "scale=1; $TRAIN_SEC/3600 + 0.5" | bc -l) hr)

## Plan

- **Base model:** \`${BASE_MODEL}\` (${BASE_PARAMS})
- **Regime:** \`${REGIME}\` ($( [[ "$REGIME" == "qlora-sft" ]] && echo "4-bit NF4 base + bf16 LoRA — fits 7B in 24 GB GPU" || echo "proper Q/A SFT — not raw-text continuation" ))
- **LoRA:** r=${LORA_R}, alpha=${LORA_ALPHA}
- **Training:** ${MAX_STEPS} steps, batch_size=${BATCH_SIZE}, grad_accum=${GRAD_ACCUM} (effective ${EFFECTIVE_BATCH}), max_seq_len=${MAX_SEQ_LEN}, grad_ckpt=${GRAD_CKPT}, lr=${LR}
- **Instance:** ${INSTANCE_TYPE} (24GB A10G) in ca-central-1 (auto-retry AZs)

## Phase sequence (computed from input format)

| # | Phase | Est | What |
|---|---|---|---|
${PHASE_ROWS}

**Skipped phases** (not needed for \`${DETECTED}\` input): \`$(echo "$SKIP" | jq -r 'join(", ")')\`

**Total estimated wall-clock:** ${TOTAL_MIN} min

## Acceptance thresholds (auto-checked, no human)

| Gate | Threshold | What happens on fail |
|---|---|---|
| AUDIT min clean tokens | ≥ 500,000 | Forge aborts; switch to RAG or expand corpus |
| PLAN_FIT mean Q/A score | ≥ 4.0 (Sonnet grader) | Forge aborts; re-synth with stronger prompt |
| PLAN_FIT min individual | ≥ 2.0 | Forge aborts |
| PLAN_FIT % in-domain | ≥ 95% | Forge aborts; tighten audit thresholds |
| PLAN_FIT budget fit | actual_synth + projected_plan_fit + projected_gpu ≤ budget_cap, with ≥10% cap headroom | Forge aborts BEFORE GPU spend; re-plan with smaller corpus or higher cap |
| EVAL artifact rate in samples | < 30% | Forge aborts; fix sampling params |
| EVAL forged perplexity | < baseline | Forge aborts; model didn't actually learn |
| CARD_VALIDATOR D-018 leaks | 0 | Forge aborts; fix template render |
| SMOKETEST live response | non-empty + non-degenerate | Forge aborts; investigate Space |

## Failure escalation

If ANY phase fails: forge tears down EC2 immediately, saves partial state to S3, emits \`failure-report.md\`, exits 1. **No recursive retry.** Surfacing the failure is the right behavior — operator wakes up to a clean state, not a frozen pipeline.

## After success

Two MD files written to \`slm-forge/.runs/${RUN_ID}/\`:
- \`after-action.md\` — final URLs, cost ledger, sample outputs (3 best, 3 worst), caveats
- \`qa-report.md\` — verbatim PASS/FAIL on every gate, verdict line: \`READY-FOR-DEMO\` | \`PUBLISHED-WITH-CAVEATS\` | \`FAILED-DO-NOT-USE\`

---

## To approve

\`\`\`bash
bash slm-forge/scripts/approve-plan.sh ${RUN_ID}
\`\`\`

## To reject + adjust

\`\`\`bash
bash slm-forge/scripts/teardown-run.sh ${RUN_ID}
# Then either re-run /slm-forge with different args, or edit ${RUN_DIR}/plan.json
# manually and re-approve.
\`\`\`
EOF

echo "$PLAN_MD"
