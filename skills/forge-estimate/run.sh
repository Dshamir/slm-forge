#!/usr/bin/env bash
# skills/forge-estimate/run.sh — ESTIMATE phase implementation.
#
# Reads:
#   - manifest.spec.*
#   - manifest.plan.*
#   - slm-forge/config/pricing.json
# Writes:
#   - manifest.estimate.{gpu_hours, instance_type, instance_cost_per_hour_usd,
#                        estimated_compute_cost_usd, estimated_storage_cost_usd,
#                        estimated_transfer_cost_usd, estimated_total_cost_usd,
#                        estimated_wall_clock_hours, confidence, assumptions[]}
#   - Advances phase to BUDGET_GATE (master-handled).
#
# GPU-hour heuristics per SKILL_SPECS.md § forge-estimate:
#   LoRA SFT:          (corpus_tokens/1e8) * (params/1e8) * 0.3
#   Full SFT:          LoRA * 3
#   Continued pretrain: (corpus_tokens/1e7) * (params/1e8) * 1.0
#   From-scratch:       (corpus_tokens/1e6) * (params/1e8) * 2.0
#
# For M2 smoke the corpus token count is not yet known (forge-shape
# computes it later). We estimate from spec.corpus_ref metadata when
# possible; otherwise we use a conservative floor.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../../lib"
CONFIG="${SCRIPT_DIR}/../../config"

# shellcheck source=../../lib/manifest.sh
source "${LIB}/manifest.sh"

FORGE_ID="${1:-}"
if [[ -z "$FORGE_ID" ]]; then
  echo "forge-estimate: forge-id required" >&2
  exit 64
fi

MANIFEST=$(manifest_load "$FORGE_ID" 2>/dev/null)
SPEC=$(echo "$MANIFEST" | jq -c .spec)
PLAN=$(echo "$MANIFEST" | jq -c .plan)

if [[ "$PLAN" == "null" ]]; then
  echo "forge-estimate: plan is empty — run forge-architect first" >&2
  exit 1
fi

# ---- Read plan fields --------------------------------------------------

base_model=$(echo "$PLAN" | jq -r .base_model)
regime=$(echo "$PLAN" | jq -r .training_regime)
target_params=$(echo "$PLAN" | jq -r .target_params)
budget_cap=$(echo "$SPEC" | jq -r '.constraints.budget_cap_usd // 100')
max_wall_clock=$(echo "$SPEC" | jq -r '.constraints.max_wall_clock_hours // 24')
corpus_ref=$(echo "$SPEC" | jq -r '.corpus_ref // ""')

# ---- Instance selection per pricing.json recommendations --------------

PRICING="${CONFIG}/pricing.json"
if [[ ! -f "$PRICING" ]]; then
  echo "forge-estimate: pricing snapshot missing at $PRICING" >&2
  exit 1
fi

# Find the first recommendation whose max_params >= target_params for this regime.
# Regime aliases per whitelist.json viable_regimes:
#   lora-sft               → regime "lora-sft"
#   full-sft               → regime "lora-sft" (conservative)
#   continued-pretrain     → regime "continued-pretrain"
#   prune-to-300m          → regime "lora-sft"
#   distill-to-300m        → regime "lora-sft" (teacher pass baked in)
#   from-scratch-pretrain  → regime "from-scratch-pretrain"

case "$regime" in
  full-sft)             lookup_regime="lora-sft" ;;
  prune-to-300m)        lookup_regime="lora-sft" ;;
  distill-to-300m)      lookup_regime="lora-sft" ;;
  from-scratch-pretrain) lookup_regime="from-scratch-pretrain" ;;
  lora-sft|continued-pretrain) lookup_regime="$regime" ;;
  *)                    lookup_regime="lora-sft" ;;
esac

instance_type=$(jq -r \
  --argjson target "$target_params" \
  --arg regime "$lookup_regime" \
  '.instance_recommendations_by_target_params
   | map(select(.max_params >= $target and .regime == $regime))
   | .[0].preferred_instance // "g5.xlarge"' "$PRICING")

rate_usd_hr=$(jq -r \
  --arg it "$instance_type" \
  '.ec2_on_demand[$it].rate_usd_hr // 1.212' "$PRICING")

# ---- Corpus token estimate ---------------------------------------------

# Very coarse for M2: estimate tokens from local file size if corpus_ref
# is a local: path; otherwise assume 1M tokens (conservative floor).
corpus_tokens=1000000  # 1M default
if [[ "$corpus_ref" == local:* ]]; then
  local_path="${corpus_ref#local:}"
  if [[ -e "$local_path" ]]; then
    # Rough: ~4 bytes per token for English text
    local_bytes=$(du -sb "$local_path" 2>/dev/null | awk '{print $1}')
    if [[ -n "$local_bytes" ]]; then
      corpus_tokens=$(( local_bytes / 4 ))
      [[ "$corpus_tokens" -lt 1000 ]] && corpus_tokens=1000  # floor
    fi
  fi
fi

# ---- GPU-hour heuristic ------------------------------------------------

compute_gpu_hours() {
  local regime="$1" tokens="$2" params="$3"
  awk -v r="$regime" -v t="$tokens" -v p="$params" '
    BEGIN {
      if (r == "lora-sft")            h = (t / 1e8) * (p / 1e8) * 0.3
      else if (r == "full-sft")       h = (t / 1e8) * (p / 1e8) * 0.9
      else if (r == "continued-pretrain") h = (t / 1e7) * (p / 1e8) * 1.0
      else if (r == "from-scratch-pretrain") h = (t / 1e6) * (p / 1e8) * 2.0
      else if (r == "prune-to-300m")  h = (t / 1e8) * (p / 1e8) * 0.5
      else if (r == "distill-to-300m") h = (t / 1e8) * (p / 1e8) * 0.6
      else                            h = (t / 1e8) * (p / 1e8) * 0.3
      # Minimum: 0.1 hour (startup + teardown overhead)
      if (h < 0.1) h = 0.1
      printf "%.2f", h
    }'
}

gpu_hours=$(compute_gpu_hours "$regime" "$corpus_tokens" "$target_params")

# ---- Cost math ---------------------------------------------------------

compute_cost=$(awk -v r="$rate_usd_hr" -v h="$gpu_hours" 'BEGIN{printf "%.2f", r*h}')

# Storage: assume 10 GB avg working set for M2 smoke (corpus + checkpoints),
# kept for ~1 month at $0.10/GB-month.
storage_cost=$(awk 'BEGIN{printf "%.2f", 10 * 0.10}')

# Transfer: intra-region EC2↔S3 is free. Assume 0.
transfer_cost="0.00"

total=$(awk -v c="$compute_cost" -v s="$storage_cost" -v t="$transfer_cost" \
  'BEGIN{printf "%.2f", c+s+t}')

# Wall-clock time: for LoRA with small corpus, ~= gpu_hours + 20% overhead
# for provision/bootstrap/teardown.
wall_clock=$(awk -v h="$gpu_hours" 'BEGIN{printf "%.2f", h * 1.2 + 0.5}')

# Confidence band
confidence="medium"
if (( corpus_tokens < 10000 )); then
  confidence="low"  # tiny corpus → estimates noisy
fi
if [[ "$regime" == "from-scratch-pretrain" ]]; then
  confidence="low"  # long-tail variance
fi

# Budget warning
budget_warning=""
if awk -v t="$total" -v b="$budget_cap" 'BEGIN{exit !(t > b * 0.8)}'; then
  budget_warning=" Estimated total is >80% of budget_cap_usd=${budget_cap}."
fi

# ---- Compose estimate --------------------------------------------------

ASSUMPTIONS=$(jq -n \
  --argjson tokens "$corpus_tokens" \
  --arg regime "$regime" \
  '[
    "corpus token count = \($tokens) (coarse; refined by forge-shape)",
    "training regime = \($regime) (from plan)",
    "no spot interruptions",
    "intra-region transfer (free)"
  ]')

ESTIMATE=$(jq -n \
  --argjson gpu_hours "$gpu_hours" \
  --arg instance_type "$instance_type" \
  --argjson rate "$rate_usd_hr" \
  --argjson compute_cost "$compute_cost" \
  --argjson storage_cost "$storage_cost" \
  --argjson transfer_cost "$transfer_cost" \
  --argjson total "$total" \
  --argjson wall_clock "$wall_clock" \
  --arg confidence "$confidence" \
  --argjson assumptions "$ASSUMPTIONS" \
  '{
    gpu_hours: $gpu_hours,
    instance_type: $instance_type,
    instance_cost_per_hour_usd: $rate,
    estimated_compute_cost_usd: $compute_cost,
    estimated_storage_cost_usd: $storage_cost,
    estimated_transfer_cost_usd: $transfer_cost,
    estimated_total_cost_usd: $total,
    estimated_wall_clock_hours: $wall_clock,
    confidence: $confidence,
    assumptions: $assumptions
  }')

# Idempotent: if estimate already set, short-circuit.
EXISTING=$(echo "$MANIFEST" | jq -c '.estimate // null')
if [[ "$EXISTING" != "null" ]]; then
  jq -n --arg fid "$FORGE_ID" '{
    status: "completed",
    next_phase: "BUDGET_GATE",
    skill: "forge-estimate",
    forge_id: $fid,
    idempotent: true
  }'
  exit 0
fi

manifest_patch "$FORGE_ID" "
  .estimate = ${ESTIMATE}
  | .phase = \"BUDGET_GATE\"
  | .phase_history[-1].exited_at = (now | todate)
  | .phase_history[-1].status = \"completed\"
  | .phase_history += [{
      phase: \"BUDGET_GATE\",
      entered_at: (now | todate),
      exited_at: null,
      status: \"in-progress\"
    }]
" >/dev/null

jq -n \
  --arg fid "$FORGE_ID" \
  --argjson estimate "$ESTIMATE" \
  --arg warning "$budget_warning" \
  '{
    status: "completed",
    next_phase: "BUDGET_GATE",
    skill: "forge-estimate",
    forge_id: $fid,
    summary: {
      instance_type: $estimate.instance_type,
      gpu_hours: $estimate.gpu_hours,
      total_usd: $estimate.estimated_total_cost_usd,
      confidence: $estimate.confidence
    },
    warning: $warning
  }'
