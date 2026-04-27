#!/bin/bash
# forge-publish: flips both HF model + Space to public. Runs only after
# card-validator and smoketest pass.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../../.."
CREDS_FILE="${FORGE_CREDS_FILE:-/tmp/forge-creds.env}"

RUN_ID="${1:-}"
[[ -z "$RUN_ID" ]] && { echo "usage: $0 <run-id>" >&2; exit 64; }

RUN_DIR="${REPO_ROOT}/slm-forge/.runs/${RUN_ID}"
STATE="$RUN_DIR/state.json"

[[ -f "$CREDS_FILE" ]] && set -a && source "$CREDS_FILE" && set +a

# Resolve repo + space ids
HF_REPO=$(jq -r '.artifacts.hf_repo // ""' "$STATE")
HF_SPACE=$(jq -r '.artifacts.hf_space // ""' "$STATE")
if [[ -z "$HF_REPO" && -f "$RUN_DIR/forge-id" ]]; then
  FORGE_ID=$(cat "$RUN_DIR/forge-id")
  source "${REPO_ROOT}/slm-forge/lib/manifest.sh"
  HF_REPO=$(manifest_load "$FORGE_ID" 2>/dev/null | jq -r '.artifacts.hf_repo // ""')
  HF_SPACE=$(manifest_load "$FORGE_ID" 2>/dev/null | jq -r '.artifacts.hf_space // ""')
fi

[[ -z "$HF_REPO" || -z "$HF_SPACE" ]] && { echo "publish: hf_repo or hf_space missing in state" >&2; exit 1; }

REPO_ID=$(echo "$HF_REPO" | sed -E 's#^https?://huggingface.co/##; s#/?$##')
SPACE_ID=$(echo "$HF_SPACE" | sed -E 's#^https?://huggingface.co/spaces/##; s#/?$##')

echo "[publish] flipping $REPO_ID + $SPACE_ID to public" >&2

# Use HF API directly (PUT settings with private:false)
RESP_M=$(curl -sS --max-time 15 -X PUT \
  -H "Authorization: Bearer $HF_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"private": false}' \
  "https://huggingface.co/api/models/${REPO_ID}/settings" 2>&1)
RESP_S=$(curl -sS --max-time 15 -X PUT \
  -H "Authorization: Bearer $HF_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"private": false}' \
  "https://huggingface.co/api/spaces/${SPACE_ID}/settings" 2>&1)

# Verify
sleep 2
PRIV_M=$(curl -sS --max-time 10 -H "Authorization: Bearer $HF_TOKEN" \
  "https://huggingface.co/api/models/${REPO_ID}" | jq -r '.private // true')
PRIV_S=$(curl -sS --max-time 10 -H "Authorization: Bearer $HF_TOKEN" \
  "https://huggingface.co/api/spaces/${SPACE_ID}" | jq -r '.private // true')

if [[ "$PRIV_M" == "true" || "$PRIV_S" == "true" ]]; then
  jq -n --arg r "$REPO_ID" --arg s "$SPACE_ID" --arg pm "$PRIV_M" --arg ps "$PRIV_S" '{
    status:"fail", repo_still_private:($pm=="true"), space_still_private:($ps=="true"), repo:$r, space:$s
  }' | tee "$RUN_DIR/publish-report.json"
  exit 1
fi

jq -n --arg r "$HF_REPO" --arg s "$HF_SPACE" '{
  status:"pass",
  hf_repo_public: $r,
  hf_space_public: $s,
  flipped_at: (now|todate)
}' | tee "$RUN_DIR/publish-report.json"
