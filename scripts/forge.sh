#!/bin/bash
# forge.sh: the master /slm-forge entry point.
# Usage: forge <target-dir> <budget-usd> [--domain <label>]
#
# Runs PREFLIGHT → ANALYZE → PLAN, then prints the plan.md path to stdout
# and exits. The operator reviews plan.md, then runs approve-plan.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."
SKILLS="${REPO_ROOT}/slm-forge/skills"

TARGET="${1:-}"
BUDGET="${2:-}"
DOMAIN_OVERRIDE=""
shift 2 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN_OVERRIDE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

if [[ -z "$TARGET" || -z "$BUDGET" ]]; then
  cat <<EOF
usage: /slm-forge <target> <budget-usd> [--domain <label>]

  target:      one of:
                 - a directory of mixed documents
                 - a single .jsonl file (pretrain or chat format)
                 - a multi-source config.yaml (sources: from dirs / DBs / URLs)
  budget-usd:  hard cap on total spend (Claude API + GPU)
  --domain:    optional explicit domain label (auto-detected via Claude if absent)

Examples:
  /slm-forge ./Publications/ 75
  /slm-forge ./qa-data.jsonl 25 --domain dental.ai.research
  /slm-forge ./multi-sources.yaml 100
EOF
  exit 64
fi

# Step 1: PREFLIGHT
echo "=== PREFLIGHT ==="
PREFLIGHT_OUT=$(bash "${SKILLS}/forge-preflight/run.sh" 2>/dev/null) || true
PREFLIGHT_STATUS=$(echo "$PREFLIGHT_OUT" | jq -r '.status' 2>/dev/null || echo "fail")
if [[ "$PREFLIGHT_STATUS" != "pass" ]]; then
  echo "❌ preflight FAILED — fix these blockers before forging:"
  echo "$PREFLIGHT_OUT" | jq -r '.blockers[] | "  - [\(.check)] \(.detail)\n      fix: \(.fix)"'
  exit 1
fi
echo "✅ preflight pass"
echo "$PREFLIGHT_OUT" | jq -r '"   AWS user: \(.resolved_creds.aws_user)\n   HF namespace: \(.resolved_creds.hf_namespace)\n   G+VT vCPU available: \(.available_quota.g_vt_vcpu_available) of \(.available_quota.g_vt_vcpu_total)"'

# If quota is tight, surface it
QUOTA_AVAIL=$(echo "$PREFLIGHT_OUT" | jq -r '.available_quota.g_vt_vcpu_available')
if (( QUOTA_AVAIL < 4 )); then
  echo
  echo "⚠️  Only $QUOTA_AVAIL vCPUs available — g5.xlarge needs 4. Blocking instance(s):"
  echo "$PREFLIGHT_OUT" | jq -r '.available_quota.blocking_instances[] | "    - \(.id) (\(.name), \(.type))"'
  echo
  echo "  Either stop them OR request quota increase, then re-run."
  exit 1
fi

# Step 2: ANALYZE
echo
echo "=== ANALYZE ==="
ANALYSIS_OUT=$(bash "${SKILLS}/forge-analyze/run.sh" "$TARGET" "$DOMAIN_OVERRIDE")
RUN_ID=$(echo "$ANALYSIS_OUT" | jq -r '.run_id')
RUN_DIR="${REPO_ROOT}/slm-forge/.runs/${RUN_ID}"
echo "$ANALYSIS_OUT" | jq -r '"   files: \(.input_inventory.total_files) (\(.input_inventory.total_size_mb) MB)\n   format: \(.detected_format)\n   domain: \(.domain_signal.label) (\(.domain_signal.via))\n   est tokens: \(.input_inventory.estimated_raw_tokens)"'

# Step 3: PLAN
echo
echo "=== PLAN ==="
PLAN_PATH=$(bash "${SKILLS}/forge-plan/run.sh" "$RUN_DIR/analysis.json" "$BUDGET" 2>&1) || PLAN_RC=$?
PLAN_RC=${PLAN_RC:-0}

if (( PLAN_RC == 2 )); then
  echo "🛑 PLAN REFUSED — over budget"
  cat "$RUN_DIR/plan-refused.md"
  exit 2
elif (( PLAN_RC != 0 )); then
  echo "❌ plan generation failed (rc=$PLAN_RC)"
  echo "$PLAN_PATH"
  exit 1
fi

echo "✅ plan ready: $PLAN_PATH"
echo
echo "═══════════════════════════════════════════════════════════════"
echo "  Review the plan, then ONE of:"
echo
echo "    APPROVE: bash ${SCRIPT_DIR}/approve-plan.sh ${RUN_ID}"
echo "    REJECT:  bash ${SCRIPT_DIR}/teardown-run.sh ${RUN_ID}"
echo "═══════════════════════════════════════════════════════════════"
