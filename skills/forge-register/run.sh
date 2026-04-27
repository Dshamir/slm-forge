#!/usr/bin/env bash
# skills/forge-register/run.sh — REGISTER phase implementation.
#
# Publishes the forged model to three consumer surfaces (D-010):
#   1. HuggingFace model repo (canonical: weights + GGUF + model card)
#   2. HuggingFace Space (Gradio browser demo)
#   3. Ollama Modelfile (terminal users)
#
# Runs LOCALLY on the forge-operator host (not EC2). Needs HF_TOKEN
# + docker (for huggingface-cli). Downloads merged weights + GGUFs +
# eval reports from S3, fills templates, uploads to HF, writes URLs.
#
# Default visibility: PRIVATE. Flip to public via HF web UI after reviewing
# model card (D-018 vendor-neutral compliance).
#
# Smoke-friendly env overrides:
#   FORGE_REGISTER_NAMESPACE    override namespace (default: from HF whoami)
#   FORGE_REGISTER_NAME_PREFIX  prefix for forge-model-name (default: '')
#   FORGE_REGISTER_SKIP_SPACE   skip Space creation (smoke speedup)
#   FORGE_REGISTER_PUBLIC       create public instead of private (danger)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../../lib"
SCRIPTS="${SCRIPT_DIR}/../../scripts"
TEMPLATES="${SCRIPT_DIR}/../../templates"

# shellcheck source=../../lib/manifest.sh
source "${LIB}/manifest.sh"
# shellcheck source=../../lib/s3.sh
source "${LIB}/s3.sh"
# shellcheck source=../../lib/hf.sh
source "${LIB}/hf.sh"

FORGE_ID="${1:-}"
if [[ -z "$FORGE_ID" ]]; then
  echo "forge-register: forge-id required" >&2
  exit 64
fi

# Pattern: save original stdout as fd 3, redirect all working stdout to
# stderr. The final JSON result is emitted to fd 3 only. This prevents
# S3 sync "download: ..." lines and other progress output from polluting
# the caller's stdout capture.
exec 3>&1 1>&2

# ---- HF_TOKEN preflight ----------------------------------------------

if [[ -z "${HF_TOKEN:-}" ]]; then
  # Try .env fallback
  ENV_FILE="${SCRIPT_DIR}/../../../.env"
  if [[ -f "$ENV_FILE" ]]; then
    HF_TOKEN=$(grep '^HF_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
    export HF_TOKEN
  fi
fi
if [[ -z "${HF_TOKEN:-}" ]]; then
  echo "forge-register: HF_TOKEN not set (env or .env)" >&2
  exit 1
fi

# Verify token + get namespace
WHOAMI=$(hf_whoami 2>/dev/null || echo "{}")
HF_NS=$(echo "$WHOAMI" | jq -r '.name // empty')
if [[ -z "$HF_NS" ]]; then
  echo "forge-register: HF /api/whoami-v2 returned no namespace (bad token?)" >&2
  exit 1
fi
HF_NS="${FORGE_REGISTER_NAMESPACE:-$HF_NS}"
echo "[forge-register] HF namespace: $HF_NS" >&2

MANIFEST=$(manifest_load "$FORGE_ID" 2>/dev/null)
GOAL=$(echo "$MANIFEST"            | jq -r '.spec.goal // ""')
DOMAIN=$(echo "$MANIFEST"          | jq -r '.spec.domain // "general"')
TARGET_USE=$(echo "$MANIFEST"      | jq -r '.spec.target_use // "local-laptop"')
LICENSE=$(echo "$MANIFEST"         | jq -r '.spec.license_preference // "apache-2.0"')
LANGUAGE=$(echo "$MANIFEST"        | jq -r '.spec.language // "en"')
TARGET_PARAMS=$(echo "$MANIFEST"   | jq -r '.plan.target_params // 0')
BASE_MODEL=$(echo "$MANIFEST"      | jq -r '.plan.base_model')
REGIME=$(echo "$MANIFEST"          | jq -r '.plan.training_regime')
FRAMEWORK=$(echo "$MANIFEST"       | jq -r '.plan.training_framework')
CHAT_TEMPLATE=$(echo "$MANIFEST"   | jq -r '.plan.chat_template')
INSTANCE_TYPE=$(echo "$MANIFEST"   | jq -r '.compute_target.instance_type // "(torn down)"')
COST=$(echo "$MANIFEST"            | jq -r '.cost_tracking.cost_to_date_usd // 0')
STARTED=$(echo "$MANIFEST"         | jq -r '.training_runtime.started_at // .created_at')
Q4_URI=$(echo "$MANIFEST"          | jq -r '.artifacts.quantized_s3.Q4_K_M.uri // ""')
Q8_URI=$(echo "$MANIFEST"          | jq -r '.artifacts.quantized_s3.Q8_0.uri // ""')
Q4_SIZE=$(echo "$MANIFEST"         | jq -r '.artifacts.quantized_s3.Q4_K_M.bytes // 0')
Q8_SIZE=$(echo "$MANIFEST"         | jq -r '.artifacts.quantized_s3.Q8_0.bytes // 0')

if [[ -z "$Q4_URI" || "$Q4_URI" == "null" ]]; then
  echo "forge-register: no quantized Q4_K_M in manifest — run forge-quantize first" >&2
  exit 1
fi

# ---- Generate forge-model-name ---------------------------------------

# Format: {domain-slug}-slm-{params_M}m-{YYYYMMDD}
DOMAIN_SLUG=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -E 's/-+/-/g; s/^-|-$//g')
[[ -z "$DOMAIN_SLUG" ]] && DOMAIN_SLUG="general"
PARAMS_M=$(awk -v p="$TARGET_PARAMS" 'BEGIN{printf "%d", p/1000000}')
DATESTAMP=$(date -u +%Y%m%d)
NAME_PREFIX="${FORGE_REGISTER_NAME_PREFIX:-}"
FORGE_MODEL_NAME="${NAME_PREFIX}${DOMAIN_SLUG}-slm-${PARAMS_M}m-${DATESTAMP}"

# Smoke uniqueness: append forge-id's 6-char suffix
SUFFIX=$(echo "$FORGE_ID" | awk -F- '{print $NF}')
FORGE_MODEL_NAME="${FORGE_MODEL_NAME}-${SUFFIX}"

MODEL_REPO_ID="${HF_NS}/${FORGE_MODEL_NAME}"
SPACE_REPO_ID="${HF_NS}/${FORGE_MODEL_NAME}-demo"
echo "[forge-register] model repo: $MODEL_REPO_ID" >&2
echo "[forge-register] space repo: $SPACE_REPO_ID" >&2

# Idempotency: if hf_repo already set, short-circuit
EXISTING_REPO=$(echo "$MANIFEST" | jq -r '.artifacts.hf_repo // ""')
if [[ -n "$EXISTING_REPO" && "$EXISTING_REPO" != "null" ]]; then
  echo "forge-register: artifacts.hf_repo already populated; skipping" >&2
  jq -n --arg fid "$FORGE_ID" --arg repo "$EXISTING_REPO" '{
    status: "completed",
    next_phase: "TEARDOWN",
    skill: "forge-register",
    forge_id: $fid,
    hf_repo: $repo,
    idempotent: true
  }' >&3
  exit 0
fi

# ---- Pull release assets from S3 to local staging --------------------

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

HF_REPO_STAGE="$STAGE/hf-repo"
HF_SPACE_STAGE="$STAGE/hf-space"
RELEASE_STAGE="$STAGE/release"
mkdir -p "$HF_REPO_STAGE/gguf" "$HF_REPO_STAGE/eval" "$HF_SPACE_STAGE" "$RELEASE_STAGE"

echo "[forge-register] downloading release assets from S3..." >&2
# Merged weights (for the model repo)
# final_weights_s3 points at the LoRA adapter if regime=lora-sft; the
# merged/distributable model lives at weights/merged/ if forge-quantize
# already merged it. Prefer merged, fall back to adapter.
MERGED_S3="s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/weights/merged/"
MERGED_COUNT=$(s3_ls "$FORGE_ID" "weights/merged/" | wc -l)
if (( MERGED_COUNT > 0 )); then
  echo "  syncing merged model from $MERGED_S3..." >&2
  s3_sync_from "$FORGE_ID" "weights/merged/" "$HF_REPO_STAGE"
else
  # Fallback: ship the adapter directly (smaller; users can still load via peft)
  FINAL_URI=$(echo "$MANIFEST" | jq -r '.artifacts.final_weights_s3')
  echo "  merged/ not in S3 — shipping adapter from $FINAL_URI (users load via peft)..." >&2
  s3_sync_from "$FORGE_ID" "weights/final/" "$HF_REPO_STAGE"
fi

# GGUFs
echo "  downloading GGUFs..." >&2
s3_get "$FORGE_ID" "weights/quantized/model-Q4_K_M.gguf" "$HF_REPO_STAGE/gguf/model-Q4_K_M.gguf"
s3_get "$FORGE_ID" "weights/quantized/model-Q8_0.gguf"   "$HF_REPO_STAGE/gguf/model-Q8_0.gguf"

# Drop training-runtime artifacts that HF flags as unsafe (pickle files
# from HF Trainer: optimizer state, training_args.bin, etc.) — none are
# needed for inference and they trigger the "1 file scanned as unsafe"
# banner on the model page.
for junk in training_args.bin optimizer.pt scheduler.pt trainer_state.json rng_state.pth; do
  find "$HF_REPO_STAGE" -maxdepth 2 -name "$junk" -delete 2>/dev/null || true
done

# Eval reports
echo "  syncing eval reports..." >&2
s3_sync_from "$FORGE_ID" "eval/reports/" "$HF_REPO_STAGE/eval"

# ---- Render templates ------------------------------------------------

Q4_SIZE_MB=$(awk -v b="$Q4_SIZE" 'BEGIN{printf "%.1f", b/1e6}')
Q8_SIZE_MB=$(awk -v b="$Q8_SIZE" 'BEGIN{printf "%.1f", b/1e6}')
TARGET_PARAMS_HUMAN="${PARAMS_M}M"
YEAR=$(date -u +%Y)

# Training duration (approx from started_at to now)
NOW_EPOCH=$(date -u +%s)
START_EPOCH=$(date -u -d "$STARTED" +%s 2>/dev/null || echo $NOW_EPOCH)
TRAINING_DURATION_MIN=$(( (NOW_EPOCH - START_EPOCH) / 60 ))

# Corpus stats (best-effort from metadata)
CORPUS_STATS=$(s3_ls "$FORGE_ID" "metadata/tokenizer-stats.json" | head -1)
CORPUS_DOC_COUNT="?"
CORPUS_TOKEN_COUNT="?"
if [[ -n "$CORPUS_STATS" ]]; then
  STATS_TMP=$(mktemp)
  s3_get "$FORGE_ID" "metadata/tokenizer-stats.json" "$STATS_TMP" >/dev/null 2>&1 || true
  if [[ -s "$STATS_TMP" ]]; then
    CORPUS_DOC_COUNT=$(jq -r '.total_doc_count // "?"' "$STATS_TMP")
    CORPUS_TOKEN_COUNT=$(jq -r '.token_stats.approx_total_tokens // "?"' "$STATS_TMP")
  fi
  rm -f "$STATS_TMP"
fi

# Simple one-paragraph description derived from goal
ONE_LINE_DESC="${GOAL}"
[[ ${#ONE_LINE_DESC} -gt 100 ]] && ONE_LINE_DESC="${ONE_LINE_DESC:0:97}..."
ONE_PARA_DESC="${GOAL}. Trained on ${CORPUS_DOC_COUNT} documents (~${CORPUS_TOKEN_COUNT} tokens) from the ${DOMAIN} domain."

# Build the vars JSON for the template renderer
VARS=$(jq -n \
  --arg forge_model_name "$FORGE_MODEL_NAME" \
  --arg hf_namespace "$HF_NS" \
  --arg license "$LICENSE" \
  --arg language "$LANGUAGE" \
  --arg domain "$DOMAIN" \
  --arg target_params "$TARGET_PARAMS" \
  --arg target_params_human "$TARGET_PARAMS_HUMAN" \
  --arg base_model "$BASE_MODEL" \
  --arg training_regime "$REGIME" \
  --arg training_framework "$FRAMEWORK" \
  --arg chat_template "$CHAT_TEMPLATE" \
  --arg target_use "$TARGET_USE" \
  --arg training_hardware "$INSTANCE_TYPE" \
  --arg training_duration_minutes "$TRAINING_DURATION_MIN" \
  --arg training_tokens "$CORPUS_TOKEN_COUNT" \
  --arg training_cost_usd "$COST" \
  --arg forge_id "$FORGE_ID" \
  --arg corpus_description "Curated ${DOMAIN} corpus (forge ${FORGE_ID})" \
  --arg corpus_doc_count "$CORPUS_DOC_COUNT" \
  --arg corpus_token_count "$CORPUS_TOKEN_COUNT" \
  --arg q4km_size_mb "$Q4_SIZE_MB" \
  --arg q80_size_mb "$Q8_SIZE_MB" \
  --arg one_paragraph_description "$ONE_PARA_DESC" \
  --arg one_line_description "$ONE_LINE_DESC" \
  --arg what_this_is "A small language model focused on ${DOMAIN}. ${ONE_LINE_DESC}" \
  --arg system_prompt "You are a helpful assistant focused on ${DOMAIN}." \
  --arg example_prompt_1 "What is the most important thing to know about ${DOMAIN}?" \
  --arg example_prompt_2 "Give me a short overview of a common ${DOMAIN} question." \
  --arg example_prompt_3 "What's a best practice in ${DOMAIN}?" \
  --arg year "$YEAR" \
  --arg domain_eval_table "(see eval/comparison-vs-baseline.md)" \
  --arg generic_eval_table "(M5 v1: generic eval deferred to hardening)" \
  --arg baseline_diff_table "(see eval/comparison-vs-baseline.md)" \
  --arg additional_limitations_from_eval_samples "" \
  '{
    forge_model_name: $forge_model_name,
    hf_namespace: $hf_namespace,
    license: $license,
    language: $language,
    domain: $domain,
    target_params: $target_params,
    target_params_human: $target_params_human,
    base_model: $base_model,
    training_regime: $training_regime,
    training_framework: $training_framework,
    chat_template: $chat_template,
    target_use: $target_use,
    training_hardware: $training_hardware,
    training_duration_minutes: $training_duration_minutes,
    training_tokens: $training_tokens,
    training_cost_usd: $training_cost_usd,
    forge_id: $forge_id,
    corpus_description: $corpus_description,
    corpus_doc_count: $corpus_doc_count,
    corpus_token_count: $corpus_token_count,
    q4km_size_mb: $q4km_size_mb,
    q80_size_mb: $q80_size_mb,
    one_paragraph_description: $one_paragraph_description,
    one_line_description: $one_line_description,
    what_this_is: $what_this_is,
    system_prompt: $system_prompt,
    example_prompt_1: $example_prompt_1,
    example_prompt_2: $example_prompt_2,
    example_prompt_3: $example_prompt_3,
    year: $year,
    domain_eval_table: $domain_eval_table,
    generic_eval_table: $generic_eval_table,
    baseline_diff_table: $baseline_diff_table,
    additional_limitations_from_eval_samples: $additional_limitations_from_eval_samples
  }')

# Render model card
python3 "${SCRIPTS}/render-template.py" "${TEMPLATES}/model-card.md.tmpl" "$VARS" > "$HF_REPO_STAGE/README.md"

# Render release README
python3 "${SCRIPTS}/render-template.py" "${TEMPLATES}/release-readme.md.tmpl" "$VARS" > "$RELEASE_STAGE/README.md"

# Render Ollama Modelfile per chat_template
MODELFILE_TMPL="${TEMPLATES}/ollama-modelfile.${CHAT_TEMPLATE}.tmpl"
if [[ ! -f "$MODELFILE_TMPL" ]]; then
  MODELFILE_TMPL="${TEMPLATES}/ollama-modelfile.chatml.tmpl"
fi
python3 "${SCRIPTS}/render-template.py" "$MODELFILE_TMPL" "$VARS" > "$HF_REPO_STAGE/Modelfile"
cp "$HF_REPO_STAGE/Modelfile" "$RELEASE_STAGE/Modelfile"

# Render Space app.py + requirements
python3 "${SCRIPTS}/render-template.py" "${TEMPLATES}/space-app.py.tmpl" "$VARS" > "$HF_SPACE_STAGE/app.py"
python3 "${SCRIPTS}/render-template.py" "${TEMPLATES}/space-requirements.txt.tmpl" "$VARS" > "$HF_SPACE_STAGE/requirements.txt"
cat > "$HF_SPACE_STAGE/README.md" <<EOF
---
title: ${FORGE_MODEL_NAME}-demo
emoji: 🦷
colorFrom: blue
colorTo: green
sdk: gradio
sdk_version: 5.6.0
python_version: "3.11"
app_file: app.py
pinned: false
license: ${LICENSE}
---

# ${FORGE_MODEL_NAME} — demo

This Space runs the [${MODEL_REPO_ID}](https://huggingface.co/${MODEL_REPO_ID}) model via llama-cpp-python (Q4_K_M GGUF).

Forged with the SLM-Forge skill tree.
EOF

# Copy LICENSE
cat > "$HF_REPO_STAGE/LICENSE" <<EOF
This model is released under the ${LICENSE} license.
EOF

# ---- Vendor-neutral grep test (D-018) --------------------------------
# Case-sensitive: catch branding patterns (NEXLESS LP, MGMO, SIF-kernel)
# but NOT the HF namespace "Nexless" (per D-013 that's Daniel's HF handle
# — it appears legitimately in repo URLs and import snippets).

echo "[forge-register] running D-018 vendor-neutral grep test..." >&2
FORBIDDEN_HITS=$(grep -rE 'NEXLESS|MGMO|SIF(-|:|\s)' "$HF_REPO_STAGE" "$HF_SPACE_STAGE" 2>/dev/null \
  | grep -vE 'license|apache-2\.0|mit' || true)
if [[ -n "$FORBIDDEN_HITS" ]]; then
  echo "[forge-register] D-018 VIOLATION: forbidden strings in release artifacts:" >&2
  echo "$FORBIDDEN_HITS" >&2
  echo "[forge-register] aborting. Templates should be vendor-neutral." >&2
  exit 1
fi

# ---- Create HF model repo + upload -----------------------------------

VISIBILITY="${FORGE_REGISTER_PUBLIC:+public}"
VISIBILITY="${VISIBILITY:-private}"

echo "[forge-register] creating HF model repo $MODEL_REPO_ID (visibility=$VISIBILITY)..." >&2
CREATE_RESP=$(hf_create_repo "$MODEL_REPO_ID" "model" "$VISIBILITY" 2>&1 || true)
# If 409 (already exists), that's fine
if echo "$CREATE_RESP" | grep -qiE "already exists|409"; then
  echo "[forge-register] model repo exists; will overwrite files" >&2
elif echo "$CREATE_RESP" | grep -qiE "error|invalid"; then
  echo "[forge-register] create_repo FAILED: $CREATE_RESP" >&2
  exit 1
fi

echo "[forge-register] uploading model repo (weights + GGUFs + card + eval)..." >&2
hf_upload_folder "$HF_REPO_STAGE" "$MODEL_REPO_ID" "" "model" 1>&2

# ---- Create HF Space + upload -----------------------------------------

HF_SPACE_URL=""
if [[ -z "${FORGE_REGISTER_SKIP_SPACE:-}" ]]; then
  echo "[forge-register] creating HF Space $SPACE_REPO_ID (gradio, $VISIBILITY)..." >&2
  SCREATE=$(hf_create_space "$SPACE_REPO_ID" "gradio" "$VISIBILITY" 2>&1 || true)
  if echo "$SCREATE" | grep -qiE "already exists|409"; then
    echo "[forge-register] space repo exists; will overwrite files" >&2
  elif echo "$SCREATE" | grep -qiE "error"; then
    echo "[forge-register] WARN: space create: $SCREATE" >&2
  fi
  echo "[forge-register] uploading Space files..." >&2
  hf_upload_folder "$HF_SPACE_STAGE" "$SPACE_REPO_ID" "" "space" 1>&2
  HF_SPACE_URL="https://huggingface.co/spaces/${SPACE_REPO_ID}"
else
  echo "[forge-register] FORGE_REGISTER_SKIP_SPACE=1 — skipping Space creation" >&2
fi

# ---- Sync release/ back to S3 ----------------------------------------

echo "[forge-register] syncing release/ to S3..." >&2
# Add the hf-repo-url pointer
echo "https://huggingface.co/${MODEL_REPO_ID}" > "$RELEASE_STAGE/hf-repo-url.txt"
cp "$HF_REPO_STAGE/README.md" "$RELEASE_STAGE/model-card.md"

s3_sync_to "$FORGE_ID" "$RELEASE_STAGE" "release"

RELEASE_URI="s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${FORGE_ID}/release/"
HF_REPO_URL="https://huggingface.co/${MODEL_REPO_ID}"

# ---- Update manifest + return ---------------------------------------

manifest_patch "$FORGE_ID" "
  .artifacts.hf_repo     = \"${HF_REPO_URL}\"
  | .artifacts.hf_space  = \"${HF_SPACE_URL}\"
  | .artifacts.model_card_s3 = \"${RELEASE_URI}README.md\"
  | .phase = \"TEARDOWN\"
  | .phase_history[-1].exited_at = (now | todate)
  | .phase_history[-1].status = \"completed\"
  | .phase_history += [{
      phase: \"TEARDOWN\",
      entered_at: (now | todate),
      exited_at: null,
      status: \"pending\"
    }]
" >/dev/null

echo "" >&2
echo "═══════════════════════════════════════════════════════════════════" >&2
echo "  FORGE RELEASED" >&2
echo "    model:       ${HF_REPO_URL}" >&2
[[ -n "$HF_SPACE_URL" ]] && echo "    browser:     ${HF_SPACE_URL}" >&2
echo "    visibility:  ${VISIBILITY}" >&2
echo "    Ollama:      curl ${HF_REPO_URL}/raw/main/Modelfile -o Modelfile && ollama create ${FORGE_MODEL_NAME} -f Modelfile" >&2
echo "═══════════════════════════════════════════════════════════════════" >&2

jq -n \
  --arg fid "$FORGE_ID" \
  --arg repo "$HF_REPO_URL" \
  --arg space "$HF_SPACE_URL" \
  --arg name "$FORGE_MODEL_NAME" \
  --arg ns "$HF_NS" \
  --arg vis "$VISIBILITY" \
  '{
    status: "completed",
    next_phase: "TEARDOWN",
    skill: "forge-register",
    forge_id: $fid,
    forge_model_name: $name,
    hf_namespace: $ns,
    hf_repo: $repo,
    hf_space: $space,
    visibility: $vis
  }' >&3
