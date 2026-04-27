#!/bin/bash
# forge-plan-fit: 7-axis pre-training plan validation gate.
# Reads the run's artifacts and plan.json, grades Q/A via Claude, validates
# budget headroom. Fails the forge before GPU spend if any axis fails.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../../.."

RUN_ID="${1:-}"
if [[ -z "$RUN_ID" ]]; then
  echo "usage: $0 <run-id>" >&2; exit 64
fi
RUN_DIR="${REPO_ROOT}/slm-forge/.runs/${RUN_ID}"
PLAN="$RUN_DIR/plan.json"

if [[ ! -f "$PLAN" ]]; then
  echo "plan-fit: plan.json missing at $PLAN" >&2; exit 1
fi

# Locate a Q/A file. Shape uploads to S3 but does not persist locally;
# qa-filtered.jsonl (synth output) is the same chat-format data plan_fit
# wants for Axis 1/3 grading, just unsplit.
QA_FILE=""
for candidate in \
  "$RUN_DIR/qa-shaped.jsonl" \
  "$RUN_DIR/shaped/train.jsonl" \
  "$RUN_DIR/qa-filtered.jsonl" \
  "$RUN_DIR/qa.jsonl"
do
  if [[ -s "$candidate" ]]; then QA_FILE="$candidate"; break; fi
done
if [[ -z "$QA_FILE" ]]; then
  echo "plan-fit: no Q/A file found in $RUN_DIR" >&2; exit 1
fi

AUDIT_REPORT="$RUN_DIR/audit-report.json"
OUT_REPORT="$RUN_DIR/plan-fit-report.json"

BASE_MODEL=$(jq -r '.base_model.hf_repo' "$PLAN")
DOMAIN=$(jq -r '.domain' "$PLAN")
OVERRIDES=$(jq -c '.training_overrides' "$PLAN")

export FORGE_PLAN_FIT_QA_FILE="$QA_FILE"
export FORGE_PLAN_FIT_AUDIT_REPORT="$AUDIT_REPORT"
export FORGE_PLAN_FIT_TRAINING_OVERRIDES="$OVERRIDES"
export FORGE_PLAN_FIT_BASE_MODEL="$BASE_MODEL"
export FORGE_PLAN_FIT_DOMAIN="$DOMAIN"
export FORGE_PLAN_FIT_OUT_REPORT="$OUT_REPORT"
export FORGE_PLAN_FIT_PLAN_JSON="$PLAN"
export FORGE_PLAN_FIT_SYNTH_PROGRESS="$RUN_DIR/synth-progress.json"

# Honor plan.json acceptance_thresholds — without this, plan_fit.py falls back
# to hardcoded defaults (4.2 mean, 3.0 min, 0.95 in-domain) which are stricter
# than what the plan actually committed to (visible in plan.md gate table).
mqm=$(jq -r '.acceptance_thresholds.plan_fit_min_qa_mean // empty' "$PLAN")
mqi=$(jq -r '.acceptance_thresholds.plan_fit_min_qa_individual // empty' "$PLAN")
mid=$(jq -r '.acceptance_thresholds.plan_fit_min_in_domain_pct // empty' "$PLAN")
mtp=$(jq -r '.acceptance_thresholds.plan_fit_max_type_pct // empty' "$PLAN")
[[ -n "$mqm" ]] && export FORGE_PLAN_FIT_MIN_QA_MEAN="$mqm"
[[ -n "$mqi" ]] && export FORGE_PLAN_FIT_MIN_QA_INDIVIDUAL="$mqi"
[[ -n "$mid" ]] && export FORGE_PLAN_FIT_MIN_DOMAIN_PCT="$mid"
[[ -n "$mtp" ]] && export FORGE_PLAN_FIT_MAX_TYPE_PCT="$mtp"

# Reuse synth's venv which already has anthropic>=0.40 installed.
# PEP 668 blocks system pip install on Debian/Ubuntu so a venv is required.
VENV="${FORGE_VENV:-/tmp/forge-venv}"
if [[ ! -x "$VENV/bin/python" ]]; then
  echo "[plan-fit] creating venv at $VENV (one-time)..." >&2
  python3 -m venv "$VENV" >&2
  "$VENV/bin/pip" install --quiet 'anthropic>=0.40' >&2
fi
# Ensure anthropic is actually available (synth might have been skipped on resume)
"$VENV/bin/python" -c "import anthropic" 2>/dev/null || \
  "$VENV/bin/pip" install --quiet 'anthropic>=0.40' >&2

exec "$VENV/bin/python" "$SCRIPT_DIR/plan_fit.py"
