#!/usr/bin/env bash
# slm-forge/scripts/check-quota-status.sh
#
# Prints the current status of the AWS Service Quota request that gates
# M4 (G+VT vCPU family in ca-central-1).
#
# Quota request id (filed 2026-04-23 from <YOUR_IAM_USER>):
#   df1f91af3fec4d249288178147f4a021ZBsgUvQ8
#
# Status values per AWS docs:
#   PENDING                 — under review, waiting for AWS to assign
#   CASE_OPENED             — AWS support has the ticket open
#   APPROVED                — granted, new quota active
#   DENIED                  — refused (AWS requires more justification)
#   CASE_CLOSED             — closed without action
#   NOT_APPROVED            — close-with-no-grant
#   INVALID_REQUEST         — bad parameters (shouldn't happen here)
#
# Usage:
#   bash slm-forge/scripts/check-quota-status.sh
#
# Requires: ec2:* + servicequotas:GetRequestedServiceQuotaChange perms.
# Forge user has servicequotas:GetServiceQuota (read) — but
# get-requested-service-quota-change might require a different perm.
# Falls back to <YOUR_IAM_USER> if forge user denied.

set -euo pipefail

QUOTA_REQUEST_ID="${FORGE_QUOTA_REQUEST_ID:-df1f91af3fec4d249288178147f4a021ZBsgUvQ8}"
QUOTA_CODE="${FORGE_QUOTA_CODE:-L-DB2E81BA}"  # Running On-Demand G and VT instances
SERVICE_CODE="ec2"
REGION="${FORGE_REGION:-ca-central-1}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../" && pwd)"

# Resolve creds: prefer FORGE_AWS_*, fall back to .env <YOUR_IAM_USER>.
KEY_ID="${FORGE_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
KEY_SECRET="${FORGE_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"

if [[ -z "$KEY_ID" ]]; then
  # Try .env (forge-scoped first, then plain AWS_*)
  if [[ -f "${REPO}/.env" ]]; then
    KEY_ID=$(grep '^FORGE_AWS_ACCESS_KEY_ID=' "${REPO}/.env" 2>/dev/null | cut -d= -f2 || true)
    KEY_SECRET=$(grep '^FORGE_AWS_SECRET_ACCESS_KEY=' "${REPO}/.env" 2>/dev/null | cut -d= -f2 || true)
  fi
fi

if [[ -z "$KEY_ID" ]]; then
  # Fall back to MongoDB credentials vault (forge-scoped entries)
  if [[ -f "${REPO}/.env" ]]; then
    MONGO_USER=$(grep '^MONGO_INITDB_ROOT_USERNAME=' "${REPO}/.env" 2>/dev/null | cut -d= -f2 || true)
    MONGO_PASS=$(grep '^MONGO_INITDB_ROOT_PASSWORD=' "${REPO}/.env" 2>/dev/null | cut -d= -f2 || true)
    if [[ -n "$MONGO_USER" && -n "$MONGO_PASS" ]]; then
      KEY_ID=$(cd "$REPO" && docker compose exec -T mongodb mongosh --quiet \
        -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin \
        mediastore --eval 'const c=db.credentials.findOne({envKey:"FORGE_AWS_ACCESS_KEY_ID"}); print(c?c.value:"")' 2>/dev/null \
        | grep -v ^time | tail -1 || true)
      KEY_SECRET=$(cd "$REPO" && docker compose exec -T mongodb mongosh --quiet \
        -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin \
        mediastore --eval 'const c=db.credentials.findOne({envKey:"FORGE_AWS_SECRET_ACCESS_KEY"}); print(c?c.value:"")' 2>/dev/null \
        | grep -v ^time | tail -1 || true)
    fi
  fi
fi

if [[ -z "$KEY_ID" ]]; then
  echo "ERROR: no AWS creds available (env, .env, /admin/credentials all empty)" >&2
  exit 1
fi

aws_run() {
  AWS_ACCESS_KEY_ID="$KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$KEY_SECRET" \
  AWS_DEFAULT_REGION="$REGION" \
    docker run --rm \
      -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
      amazon/aws-cli:latest "$@"
}

echo "Quota request: $QUOTA_REQUEST_ID"
echo "Quota code:    $QUOTA_CODE (Running On-Demand G and VT instances)"
echo "Region:        $REGION"
echo ""

# 1. Try to fetch the requested change details
echo "[1] Status of the request:"
if aws_run service-quotas get-requested-service-quota-change \
     --request-id "$QUOTA_REQUEST_ID" \
     --query 'RequestedQuota.[Status,Created,LastUpdated,DesiredValue,QuotaName]' \
     --output table 2>/dev/null; then
  :
else
  echo "  (forge user can't read request details — falling back to current quota value)"
fi

echo ""
echo "[2] Current effective quota value:"
aws_run service-quotas get-service-quota \
  --service-code "$SERVICE_CODE" \
  --quota-code "$QUOTA_CODE" \
  --query 'Quota.[QuotaName,Value,Adjustable]' \
  --output table

echo ""
echo "Interpretation:"
echo "  - If [2] shows 32 (or higher), the quota was GRANTED. M4 unblocked."
echo "  - If [2] still shows 8, the quota is still PENDING. M4 stays parked."
