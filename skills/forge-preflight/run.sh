#!/bin/bash
# forge-preflight: single-shot env readiness. Hard-fails before plan if
# credentials/tools/quota/AZ aren't ready. Caches resolved creds to
# /tmp/forge-creds.env for downstream skills.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../../.."
FORGE_REGION="${FORGE_REGION:-ca-central-1}"
CREDS_FILE="${FORGE_CREDS_FILE:-/tmp/forge-creds.env}"

BLOCKERS_FILE=$(mktemp)
echo "[]" > "$BLOCKERS_FILE"

add_blocker() {
  local check="$1" detail="$2" fix="$3"
  jq --arg c "$check" --arg d "$detail" --arg f "$fix" \
    '. += [{check:$c, detail:$d, fix:$f}]' "$BLOCKERS_FILE" > "$BLOCKERS_FILE.new"
  mv "$BLOCKERS_FILE.new" "$BLOCKERS_FILE"
}

check_tool() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 || \
    add_blocker "tool_$tool" "$tool not found on PATH" "install $tool (apt install $tool or equivalent)"
}

# --- 1. Host tools ---------------------------------------------------------
echo "[preflight] 1/8 host tools..." >&2
for t in jq curl git python3 docker; do check_tool "$t"; done

# --- 2. AWS forge creds ----------------------------------------------------
echo "[preflight] 2/8 AWS forge creds..." >&2
AWS_KEY="${FORGE_AWS_ACCESS_KEY_ID:-}"
AWS_SEC="${FORGE_AWS_SECRET_ACCESS_KEY:-}"

# Try loading from existing creds file
if [[ -z "$AWS_KEY" && -f "$CREDS_FILE" ]]; then
  AWS_KEY=$(grep -oP '(?<=FORGE_AWS_ACCESS_KEY_ID=).*' "$CREDS_FILE" 2>/dev/null || true)
  AWS_SEC=$(grep -oP '(?<=FORGE_AWS_SECRET_ACCESS_KEY=).*' "$CREDS_FILE" 2>/dev/null || true)
fi

# Fall back to vault
if [[ -z "$AWS_KEY" ]]; then
  ENV_FILE="${REPO_ROOT}/.env"
  if [[ -f "$ENV_FILE" ]]; then
    MUSER=$(grep -oP '(?<=MONGO_INITDB_ROOT_USERNAME=).*' "$ENV_FILE" 2>/dev/null || true)
    MPASS=$(grep -oP '(?<=MONGO_INITDB_ROOT_PASSWORD=).*' "$ENV_FILE" 2>/dev/null || true)
    if [[ -n "$MUSER" && -n "$MPASS" ]]; then
      AWS_KEY=$(cd "$REPO_ROOT" && docker compose exec -T mongodb mongosh --quiet \
        -u "$MUSER" -p "$MPASS" --authenticationDatabase admin mediastore \
        --eval 'const c=db.credentials.findOne({envKey:"FORGE_AWS_ACCESS_KEY_ID"}); print(c?c.value:"")' \
        2>/dev/null | grep -v ^time | tail -1)
      AWS_SEC=$(cd "$REPO_ROOT" && docker compose exec -T mongodb mongosh --quiet \
        -u "$MUSER" -p "$MPASS" --authenticationDatabase admin mediastore \
        --eval 'const c=db.credentials.findOne({envKey:"FORGE_AWS_SECRET_ACCESS_KEY"}); print(c?c.value:"")' \
        2>/dev/null | grep -v ^time | tail -1)
    fi
  fi
fi

if [[ -z "$AWS_KEY" || -z "$AWS_SEC" ]]; then
  add_blocker "aws_forge_creds" "FORGE_AWS_ACCESS_KEY_ID + FORGE_AWS_SECRET_ACCESS_KEY not in env, /tmp/forge-creds.env, or vault" \
    "seed credentials in /admin/credentials with envKey=FORGE_AWS_ACCESS_KEY_ID and FORGE_AWS_SECRET_ACCESS_KEY"
fi

AWS_USER=""
if [[ -n "$AWS_KEY" ]]; then
  AWS_USER=$(docker run --rm \
    -e AWS_ACCESS_KEY_ID="$AWS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SEC" \
    -e AWS_DEFAULT_REGION="$FORGE_REGION" \
    amazon/aws-cli:latest sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo "")
  if [[ -z "$AWS_USER" || "$AWS_USER" != *"intellident-forge-provisioner"* ]]; then
    add_blocker "aws_user_wrong" "Resolved AWS keys but user is not intellident-forge-provisioner (got: $AWS_USER)" \
      "rotate FORGE_AWS_ACCESS_KEY_ID to a key for intellident-forge-provisioner IAM user"
  fi
fi

# --- 3. S3 bucket reachable ------------------------------------------------
echo "[preflight] 3/8 S3 bucket..." >&2
if [[ -n "$AWS_KEY" ]]; then
  S3_OK=$(docker run --rm \
    -e AWS_ACCESS_KEY_ID="$AWS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SEC" \
    -e AWS_DEFAULT_REGION="$FORGE_REGION" \
    amazon/aws-cli:latest s3 ls s3://<YOUR_S3_BUCKET>/forge/ >/dev/null 2>&1 && echo yes || echo no)
  if [[ "$S3_OK" != "yes" ]]; then
    add_blocker "s3_unreachable" "Cannot list s3://<YOUR_S3_BUCKET>/forge/" \
      "verify bucket policy allows intellident-forge-provisioner s3:ListBucket on prefix forge/"
  fi
fi

# --- 4. HF token -----------------------------------------------------------
echo "[preflight] 4/8 HF token..." >&2
HF_TOKEN_VAL="${HF_TOKEN:-}"
if [[ -z "$HF_TOKEN_VAL" && -f "$CREDS_FILE" ]]; then
  HF_TOKEN_VAL=$(grep -oP '(?<=HF_TOKEN=).*' "$CREDS_FILE" 2>/dev/null || true)
fi
if [[ -z "$HF_TOKEN_VAL" && -f "${REPO_ROOT}/.env" ]]; then
  HF_TOKEN_VAL=$(grep -oP '(?<=^HF_TOKEN=).*' "${REPO_ROOT}/.env" 2>/dev/null || true)
fi

HF_NS=""
if [[ -z "$HF_TOKEN_VAL" ]]; then
  add_blocker "hf_token" "HF_TOKEN not in env, /tmp/forge-creds.env, or .env" \
    "seed HF_TOKEN in /admin/credentials or .env (write+create scope required)"
else
  HF_INFO=$(curl -sS --max-time 10 -H "Authorization: Bearer $HF_TOKEN_VAL" \
    "https://huggingface.co/api/whoami-v2" 2>/dev/null || echo "{}")
  HF_NS=$(echo "$HF_INFO" | jq -r '.name // ""')
  HF_AUTH_TYPE=$(echo "$HF_INFO" | jq -r '.auth.accessToken.role // .auth.type // ""')
  if [[ -z "$HF_NS" ]]; then
    add_blocker "hf_token_invalid" "HF token rejected by API" \
      "regenerate HF token at https://huggingface.co/settings/tokens"
  fi
  # We don't strictly require write role label — fineGrained tokens with
  # repo:create work fine. We'll let REGISTER fail loudly if perms miss.
fi

# --- 5. Anthropic API key --------------------------------------------------
echo "[preflight] 5/8 Anthropic API key..." >&2
ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-}"
if [[ -z "$ANTHROPIC_KEY" && -f "$CREDS_FILE" ]]; then
  ANTHROPIC_KEY=$(grep -oP '(?<=ANTHROPIC_API_KEY=).*' "$CREDS_FILE" 2>/dev/null || true)
fi
if [[ -z "$ANTHROPIC_KEY" && -f "${REPO_ROOT}/.env" ]]; then
  MUSER=${MUSER:-$(grep -oP '(?<=MONGO_INITDB_ROOT_USERNAME=).*' "${REPO_ROOT}/.env" 2>/dev/null)}
  MPASS=${MPASS:-$(grep -oP '(?<=MONGO_INITDB_ROOT_PASSWORD=).*' "${REPO_ROOT}/.env" 2>/dev/null)}
  if [[ -n "$MUSER" && -n "$MPASS" ]]; then
    ANTHROPIC_KEY=$(cd "$REPO_ROOT" && docker compose exec -T mongodb mongosh --quiet \
      -u "$MUSER" -p "$MPASS" --authenticationDatabase admin mediastore \
      --eval 'const c=db.aiProviders.findOne({apiKey:/^sk-ant/}); print(c?c.apiKey:"")' \
      2>/dev/null | grep -v ^time | tail -1)
  fi
fi
if [[ -z "$ANTHROPIC_KEY" ]]; then
  add_blocker "anthropic_key" "ANTHROPIC_API_KEY not in env, creds file, or aiProviders collection" \
    "add to /admin/custom-agents (sk-ant-...) or env"
fi

# --- 6. G+VT vCPU quota ----------------------------------------------------
echo "[preflight] 6/8 G+VT vCPU quota..." >&2
G_AVAIL=0
G_LIMIT=0
G_BLOCKERS="[]"
if [[ -n "$AWS_KEY" ]]; then
  G_LIMIT=$(docker run --rm \
    -e AWS_ACCESS_KEY_ID="$AWS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SEC" \
    -e AWS_DEFAULT_REGION="$FORGE_REGION" \
    amazon/aws-cli:latest service-quotas get-service-quota \
    --service-code ec2 --quota-code L-DB2E81BA \
    --query 'Quota.Value' --output text 2>/dev/null || echo "0")
  G_LIMIT=${G_LIMIT%.*}

  # Find any running G/VT instances consuming the quota
  G_BLOCKERS=$(docker run --rm \
    -e AWS_ACCESS_KEY_ID="$AWS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SEC" \
    -e AWS_DEFAULT_REGION="$FORGE_REGION" \
    amazon/aws-cli:latest ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running,pending,stopping,shutting-down" \
              "Name=instance-type,Values=g4dn.*,g5.*,g6.*,g6e.*,gr6.*,vt1.*" \
    --query 'Reservations[].Instances[].{id:InstanceId,name:Tags[?Key==`Name`].Value|[0],type:InstanceType}' \
    --output json 2>/dev/null || echo "[]")

  # Order matters — match longer suffixes first (else "xlarge$" eats "2xlarge$").
  IN_USE=$(echo "$G_BLOCKERS" | jq '[.[].type] | map(
    if test("48xlarge$") then 192
    elif test("24xlarge$") then 96
    elif test("16xlarge$") then 64
    elif test("12xlarge$") then 48
    elif test("8xlarge$") then 32
    elif test("4xlarge$") then 16
    elif test("2xlarge$") then 8
    elif test("xlarge$") then 4
    else 0 end
  ) | add // 0')
  G_AVAIL=$((G_LIMIT - IN_USE))

  # Need at least 4 vCPU for g5.xlarge — anything less is a blocker (but
  # we surface the blocking instances so operator can decide to stop them)
  if (( G_AVAIL < 4 )); then
    add_blocker "g_vt_vcpu_quota" "Only $G_AVAIL G+VT vCPUs available (limit $G_LIMIT, in use $IN_USE)" \
      "either request quota increase OR stop blocking instance(s): $(echo "$G_BLOCKERS" | jq -c '.')"
  fi
fi

# --- 7. AZ availability ----------------------------------------------------
echo "[preflight] 7/8 g5.xlarge AZ availability..." >&2
AZS_OK=""
if [[ -n "$AWS_KEY" ]]; then
  AZS_OK=$(docker run --rm \
    -e AWS_ACCESS_KEY_ID="$AWS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$AWS_SEC" \
    -e AWS_DEFAULT_REGION="$FORGE_REGION" \
    amazon/aws-cli:latest ec2 describe-instance-type-offerings \
    --location-type availability-zone \
    --filters "Name=instance-type,Values=g5.xlarge" \
    --query 'InstanceTypeOfferings[].Location' --output text 2>/dev/null || echo "")
  if [[ -z "$AZS_OK" ]]; then
    add_blocker "az_no_g5" "g5.xlarge not offered in any AZ in $FORGE_REGION" \
      "switch FORGE_REGION OR change base instance type in plan"
  fi
fi

# --- 8. Disk headroom ------------------------------------------------------
echo "[preflight] 8/8 disk headroom..." >&2
TMP_FREE_GB=$(df -BG /tmp 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
PWD_FREE_GB=$(df -BG . 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
if (( TMP_FREE_GB < 5 )); then
  add_blocker "disk_tmp" "/tmp has only ${TMP_FREE_GB}G free (need ≥5G)" \
    "free up /tmp or set TMPDIR to a larger volume"
fi
if (( PWD_FREE_GB < 20 )); then
  add_blocker "disk_workdir" "Working dir has only ${PWD_FREE_GB}G free (need ≥20G for HF cache + GGUF staging)" \
    "free up disk or run from a larger volume"
fi

# --- Decision --------------------------------------------------------------
N_BLOCKERS=$(jq 'length' "$BLOCKERS_FILE")
if (( N_BLOCKERS > 0 )); then
  jq -n --slurpfile b "$BLOCKERS_FILE" '{
    status: "fail",
    blockers: $b[0]
  }'
  rm -f "$BLOCKERS_FILE"
  exit 1
fi

# Cache resolved creds for downstream skills
umask 077
cat > "$CREDS_FILE" <<EOF
FORGE_AWS_ACCESS_KEY_ID=$AWS_KEY
FORGE_AWS_SECRET_ACCESS_KEY=$AWS_SEC
HF_TOKEN=$HF_TOKEN_VAL
ANTHROPIC_API_KEY=$ANTHROPIC_KEY
EOF

KEY_PREVIEW="${ANTHROPIC_KEY:0:20}..."

jq -n \
  --arg user "$AWS_USER" \
  --arg ns "$HF_NS" \
  --arg key_prev "$KEY_PREVIEW" \
  --arg azs "$AZS_OK" \
  --argjson g_avail "$G_AVAIL" \
  --argjson g_limit "$G_LIMIT" \
  --argjson g_in_use "${IN_USE:-0}" \
  --argjson g_blockers "$G_BLOCKERS" \
  '{
    status: "pass",
    next_phase: "ANALYZE",
    resolved_creds: {
      aws_user: $user,
      hf_namespace: $ns,
      anthropic_key_preview: $key_prev,
      s3_bucket: "<YOUR_S3_BUCKET>",
      s3_prefix: "forge/"
    },
    available_quota: {
      g_vt_vcpu_total: $g_limit,
      g_vt_vcpu_in_use: $g_in_use,
      g_vt_vcpu_available: $g_avail,
      blocking_instances: $g_blockers
    },
    g5_xlarge_azs: ($azs | split("\\s+"; "g") | map(select(. != "")))
  }'

rm -f "$BLOCKERS_FILE"
exit 0
