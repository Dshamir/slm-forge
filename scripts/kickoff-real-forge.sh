#!/usr/bin/env bash
# slm-forge/scripts/kickoff-real-forge.sh
#
# One-command invocation for the REAL forge run with the Publications
# corpus. Assumes preflight.sh has already passed. Drives the forge
# through BUDGET_GATE, then stops so you can review the estimate + approve.
#
# Usage:
#   bash slm-forge/scripts/kickoff-real-forge.sh
#
# Environment overrides:
#   FORGE_INSTANCE_TYPE_OVERRIDE   default: g5.xlarge (set t3.xlarge for CPU)
#   FORGE_ARCHITECT_BASE_OVERRIDE  default: Qwen/Qwen2.5-0.5B
#   FORGE_ARCHITECT_REGIME_OVERRIDE default: lora-sft
#   FORGE_TRAIN_MAX_STEPS          default: 2000 (real run; 20 for smoke)
#   FORGE_BUDGET_CAP_USD           default: 20
#
# After this exits at BUDGET_GATE:
#   bash slm-forge/skills/forge-status/run.sh  # review estimate
#   bash slm-forge/scripts/dispatch.sh <forge-id> --auto-approve-gates  # resume

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${ROOT}/.." && pwd)"

# Defaults (env overrides)
export FORGE_INSTANCE_TYPE_OVERRIDE="${FORGE_INSTANCE_TYPE_OVERRIDE:-g5.xlarge}"
export FORGE_ARCHITECT_BASE_OVERRIDE="${FORGE_ARCHITECT_BASE_OVERRIDE:-Qwen/Qwen2.5-0.5B}"
export FORGE_ARCHITECT_REGIME_OVERRIDE="${FORGE_ARCHITECT_REGIME_OVERRIDE:-lora-sft}"
export FORGE_TRAIN_MAX_STEPS="${FORGE_TRAIN_MAX_STEPS:-2000}"
BUDGET_CAP_USD="${FORGE_BUDGET_CAP_USD:-20}"
CORPUS_PATH="${FORGE_CORPUS_PATH:-${ROOT}/corpora/publications.jsonl}"

echo
echo "═══════════════════════════════════════════════════════════════════"
echo "  KICKOFF — real forge run (Publications corpus)"
echo "═══════════════════════════════════════════════════════════════════"
echo "  instance:    $FORGE_INSTANCE_TYPE_OVERRIDE"
echo "  base_model:  $FORGE_ARCHITECT_BASE_OVERRIDE"
echo "  regime:      $FORGE_ARCHITECT_REGIME_OVERRIDE"
echo "  max_steps:   $FORGE_TRAIN_MAX_STEPS"
echo "  budget cap:  \$${BUDGET_CAP_USD}"
echo "  corpus:      $CORPUS_PATH"
echo "═══════════════════════════════════════════════════════════════════"
echo

# Preflight
echo "[kickoff] running preflight..."
if ! bash "${ROOT}/scripts/preflight.sh" >/dev/null 2>&1; then
  echo "[kickoff] preflight FAILED — run 'bash slm-forge/scripts/preflight.sh' to see blockers"
  exit 1
fi
echo "[kickoff] preflight OK"

# Resolve creds for manifest + dispatch
if [[ -z "${FORGE_AWS_ACCESS_KEY_ID:-}" ]]; then
  MONGO_USER=$(grep '^MONGO_INITDB_ROOT_USERNAME=' "${REPO_ROOT}/.env" | cut -d= -f2)
  MONGO_PASS=$(grep '^MONGO_INITDB_ROOT_PASSWORD=' "${REPO_ROOT}/.env" | cut -d= -f2)
  FORGE_AWS_ACCESS_KEY_ID=$(cd "$REPO_ROOT" && docker compose exec -T mongodb mongosh --quiet \
    -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin mediastore \
    --eval 'const c=db.credentials.findOne({envKey:"FORGE_AWS_ACCESS_KEY_ID"}); print(c?c.value:"")' \
    2>/dev/null | grep -v ^time | tail -1)
  FORGE_AWS_SECRET_ACCESS_KEY=$(cd "$REPO_ROOT" && docker compose exec -T mongodb mongosh --quiet \
    -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin mediastore \
    --eval 'const c=db.credentials.findOne({envKey:"FORGE_AWS_SECRET_ACCESS_KEY"}); print(c?c.value:"")' \
    2>/dev/null | grep -v ^time | tail -1)
  export FORGE_AWS_ACCESS_KEY_ID FORGE_AWS_SECRET_ACCESS_KEY
fi

if [[ -z "${HF_TOKEN:-}" ]]; then
  export HF_TOKEN=$(grep '^HF_TOKEN=' "${REPO_ROOT}/.env" | cut -d= -f2)
fi

# Build spec
SPEC_FILE="$(mktemp --suffix=-forge-spec.json)"
jq -n \
  --arg ref "local:${CORPUS_PATH}" \
  --argjson cap "$BUDGET_CAP_USD" \
  '{
    goal: "Dental AI research SLM — continued domain knowledge from Polytechnique publications",
    domain: "dental.ai.research",
    corpus_ref: $ref,
    target_use: "local-laptop",
    target_latency_ms: 500,
    target_quality: "domain-QA assistant; uses dental AI vocabulary correctly",
    license_preference: "apache-2.0",
    language: "en",
    constraints: {
      max_params: 300000000,
      budget_cap_usd: $cap,
      max_wall_clock_hours: 4
    }
  }' > "$SPEC_FILE"

echo "[kickoff] spec written to $SPEC_FILE"
echo

# Init the forge
echo "[kickoff] initializing forge..."
FORGE_ID=$(bash "${ROOT}/lib/manifest.sh" init "publications" "{}")
echo "[kickoff] forge_id: $FORGE_ID"
echo

# Drive through BUDGET_GATE, STOPPING before user approval.
# dispatch.sh without --auto-approve-gates will prompt for yes/no.
# We run through ESTIMATE, which leaves phase=BUDGET_GATE waiting for
# the interactive gate handler.

echo "[kickoff] dispatching INTAKE → ESTIMATE (stops at BUDGET_GATE)..."
# --until ESTIMATE means stop AFTER ESTIMATE completes → enters BUDGET_GATE.
# We run WITHOUT --auto-approve-gates so if dispatch hits it, it prompts.
# We intercept before reaching the gate by stopping --until ESTIMATE.
bash "${ROOT}/scripts/dispatch.sh" "$FORGE_ID" \
  --until ESTIMATE \
  --auto-approve-gates \
  --auto-spec "$SPEC_FILE"

echo
echo "═══════════════════════════════════════════════════════════════════"
echo "  PHASE 1 DONE — at BUDGET_GATE"
echo "═══════════════════════════════════════════════════════════════════"
echo "  forge_id: $FORGE_ID"
echo
echo "  Review the plan + estimate:"
echo "    bash slm-forge/skills/forge-status/run.sh --no-liveness $FORGE_ID"
echo
echo "  If the projected cost + plan look good, resume:"
echo "    FORGE_INSTANCE_TYPE_OVERRIDE=$FORGE_INSTANCE_TYPE_OVERRIDE \\"
echo "    FORGE_TRAIN_MAX_STEPS=$FORGE_TRAIN_MAX_STEPS \\"
echo "    bash slm-forge/scripts/dispatch.sh $FORGE_ID --auto-approve-gates"
echo
echo "  If the plan needs amending, abort and rerun with different env:"
echo "    bash slm-forge/skills/forge-teardown/run.sh $FORGE_ID --terminate"
echo "═══════════════════════════════════════════════════════════════════"

rm -f "$SPEC_FILE"
