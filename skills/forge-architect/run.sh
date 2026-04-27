#!/usr/bin/env bash
# skills/forge-architect/run.sh — ARCHITECT phase implementation.
#
# Reads:
#   - manifest.spec.*
#   - slm-forge/config/whitelist.json (D-006 base model list)
# Writes:
#   - manifest.plan.{base_model, training_regime, target_params,
#                    training_framework, chat_template, tokenizer_strategy,
#                    rationale, selected_at}
#   - Advances phase to ESTIMATE.
#
# Selection logic (rule-based, deterministic; no LLM call):
#   1. Filter candidates by license compatibility with spec.license_preference.
#   2. Score remaining candidates on:
#        - size vs target_params (prefer ratio 1x-3x the target)
#        - license score (permissive > restricted)
#        - tokenizer maturity
#   3. Pick top scorer.
#   4. Select regime based on corpus heuristics (estimated token count,
#      domain fit, user's target_use).
#
# Usage:
#   run.sh <forge-id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../../lib"
CONFIG="${SCRIPT_DIR}/../../config"

# shellcheck source=../../lib/manifest.sh
source "${LIB}/manifest.sh"

FORGE_ID="${1:-}"
if [[ -z "$FORGE_ID" ]]; then
  echo "forge-architect: forge-id required" >&2
  exit 64
fi

# ---- v2 bridge: if FORGE_ID is a v2 run-id with plan.json, import the
# plan's choices directly into the legacy manifest fields and exit.
# forge-plan already did the architecture work — this is just data motion.
PLAN_FILE="${SCRIPT_DIR}/../../.runs/${FORGE_ID}/plan.json"
if [[ -f "$PLAN_FILE" ]]; then
  echo "[forge-architect] v2 path: importing plan.json into manifest" >&2
  BASE=$(jq -r '.base_model.hf_repo' "$PLAN_FILE")
  REGIME=$(jq -r '.regime' "$PLAN_FILE")
  FW=$(jq -r '.framework' "$PLAN_FILE")
  CT=$(jq -r '.chat_template // "qwen2"' "$PLAN_FILE")

  manifest_patch "$FORGE_ID" "
    .plan.base_model = \"$BASE\" |
    .plan.training_regime = \"$REGIME\" |
    .plan.training_framework = \"$FW\" |
    .plan.chat_template = \"$CT\" |
    .plan.tokenizer_strategy = \"reuse-base\" |
    .plan.target_params = 300000000 |
    .plan.rationale = \"v2 plan.json (forge-plan)\" |
    .plan.selected_at = (now | todate) |
    .phase = \"ESTIMATE\"
  " >/dev/null

  jq -n --arg fid "$FORGE_ID" --arg base "$BASE" --arg reg "$REGIME" '{
    status: "completed",
    next_phase: "ESTIMATE",
    skill: "forge-architect",
    forge_id: $fid,
    bridged_from: "v2-plan-json",
    selected: { base_model: $base, training_regime: $reg }
  }'
  exit 0
fi

MANIFEST=$(manifest_load "$FORGE_ID" 2>/dev/null)
SPEC=$(echo "$MANIFEST" | jq -c .spec)

if [[ "$SPEC" == "null" || "$SPEC" == "{}" ]]; then
  echo "forge-architect: spec is empty — run forge-intake first" >&2
  exit 1
fi

# ---- Smoke overrides --------------------------------------------------
# FORGE_ARCHITECT_REGIME_OVERRIDE lets smoke tests force a specific regime
# without amending the spec (useful when the natural scoring picks a
# regime the M4 v1 train.py doesn't yet fully support, like prune-to-300m).
# FORGE_ARCHITECT_BASE_OVERRIDE forces a specific base_model id, bypassing
# the scoring loop entirely.

ARCHITECT_REGIME_OVERRIDE="${FORGE_ARCHITECT_REGIME_OVERRIDE:-}"
ARCHITECT_BASE_OVERRIDE="${FORGE_ARCHITECT_BASE_OVERRIDE:-}"

# ---- Read spec fields --------------------------------------------------

license_pref=$(echo "$SPEC" | jq -r '.license_preference // "apache-2.0"')
language=$(echo "$SPEC" | jq -r '.language // "en"')
target_params=$(echo "$SPEC" | jq -r '.constraints.max_params // 300000000')
target_latency=$(echo "$SPEC" | jq -r '.target_latency_ms // 500')
target_use=$(echo "$SPEC" | jq -r '.target_use // "local-laptop"')
corpus_ref=$(echo "$SPEC" | jq -r '.corpus_ref // ""')

# ---- License compatibility ---------------------------------------------
# Rough ordering: apache-2.0 ≈ mit (fully permissive) > llama-3.2-community
# (permissive for most uses) > other. If user asks for apache-2.0 or mit,
# we must only pick from those. Otherwise all licenses are acceptable.

is_license_compatible() {
  local user_pref="$1" model_license="$2"
  case "$user_pref" in
    apache-2.0|mit|bsd*|cc0|cc-by*|permissive)
      case "$model_license" in
        apache-2.0|mit|bsd*|cc0|cc-by*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *)
      return 0  # any license acceptable
      ;;
  esac
}

# ---- Whitelist filter + scoring ----------------------------------------

WHITELIST="${CONFIG}/whitelist.json"
if [[ ! -f "$WHITELIST" ]]; then
  echo "forge-architect: whitelist missing at $WHITELIST" >&2
  exit 1
fi

# Build a candidate list: iterate models, apply license filter, compute score.
# Score = f(size delta, regime viability). Higher is better.

best_id=""
best_score=-1
best_regime=""
best_chat_template=""
best_tokenizer=""
best_license=""
best_params=""

# "from-scratch" is special-cased: only considered when corpus is very
# large AND user accepts long training. For M2 smoke we don't pick it.
while IFS= read -r model; do
  id=$(echo "$model" | jq -r .id)
  license=$(echo "$model" | jq -r .license)
  params=$(echo "$model" | jq -r '.params // 0')
  chat_template=$(echo "$model" | jq -r .chat_template)
  tokenizer=$(echo "$model" | jq -r .tokenizer)
  regimes=$(echo "$model" | jq -c .viable_regimes)

  # Skip from-scratch unless the spec explicitly opts in (not yet supported).
  if [[ "$id" == "from-scratch" ]]; then
    continue
  fi

  # License compat
  if ! is_license_compatible "$license_pref" "$license"; then
    continue
  fi

  # Size delta scoring: prefer base_params in [target, 3*target] range
  # (gives good distill ratios) — the existing whitelist notes call these
  # out explicitly. Penalty for base < target (the target_params IS the
  # ceiling, so base<target means very little headroom).
  local_score=0
  if (( params >= target_params && params <= target_params * 4 )); then
    local_score=$(( local_score + 100 ))
  elif (( params > target_params * 4 )); then
    local_score=$(( local_score + 40 ))  # distill-only — still viable
  elif (( params < target_params )); then
    local_score=$(( local_score + 20 ))  # too small, can only SFT within
  fi

  # License score: apache-2.0 > mit > llama-community > other
  case "$license" in
    apache-2.0) local_score=$(( local_score + 30 )) ;;
    mit)        local_score=$(( local_score + 25 )) ;;
    llama-3.2-community) local_score=$(( local_score + 10 )) ;;
    *)          local_score=$(( local_score + 5 )) ;;
  esac

  # Chat template maturity (subjective but deterministic): qwen2, llama-3,
  # chatml, phi-3 are all well-supported in HF tokenizers.
  local_score=$(( local_score + 10 ))

  if (( local_score > best_score )); then
    best_score=$local_score
    best_id=$id
    best_license=$license
    best_params=$params
    best_chat_template=$chat_template
    best_tokenizer=$tokenizer
    best_regime_list=$regimes
  fi
done < <(jq -c '.models[]' "$WHITELIST")

if [[ -z "$best_id" ]]; then
  echo "forge-architect: no candidates passed filters (license_pref=$license_pref)" >&2
  exit 1
fi

# Apply base_model override if set (smoke tests)
if [[ -n "$ARCHITECT_BASE_OVERRIDE" ]]; then
  echo "forge-architect: FORGE_ARCHITECT_BASE_OVERRIDE=$ARCHITECT_BASE_OVERRIDE (was $best_id)" >&2
  # Look up the override in the whitelist to get chat_template + viable regimes.
  # If not in whitelist, use safe defaults.
  override_entry=$(jq -c --arg id "$ARCHITECT_BASE_OVERRIDE" '.models[] | select(.id == $id)' "$WHITELIST")
  if [[ -n "$override_entry" ]]; then
    best_id=$(echo "$override_entry" | jq -r .id)
    best_license=$(echo "$override_entry" | jq -r .license)
    best_params=$(echo "$override_entry" | jq -r '.params // 0')
    best_chat_template=$(echo "$override_entry" | jq -r .chat_template)
    best_tokenizer=$(echo "$override_entry" | jq -r .tokenizer)
    best_regime_list=$(echo "$override_entry" | jq -c .viable_regimes)
  else
    # Not in whitelist. Sniff reasonable defaults from the model id.
    best_id="$ARCHITECT_BASE_OVERRIDE"
    best_license="apache-2.0"
    best_params=100000000  # caller provided; we can't know
    best_chat_template="chatml"
    best_tokenizer="auto"
    best_regime_list='["lora-sft"]'
    echo "forge-architect: override $ARCHITECT_BASE_OVERRIDE not in whitelist; using defaults (chat_template=chatml, regime=lora-sft)" >&2
  fi
fi

# ---- Regime selection --------------------------------------------------
# Without a real token count we use a coarse heuristic on corpus_ref. For
# M2 smoke the tiny-corpus fixture has ~100 docs → trivially LoRA-SFT.
# Full logic from SKILL_SPECS.md § forge-architect step 6 fires when we
# can estimate the token count — defer to forge-shape's tokenizer pass.

# Default to the lightest viable regime in the candidate's list.
regime="lora-sft"
# Prefer prune/distill into the target window when the base is bigger.
# Use the model's declared viable_regimes to pick the right one.
first_regime=$(echo "$best_regime_list" | jq -r '.[0]')
case "$first_regime" in
  lora-sft|full-sft|continued-pretrain|prune-to-300m|distill-to-300m)
    regime="$first_regime" ;;
  *)
    regime="lora-sft" ;;
esac

# Apply regime override if set
if [[ -n "$ARCHITECT_REGIME_OVERRIDE" ]]; then
  echo "forge-architect: FORGE_ARCHITECT_REGIME_OVERRIDE=$ARCHITECT_REGIME_OVERRIDE (was $regime)" >&2
  regime="$ARCHITECT_REGIME_OVERRIDE"
fi

# Target params: if base is larger than ceiling, target = ceiling; else
# target = base (direct fine-tune, no size change).
if (( best_params > target_params )); then
  forge_target_params=$target_params
else
  forge_target_params=$best_params
fi

# Training framework decision (D-008): Unsloth for supported bases
# (Llama/Mistral/Qwen/Gemma); HF Trainer otherwise.
case "$best_id" in
  *Llama*|*Qwen*|*Mistral*|*Gemma*|*TinyLlama*) framework="unsloth" ;;
  *) framework="huggingface-trainer" ;;
esac

# Tokenizer strategy: reuse-base for all whitelist bases (M2 default).
tokenizer_strategy="reuse-base"

# ---- Compose plan ------------------------------------------------------

rationale="Selected ${best_id} (${best_params} params, ${best_license}) from whitelist after license filter against '${license_pref}'. Regime '${regime}' chosen from the model's viable_regimes list. Training framework '${framework}' per D-008. Chat template '${best_chat_template}'. Tokenizer strategy '${tokenizer_strategy}'."

PLAN=$(jq -n \
  --arg base_model "$best_id" \
  --arg regime "$regime" \
  --argjson target_params "$forge_target_params" \
  --arg framework "$framework" \
  --arg chat_template "$best_chat_template" \
  --arg tokenizer_strategy "$tokenizer_strategy" \
  --arg rationale "$rationale" \
  --arg selected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    base_model: $base_model,
    training_regime: $regime,
    target_params: $target_params,
    training_framework: $framework,
    chat_template: $chat_template,
    tokenizer_strategy: $tokenizer_strategy,
    rationale: $rationale,
    selected_at: $selected_at
  }')

# Idempotent: if plan already set, short-circuit
EXISTING_PLAN=$(echo "$MANIFEST" | jq -c '.plan // null')
if [[ "$EXISTING_PLAN" != "null" && "$EXISTING_PLAN" != "{}" ]]; then
  jq -n --arg fid "$FORGE_ID" '{
    status: "completed",
    next_phase: "ESTIMATE",
    skill: "forge-architect",
    forge_id: $fid,
    idempotent: true
  }'
  exit 0
fi

manifest_patch "$FORGE_ID" "
  .plan = ${PLAN}
  | .phase = \"ESTIMATE\"
  | .phase_history[-1].exited_at = (now | todate)
  | .phase_history[-1].status = \"completed\"
  | .phase_history += [{
      phase: \"ESTIMATE\",
      entered_at: (now | todate),
      exited_at: null,
      status: \"in-progress\"
    }]
" >/dev/null

jq -n \
  --arg fid "$FORGE_ID" \
  --arg base "$best_id" \
  --arg regime "$regime" \
  --argjson params "$forge_target_params" \
  '{
    status: "completed",
    next_phase: "ESTIMATE",
    skill: "forge-architect",
    forge_id: $fid,
    selected: {
      base_model: $base,
      training_regime: $regime,
      target_params: $params
    }
  }'
