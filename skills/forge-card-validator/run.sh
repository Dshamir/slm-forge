#!/bin/bash
# forge-card-validator: D-018 leak grep + placeholder check on the published
# HF model card. Hard-fails if anything bad slipped through. Runs AFTER
# register (private), BEFORE publish (public).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../../.."
CREDS_FILE="${FORGE_CREDS_FILE:-/tmp/forge-creds.env}"

RUN_ID="${1:-}"
[[ -z "$RUN_ID" ]] && { echo "usage: $0 <run-id>" >&2; exit 64; }

RUN_DIR="${REPO_ROOT}/slm-forge/.runs/${RUN_ID}"
STATE="$RUN_DIR/state.json"

[[ -f "$CREDS_FILE" ]] && set -a && source "$CREDS_FILE" && set +a

# Pull the HF repo URL from state
HF_REPO=$(jq -r '.artifacts.hf_repo // ""' "$STATE")
if [[ -z "$HF_REPO" ]]; then
  # Try v1 manifest path (bridge to existing forge-register)
  FORGE_ID="${FORGE_FORGE_ID:-}"
  if [[ -z "$FORGE_ID" && -f "$RUN_DIR/forge-id" ]]; then
    FORGE_ID=$(cat "$RUN_DIR/forge-id")
  fi
  if [[ -n "$FORGE_ID" ]]; then
    source "${REPO_ROOT}/slm-forge/lib/manifest.sh"
    HF_REPO=$(manifest_load "$FORGE_ID" 2>/dev/null | jq -r '.artifacts.hf_repo // ""')
  fi
fi

if [[ -z "$HF_REPO" ]]; then
  echo "card-validator: no hf_repo in state — REGISTER must run first" >&2
  exit 1
fi

# Strip the URL → repo id
REPO_ID=$(echo "$HF_REPO" | sed -E 's#^https?://huggingface.co/##; s#/?$##')
echo "[card-validator] checking $REPO_ID" >&2

# Pull README
README=$(mktemp)
curl -sSL --max-time 20 \
  -H "Authorization: Bearer $HF_TOKEN" \
  "https://huggingface.co/${REPO_ID}/raw/main/README.md" -o "$README" 2>/dev/null

if [[ ! -s "$README" ]]; then
  echo "card-validator: failed to download README from $REPO_ID" >&2
  exit 1
fi

# --- Checks ----------------------------------------------------------------
LEAK_HITS="[]"
LEAK_TERMS=("NEXLESS" "MGMO" "Intellident" "ToothFerry" "Dshamir" "blucap")
# SIF is too generic; only flag SIF as standalone word
for term in "${LEAK_TERMS[@]}"; do
  HITS=$(grep -nE "\b${term}\b" "$README" 2>/dev/null | head -3 || true)
  if [[ -n "$HITS" ]]; then
    LEAK_HITS=$(echo "$LEAK_HITS" | jq --arg t "$term" --arg h "$HITS" '. += [{term:$t, hits:$h}]')
  fi
done
SIF_HITS=$(grep -nE "(^|\s)SIF($|\s|[:.,])" "$README" 2>/dev/null | head -3 || true)
if [[ -n "$SIF_HITS" ]]; then
  LEAK_HITS=$(echo "$LEAK_HITS" | jq --arg h "$SIF_HITS" '. += [{term:"SIF", hits:$h}]')
fi

# Template placeholders
PLACEHOLDER_HITS=$(grep -oE '\{\{[a-z_]+\}\}' "$README" 2>/dev/null | sort -u | jq -R . | jq -sc . || echo "[]")

# Required sections
MISSING_SECTIONS="[]"
for sec in "## Model Details" "## Limitations" "## How to Use"; do
  if ! grep -qF "$sec" "$README"; then
    MISSING_SECTIONS=$(echo "$MISSING_SECTIONS" | jq --arg s "$sec" '. += [$s]')
  fi
done

# Param count: should NOT be the placeholder cap value (300000000) for real models
PARAM_LINE=$(grep -E "^\s*-\s+\*\*Parameters:\*\*" "$README" 2>/dev/null || true)
PARAM_REAL="true"
if [[ "$PARAM_LINE" == *"300000000"* ]]; then
  PARAM_REAL="false"
fi

# YAML frontmatter
HAS_FRONTMATTER=$(head -20 "$README" | grep -q "^base_model:" && echo true || echo false)

# --- Verdict ---------------------------------------------------------------
N_LEAKS=$(echo "$LEAK_HITS" | jq 'length')
N_PLACEHOLDERS=$(echo "$PLACEHOLDER_HITS" | jq 'length')
N_MISSING=$(echo "$MISSING_SECTIONS" | jq 'length')

PASS="true"
(( N_LEAKS > 0 )) && PASS="false"
(( N_PLACEHOLDERS > 0 )) && PASS="false"
(( N_MISSING > 0 )) && PASS="false"
[[ "$PARAM_REAL" != "true" ]] && PASS="false"
[[ "$HAS_FRONTMATTER" != "true" ]] && PASS="false"

REPORT=$(jq -n \
  --arg repo "$REPO_ID" \
  --arg pass "$PASS" \
  --argjson leaks "$LEAK_HITS" \
  --argjson placeholders "$PLACEHOLDER_HITS" \
  --argjson missing "$MISSING_SECTIONS" \
  --arg pr "$PARAM_REAL" \
  --arg fm "$HAS_FRONTMATTER" \
  '{
    repo: $repo,
    status: (if $pass=="true" then "pass" else "fail" end),
    checks: {
      d018_leaks: {passed: ($leaks|length == 0), hits: $leaks},
      template_placeholders: {passed: ($placeholders|length == 0), hits: $placeholders},
      required_sections: {passed: ($missing|length == 0), missing: $missing},
      param_count_real: {passed: ($pr == "true")},
      yaml_frontmatter: {passed: ($fm == "true")}
    }
  }')

echo "$REPORT" > "$RUN_DIR/card-validator-report.json"
echo "$REPORT"

rm -f "$README"

if [[ "$PASS" == "true" ]]; then
  exit 0
else
  exit 1
fi
