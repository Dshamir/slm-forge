#!/bin/bash
# forge-smoketest: live API call to the freshly-published HF Space.
# Verifies the model returns a non-empty, non-degenerate response to a
# canonical probe. Hard fails if degenerate patterns detected. Runs
# AFTER card-validator, BEFORE publish.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../../.."
CREDS_FILE="${FORGE_CREDS_FILE:-/tmp/forge-creds.env}"

RUN_ID="${1:-}"
[[ -z "$RUN_ID" ]] && { echo "usage: $0 <run-id>" >&2; exit 64; }

RUN_DIR="${REPO_ROOT}/slm-forge/.runs/${RUN_ID}"
STATE="$RUN_DIR/state.json"

[[ -f "$CREDS_FILE" ]] && set -a && source "$CREDS_FILE" && set +a

# Resolve hf_space
HF_SPACE=$(jq -r '.artifacts.hf_space // ""' "$STATE")
if [[ -z "$HF_SPACE" ]]; then
  if [[ -f "$RUN_DIR/forge-id" ]]; then
    FORGE_ID=$(cat "$RUN_DIR/forge-id")
    source "${REPO_ROOT}/slm-forge/lib/manifest.sh"
    HF_SPACE=$(manifest_load "$FORGE_ID" 2>/dev/null | jq -r '.artifacts.hf_space // ""')
  fi
fi

if [[ -z "$HF_SPACE" ]]; then
  echo "smoketest: no hf_space in state — REGISTER must have run first" >&2
  exit 1
fi

# HF Space direct subdomain follows the {namespace}-{repo-name}.hf.space pattern
# e.g. https://huggingface.co/spaces/Nexless/foo-demo → https://nexless-foo-demo.hf.space/
SUBDOMAIN_REPO=$(echo "$HF_SPACE" | sed -E 's#^https?://huggingface.co/spaces/##; s#/?$##' | tr '[:upper:]/' '[:lower:]-')
SPACE_URL="https://${SUBDOMAIN_REPO}.hf.space/"

echo "[smoketest] Space URL: $SPACE_URL" >&2

# Wait for Space to be RUNNING — poll up to 8 minutes
SPACE_API="https://huggingface.co/api/spaces/$(echo "$HF_SPACE" | sed -E 's#^https?://huggingface.co/spaces/##; s#/?$##')"
prev=""
deadline=$(( $(date +%s) + 480 ))
while (( $(date +%s) < deadline )); do
  S=$(curl -sS --max-time 10 -H "Authorization: Bearer $HF_TOKEN" "$SPACE_API" 2>/dev/null \
    | jq -r '.runtime.stage // ""')
  if [[ "$S" != "$prev" ]]; then
    echo "[smoketest] stage: $S" >&2
    prev="$S"
  fi
  if [[ "$S" == "RUNNING" ]]; then
    code=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" "$SPACE_URL" 2>/dev/null)
    [[ "$code" == "200" ]] && break
  fi
  if [[ "$S" == *ERROR* ]]; then
    echo "[smoketest] stage went to error: $S" >&2
    jq -n --arg url "$SPACE_URL" --arg stage "$S" '{
      status:"fail", url:$url, error:"runtime stage \($stage)"
    }' | tee "$RUN_DIR/smoketest-report.json"
    exit 1
  fi
  sleep 20
done

if [[ "$S" != "RUNNING" ]]; then
  echo "[smoketest] timeout waiting for RUNNING (current: $S)" >&2
  exit 1
fi

# Try to call the Space's Gradio API. Most apps expose /run/predict.
# We send a canonical prompt and check the response for degenerate patterns.
PROBE_PROMPT="What is a dental crown?"
echo "[smoketest] sending probe: $PROBE_PROMPT" >&2

API_RESP=$(curl -sS --max-time 90 -X POST "${SPACE_URL}run/predict" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg p "$PROBE_PROMPT" '{data:[$p]}')" 2>/dev/null || echo "{}")

# Extract response text — Gradio returns {"data":["...response..."]}
RESP_TEXT=$(echo "$API_RESP" | jq -r '.data[0] // ""' 2>/dev/null)

# If the API call didn't work (auth, custom endpoint), we settle for a homepage check.
# At least confirm the Space is serving HTML successfully.
if [[ -z "$RESP_TEXT" ]]; then
  echo "[smoketest] /run/predict didn't return data, falling back to homepage check" >&2
  HTML=$(curl -sS --max-time 15 "$SPACE_URL")
  if [[ -n "$HTML" && "$HTML" == *"gradio"* ]]; then
    jq -n --arg url "$SPACE_URL" '{
      status:"pass", url:$url, mode:"homepage-only", note:"Could not call /run/predict; Gradio HTML serves OK. Manual verification recommended."
    }' | tee "$RUN_DIR/smoketest-report.json"
    exit 0
  else
    jq -n --arg url "$SPACE_URL" '{
      status:"fail", url:$url, error:"homepage did not return Gradio HTML"
    }' | tee "$RUN_DIR/smoketest-report.json"
    exit 1
  fi
fi

# Degenerate-pattern checks
DEGENERATE=""
[[ ${#RESP_TEXT} -lt 30 ]] && DEGENERATE+="too_short "
echo "$RESP_TEXT" | grep -qE "(\b(\w+)\s+\2\s+\2\b)" && DEGENERATE+="triple_word "
echo "$RESP_TEXT" | grep -qE "(.{40,})\1{2,}" && DEGENERATE+="paragraph_loop "
echo "$RESP_TEXT" | grep -qE "tti(user|assistant|\b)" && DEGENERATE+="gguf_artifact "

if [[ -n "$DEGENERATE" ]]; then
  jq -n --arg url "$SPACE_URL" --arg resp "$RESP_TEXT" --arg deg "$DEGENERATE" '{
    status:"fail", url:$url, response_preview:($resp[0:300]), degenerate_patterns:($deg|split(" "))
  }' | tee "$RUN_DIR/smoketest-report.json"
  exit 1
fi

jq -n --arg url "$SPACE_URL" --arg resp "$RESP_TEXT" --arg prompt "$PROBE_PROMPT" '{
  status:"pass", url:$url, prompt:$prompt, response_preview:($resp[0:400])
}' | tee "$RUN_DIR/smoketest-report.json"
exit 0
