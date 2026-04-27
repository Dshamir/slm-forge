#!/usr/bin/env bash
# slm-forge/scripts/preflight.sh
#
# Pre-flight check before invoking the forge for real. Verifies every
# prerequisite in one shot. Exits 0 if all GREEN, 1 if any blocker.
#
# Run this FIRST every morning. If green, `scripts/kickoff-real-forge.sh`
# is clear to go. If yellow (quota pending), you can still CPU-train.
# If red, fix before touching anything.
#
# Usage:
#   bash slm-forge/scripts/preflight.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../" && pwd)"
cd "$ROOT"

CORPUS_PATH="${FORGE_CORPUS_PATH:-${ROOT}/slm-forge/corpora/publications.jsonl}"
REGION="${FORGE_REGION:-ca-central-1}"
BUCKET="${FORGE_BUCKET:-<YOUR_S3_BUCKET>}"

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; OFF="\033[0m"
ok()   { echo -e "${GREEN}[✓]${OFF} $*"; }
warn() { echo -e "${YELLOW}[!]${OFF} $*"; }
bad()  { echo -e "${RED}[✗]${OFF} $*"; ANY_BAD=1; }
hdr()  { echo; echo -e "${CYAN}=== $* ===${OFF}"; }

ANY_BAD=0
ANY_WARN=0

# ---- [1] Tools on the host ----------------------------------------------

hdr "[1/7] host tools"
for tool in docker jq curl git python3; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool: $(command -v "$tool")"
  else
    bad "$tool: not installed"
  fi
done

# ---- [2] Git state ------------------------------------------------------

hdr "[2/7] git state"
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
if [[ "$BRANCH" == "poly_updates" ]]; then
  ok "branch: poly_updates"
else
  warn "branch: $BRANCH (expected poly_updates — switch with: git checkout poly_updates)"
  ANY_WARN=1
fi
AHEAD=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo "?")
BEHIND=$(git rev-list --count 'HEAD..@{u}' 2>/dev/null || echo "?")
if [[ "$AHEAD" == "0" && "$BEHIND" == "0" ]]; then
  ok "sync: in-sync with origin"
elif [[ "$BEHIND" != "0" ]]; then
  warn "sync: $BEHIND commits behind origin — run 'git pull'"
  ANY_WARN=1
elif [[ "$AHEAD" != "0" ]]; then
  warn "sync: $AHEAD commits ahead of origin (unpushed local work)"
  ANY_WARN=1
fi
ok "HEAD: $(git log --oneline -1)"

# ---- [3] Corpus file ----------------------------------------------------

hdr "[3/7] corpus"
if [[ -f "$CORPUS_PATH" ]]; then
  SIZE=$(du -h "$CORPUS_PATH" | awk '{print $1}')
  LINES=$(wc -l < "$CORPUS_PATH")
  ok "corpus: $CORPUS_PATH"
  ok "size: $SIZE  ($LINES chunks)"
else
  bad "corpus missing: $CORPUS_PATH"
  bad "  rebuild: bash slm-forge/scripts/prep-publications.py (needs the extracted RAR)"
fi

# ---- [4] HuggingFace token + scope --------------------------------------

hdr "[4/7] HF token"
HF_TOKEN=$(grep '^HF_TOKEN=' "${ROOT}/.env" 2>/dev/null | cut -d= -f2 || echo "")
if [[ -z "$HF_TOKEN" ]]; then
  bad "HF_TOKEN missing from .env"
else
  RESP=$(curl -sS -H "Authorization: Bearer $HF_TOKEN" https://huggingface.co/api/whoami-v2 2>/dev/null)
  HF_NAME=$(echo "$RESP" | jq -r '.name // ""')
  HF_ROLE=$(echo "$RESP" | jq -r '.auth.accessToken.role // .accessToken.role // "?"')
  if [[ -n "$HF_NAME" ]]; then
    ok "namespace: $HF_NAME  (role: $HF_ROLE)"
    # Scope probe: create + delete a throwaway repo
    TS=$(date +%s)
    PROBE="${HF_NAME}/forge-preflight-${TS}"
    PROBE_RESP=$(curl -sS -X POST -H "Authorization: Bearer $HF_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg n "forge-preflight-${TS}" --arg o "$HF_NAME" '{name:$n,organization:$o,type:"model",private:true}')" \
      https://huggingface.co/api/repos/create 2>/dev/null)
    if echo "$PROBE_RESP" | jq -e '.url' >/dev/null 2>&1; then
      ok "repo:create scope: OK"
      # Clean up
      curl -sS -X DELETE -H "Authorization: Bearer $HF_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg n "forge-preflight-${TS}" --arg o "$HF_NAME" '{name:$n,organization:$o,type:"model"}')" \
        https://huggingface.co/api/repos/delete >/dev/null 2>&1
    else
      bad "repo:create scope: MISSING"
      bad "  fix: edit token at https://huggingface.co/settings/tokens — add 'Write access' + 'Create repos' on your namespace"
      bad "  response: $PROBE_RESP"
    fi
  else
    bad "HF_TOKEN rejected: $RESP"
  fi
fi

# ---- [5] Forge AWS creds ------------------------------------------------

hdr "[5/7] AWS forge creds"
# Pull from env → .env → MongoDB vault chain
FORGE_AWS_ACCESS_KEY_ID="${FORGE_AWS_ACCESS_KEY_ID:-}"
FORGE_AWS_SECRET_ACCESS_KEY="${FORGE_AWS_SECRET_ACCESS_KEY:-}"
if [[ -z "$FORGE_AWS_ACCESS_KEY_ID" ]]; then
  MONGO_USER=$(grep '^MONGO_INITDB_ROOT_USERNAME=' "${ROOT}/.env" 2>/dev/null | cut -d= -f2 || true)
  MONGO_PASS=$(grep '^MONGO_INITDB_ROOT_PASSWORD=' "${ROOT}/.env" 2>/dev/null | cut -d= -f2 || true)
  if [[ -n "$MONGO_USER" && -n "$MONGO_PASS" ]]; then
    FORGE_AWS_ACCESS_KEY_ID=$(cd "$ROOT" && docker compose exec -T mongodb mongosh --quiet \
      -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin mediastore \
      --eval 'const c=db.credentials.findOne({envKey:"FORGE_AWS_ACCESS_KEY_ID"}); print(c?c.value:"")' \
      2>/dev/null | grep -v ^time | tail -1 || true)
    FORGE_AWS_SECRET_ACCESS_KEY=$(cd "$ROOT" && docker compose exec -T mongodb mongosh --quiet \
      -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin mediastore \
      --eval 'const c=db.credentials.findOne({envKey:"FORGE_AWS_SECRET_ACCESS_KEY"}); print(c?c.value:"")' \
      2>/dev/null | grep -v ^time | tail -1 || true)
  fi
fi
if [[ -z "$FORGE_AWS_ACCESS_KEY_ID" || -z "$FORGE_AWS_SECRET_ACCESS_KEY" ]]; then
  bad "FORGE_AWS_ACCESS_KEY_ID / FORGE_AWS_SECRET_ACCESS_KEY missing (env / .env / MongoDB vault)"
else
  ok "keys resolved (ID len=${#FORGE_AWS_ACCESS_KEY_ID} secret len=${#FORGE_AWS_SECRET_ACCESS_KEY})"
  IDENTITY=$(AWS_ACCESS_KEY_ID="$FORGE_AWS_ACCESS_KEY_ID" \
             AWS_SECRET_ACCESS_KEY="$FORGE_AWS_SECRET_ACCESS_KEY" \
             AWS_DEFAULT_REGION="$REGION" \
             docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
               amazon/aws-cli:latest sts get-caller-identity --query 'Arn' --output text 2>&1)
  if echo "$IDENTITY" | grep -q "intellident-forge-provisioner"; then
    ok "identity: $IDENTITY"
    ok "S3 access: "
    if AWS_ACCESS_KEY_ID="$FORGE_AWS_ACCESS_KEY_ID" \
       AWS_SECRET_ACCESS_KEY="$FORGE_AWS_SECRET_ACCESS_KEY" \
       AWS_DEFAULT_REGION="$REGION" \
       docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
         amazon/aws-cli:latest s3api list-objects-v2 --bucket "$BUCKET" --prefix forge/ --max-keys 1 \
         --query 'KeyCount' --output text 2>/dev/null >/dev/null; then
      ok "  bucket: s3://$BUCKET/forge/ accessible"
    else
      bad "  s3://$BUCKET/forge/ NOT accessible"
    fi
  else
    bad "identity resolved unexpected: $IDENTITY"
  fi
fi

# ---- [6] AWS G+VT vCPU quota --------------------------------------------

hdr "[6/7] AWS G+VT vCPU quota (gates GPU training)"
QUOTA_VAL=$(AWS_ACCESS_KEY_ID="$FORGE_AWS_ACCESS_KEY_ID" \
            AWS_SECRET_ACCESS_KEY="$FORGE_AWS_SECRET_ACCESS_KEY" \
            AWS_DEFAULT_REGION="$REGION" \
            docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
              amazon/aws-cli:latest \
              service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA \
              --query 'Quota.Value' --output text 2>/dev/null | head -1)
QUOTA_INT="${QUOTA_VAL%.*}"
if [[ -z "$QUOTA_VAL" ]]; then
  bad "quota lookup failed"
elif (( QUOTA_INT >= 8 )) && (( QUOTA_INT >= 8 )); then
  # g4dn.2xlarge consumes 8; need at least 12 for g5.xlarge (+4) to launch alongside.
  # If quota >= 32, plenty of headroom.
  if (( QUOTA_INT >= 32 )); then
    ok "quota: ${QUOTA_VAL}  — ready for GPU training"
  elif (( QUOTA_INT >= 12 )); then
    ok "quota: ${QUOTA_VAL}  — enough for a single g5.xlarge alongside burst"
  elif (( QUOTA_INT == 8 )); then
    warn "quota: ${QUOTA_VAL}  — still default. request not granted yet."
    warn "  check: bash slm-forge/scripts/check-quota-status.sh"
    warn "  workaround: CPU training on t3.xlarge (slow — many hours for real corpus)"
    ANY_WARN=1
  else
    warn "quota: ${QUOTA_VAL}  — unusual value"
    ANY_WARN=1
  fi
fi

# ---- [7] Docker images pre-warmed (optional) ----------------------------

hdr "[7/7] Docker images (optional)"
for img in amazon/aws-cli:latest python:3.11-slim ubuntu:22.04; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    ok "cached: $img"
  else
    warn "not cached: $img  (will pull on first use, adds ~30 s)"
  fi
done

# ---- Summary ------------------------------------------------------------

echo
echo "═══════════════════════════════════════════════════════════════════"
if (( ANY_BAD == 0 )) && (( ANY_WARN == 0 )); then
  echo -e "${GREEN}  PREFLIGHT PASS — forge is clear to go for GPU run${OFF}"
elif (( ANY_BAD == 0 )); then
  echo -e "${YELLOW}  PREFLIGHT YELLOW — core infra OK, but quota not yet granted${OFF}"
  echo -e "${YELLOW}  Options:${OFF}"
  echo "    1. Wait for quota grant (check: bash slm-forge/scripts/check-quota-status.sh)"
  echo "    2. Run on t3.xlarge CPU (set FORGE_INSTANCE_TYPE_OVERRIDE=t3.xlarge;"
  echo "       cap training to MAX_STEPS=500 for ~1 hour CPU run)"
else
  echo -e "${RED}  PREFLIGHT FAIL — blockers above must be fixed first${OFF}"
fi
echo "═══════════════════════════════════════════════════════════════════"

(( ANY_BAD == 0 )) && exit 0 || exit 1
