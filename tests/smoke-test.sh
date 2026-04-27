#!/usr/bin/env bash
# slm-forge/tests/smoke-test.sh
#
# End-to-end smoke harness. Run modes:
#   --init-only             M1 — manifest init + load + patch + version check (no spend)
#   --through SHAPE         M2 — data path through SHAPE (no AWS spend, local exec)
#   --through BOOTSTRAP --then-teardown
#                           M3 — provision + bootstrap + teardown ($1-2 spend)
#   --full-train --quick    M4 — tiny model + tiny corpus, ~5 min ($1)
#   --full                  M5+ — full pipeline including HF Space publish (~$2)
#
# Exit code 0 = smoke pass; non-zero = failure.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
FIXTURE="${ROOT}/tests/fixtures/tiny-corpus"

MODE=""
THROUGH=""
THEN_TEARDOWN=""
QUICK=""
SKIP_BOOTSTRAP=""
FORGE_ID_FROM_PRIOR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --init-only)        MODE="init-only"; shift ;;
    --through)          MODE="through"; THROUGH="$2"; shift 2 ;;
    --then-teardown)    THEN_TEARDOWN="yes"; shift ;;
    --full-train)       MODE="full-train"; shift ;;
    --quick)            QUICK="yes"; shift ;;
    --full)             MODE="full"; shift ;;
    --skip-bootstrap)   SKIP_BOOTSTRAP="yes"; shift ;;
    --resume)           FORGE_ID_FROM_PRIOR="$2"; shift 2 ;;
    --help|-h)
      sed -n '3,12p' "$0"; exit 0 ;;
    *)
      echo "smoke-test: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "smoke-test: must specify a mode (--init-only|--through PHASE|--full-train|--full)" >&2
  exit 64
fi

# ---- Cred sourcing -----------------------------------------------------

# Pull FORGE_AWS_* from .env in the repo root if not already in env (grep
# tolerated to fail under set -e via `|| true`).
if [[ -z "${FORGE_AWS_ACCESS_KEY_ID:-}" || -z "${FORGE_AWS_SECRET_ACCESS_KEY:-}" ]]; then
  ENV_FILE="${ROOT}/../.env"
  if [[ -f "$ENV_FILE" ]]; then
    FORGE_AWS_ACCESS_KEY_ID=$(grep '^FORGE_AWS_ACCESS_KEY_ID=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
    FORGE_AWS_SECRET_ACCESS_KEY=$(grep '^FORGE_AWS_SECRET_ACCESS_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
    export FORGE_AWS_ACCESS_KEY_ID FORGE_AWS_SECRET_ACCESS_KEY
  fi
fi

# Fallback: pull from /admin/credentials via mongosh
if [[ -z "${FORGE_AWS_ACCESS_KEY_ID:-}" ]]; then
  echo "[smoke] FORGE_AWS_* not in env or .env — attempting MongoDB vault..." >&2
  REPO_ROOT="${ROOT}/.."
  MONGO_USER=$(grep '^MONGO_INITDB_ROOT_USERNAME=' "$REPO_ROOT/.env" 2>/dev/null | cut -d= -f2 || true)
  MONGO_PASS=$(grep '^MONGO_INITDB_ROOT_PASSWORD=' "$REPO_ROOT/.env" 2>/dev/null | cut -d= -f2 || true)
  if [[ -n "$MONGO_USER" && -n "$MONGO_PASS" ]]; then
    FORGE_AWS_ACCESS_KEY_ID=$(cd "$REPO_ROOT" && docker compose exec -T mongodb mongosh --quiet \
      -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin \
      mediastore --eval 'const c=db.credentials.findOne({envKey:"FORGE_AWS_ACCESS_KEY_ID"}); print(c?c.value:"")' 2>/dev/null \
      | grep -v ^time | tail -1 || true)
    FORGE_AWS_SECRET_ACCESS_KEY=$(cd "$REPO_ROOT" && docker compose exec -T mongodb mongosh --quiet \
      -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin \
      mediastore --eval 'const c=db.credentials.findOne({envKey:"FORGE_AWS_SECRET_ACCESS_KEY"}); print(c?c.value:"")' 2>/dev/null \
      | grep -v ^time | tail -1 || true)
    export FORGE_AWS_ACCESS_KEY_ID FORGE_AWS_SECRET_ACCESS_KEY
  fi
fi

if [[ -z "${FORGE_AWS_ACCESS_KEY_ID:-}" ]]; then
  echo "[smoke] FATAL: cannot resolve FORGE_AWS_*" >&2
  exit 1
fi
echo "[smoke] FORGE_AWS_* resolved (length ID=${#FORGE_AWS_ACCESS_KEY_ID})"

# ---- Source libs -------------------------------------------------------

# shellcheck source=../lib/manifest.sh
source "${LIB}/manifest.sh"
# shellcheck source=../lib/s3.sh
source "${LIB}/s3.sh"

# ---- Cleanup helpers ---------------------------------------------------

CLEANUP_FORGE_IDS=()

cleanup() {
  local rc=${1:-$?}
  for fid in "${CLEANUP_FORGE_IDS[@]:-}"; do
    [[ -z "$fid" ]] && continue
    echo "[smoke:cleanup] Removing test forge $fid from S3 (best-effort)..."
    _s3_aws s3 rm "s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${fid}/" --recursive 2>/dev/null || true
    rm -f "${FORGE_WORK:-${HOME}/.slm-forge}/manifests/${fid}.json"
  done
  exit $rc
}
# Capture the real exit code at trap fire, before any cleanup runs.
trap '_smoke_rc=$?; cleanup $_smoke_rc' EXIT

# ---- Mode: --init-only -------------------------------------------------

run_init_only() {
  echo "[smoke:init-only] Step 1: bucket sanity"
  s3_check_bucket

  echo "[smoke:init-only] Step 2: manifest init"
  local fid
  fid=$(manifest_init "smoke-init-only" '{"goal":"smoke-test"}')
  CLEANUP_FORGE_IDS+=("$fid")
  echo "  forge_id: $fid"

  echo "[smoke:init-only] Step 3: manifest load"
  local m
  m=$(manifest_load "$fid" 2> >(grep '^version-id:' >&2))
  echo "  loaded $(echo "$m" | jq -r '.forge_id') @ phase=$(echo "$m" | jq -r '.phase')"

  echo "[smoke:init-only] Step 4: schema validation on loaded manifest"
  manifest_validate "$m"
  echo "  schema OK"

  echo "[smoke:init-only] Step 5: round-trip diff (local vs S3)"
  local local_path
  local_path="${FORGE_WORK:-${HOME}/.slm-forge}/manifests/${fid}.json"
  if ! diff <(jq -S . "$local_path") <(echo "$m" | jq -S .) >/dev/null; then
    echo "  WARN: local vs S3 manifest differ (expected if a save happened mid-run)" >&2
  else
    echo "  local==S3 byte-for-byte (after jq normalization)"
  fi

  echo "[smoke:init-only] Step 6: manifest_patch — append a note, verify it persists"
  manifest_patch "$fid" '.notes += [{"by":"smoke-test","at":now|todate,"text":"M1 smoke pass"}]'
  local patched
  patched=$(manifest_load "$fid")
  local note_count
  note_count=$(echo "$patched" | jq '.notes | length')
  if [[ "$note_count" != "1" ]]; then
    echo "  FAIL: expected 1 note after patch, got $note_count" >&2
    exit 1
  fi
  echo "  notes count = $note_count ✓"

  echo "[smoke:init-only] Step 7: list S3 objects under forge prefix"
  local count
  count=$(s3_ls "$fid" | wc -l)
  echo "  $count object(s) under forge/$fid/"
  if [[ "$count" -lt 1 ]]; then
    echo "  FAIL: expected at least 1 object" >&2
    exit 1
  fi

  echo "[smoke:init-only] Step 8: manifest_set_current + manifest_current_forge round-trip"
  local cur
  cur=$(manifest_current_forge)
  if [[ "$cur" != "$fid" ]]; then
    echo "  FAIL: current-forge pointer = '$cur', expected '$fid'" >&2
    exit 1
  fi
  echo "  current-forge pointer = $fid ✓"

  echo ""
  echo "[smoke:init-only] PASS — manifest lifecycle verified"
  echo "  forge_id: $fid"
  echo "  S3 location: s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${fid}/manifest.json"
  echo "  local mirror: $local_path"
  echo "  notes: $note_count"
  echo "  cleanup will remove this test forge on exit."
}

run_through_shape() {
  local fixture="${1:-tiny-corpus}"
  local fixture_dir="${FIXTURE}"
  if [[ "$fixture" != "tiny-corpus" ]]; then
    echo "[smoke:through-shape] fixture '$fixture' not available (only tiny-corpus today)" >&2
    exit 64
  fi
  if [[ ! -f "${fixture_dir}/docs.jsonl" ]]; then
    echo "[smoke:through-shape] fixture missing at ${fixture_dir}/docs.jsonl" >&2
    exit 1
  fi

  echo "[smoke:through-shape] Step 1: bucket sanity"
  s3_check_bucket

  echo "[smoke:through-shape] Step 2: manifest init (empty spec; forge-intake populates via --auto-spec)"
  local fid
  fid=$(manifest_init "smoke-through-shape" '{}')
  CLEANUP_FORGE_IDS+=("$fid")
  echo "  forge_id: $fid"

  echo "[smoke:through-shape] Step 3: write auto-spec fixture"
  local auto_spec_file="${WORK_TMP:-/tmp}/.smoke-auto-spec-$$.json"
  jq -n \
    --arg ref "local:${fixture_dir}/docs.jsonl" \
    '{
      goal: "smoke test: dental patient education SLM from tiny corpus",
      domain: "dental.patient-education",
      corpus_ref: $ref,
      target_use: "local-laptop",
      target_latency_ms: 500,
      target_quality: "smoke-test-only",
      license_preference: "apache-2.0",
      language: "en",
      constraints: {
        max_params: 200000000,
        budget_cap_usd: 10,
        max_wall_clock_hours: 1
      }
    }' > "$auto_spec_file"

  echo "[smoke:through-shape] Step 4: bootstrap INIT → INTAKE"
  # dispatch.sh handles the INIT → INTAKE bump itself, but we trigger it
  # by invoking dispatch with --until SHAPE --auto-approve-gates.
  bash "${ROOT}/scripts/dispatch.sh" "$fid" \
    --until SHAPE \
    --auto-approve-gates \
    --auto-spec "$auto_spec_file"

  echo "[smoke:through-shape] Step 5: verify final manifest state"
  local final
  final=$(manifest_load "$fid" 2>/dev/null)

  local phase raw_uri curated_uri shaped_uri
  phase=$(echo "$final"       | jq -r .phase)
  raw_uri=$(echo "$final"     | jq -r '.artifacts.raw_corpus_s3 // "null"')
  curated_uri=$(echo "$final" | jq -r '.artifacts.curated_corpus_s3 // "null"')
  shaped_uri=$(echo "$final"  | jq -r '.artifacts.shaped_corpus_s3 // "null"')

  local ok=1
  [[ "$phase" == "PROVISION" ]] || { echo "  FAIL: phase=$phase, expected PROVISION" >&2; ok=0; }
  [[ "$raw_uri" != "null" ]]     || { echo "  FAIL: raw_corpus_s3 not set" >&2; ok=0; }
  [[ "$curated_uri" != "null" ]] || { echo "  FAIL: curated_corpus_s3 not set" >&2; ok=0; }
  [[ "$shaped_uri" != "null" ]]  || { echo "  FAIL: shaped_corpus_s3 not set" >&2; ok=0; }

  echo "  phase:         $phase"
  echo "  raw_corpus_s3:     $raw_uri"
  echo "  curated_corpus_s3: $curated_uri"
  echo "  shaped_corpus_s3:  $shaped_uri"

  echo "[smoke:through-shape] Step 6: phase_history completeness"
  local expected_phases=(INIT INTAKE ARCHITECT ESTIMATE BUDGET_GATE SOURCE CURATE SHAPE PROVISION)
  local missing=""
  for p in "${expected_phases[@]}"; do
    if ! echo "$final" | jq -e ".phase_history | any(.phase == \"$p\")" >/dev/null 2>&1; then
      missing+=" $p"
    fi
  done
  if [[ -n "$missing" ]]; then
    echo "  FAIL: phase_history missing:$missing" >&2
    ok=0
  else
    echo "  phase_history has all 9 expected phases ✓"
  fi

  echo "[smoke:through-shape] Step 7: budget gate resolution"
  local gate_status
  gate_status=$(echo "$final" | jq -r '.gates.budget_gate.status')
  [[ "$gate_status" == "passed" ]] || { echo "  FAIL: budget_gate=$gate_status" >&2; ok=0; }
  echo "  budget_gate: $gate_status ✓"

  echo "[smoke:through-shape] Step 8: S3 artifact existence"
  local raw_count curated_count shaped_count
  raw_count=$(s3_ls "$fid" "data/raw/" | wc -l)
  curated_count=$(s3_ls "$fid" "data/curated/" | wc -l)
  shaped_count=$(s3_ls "$fid" "data/shaped/" | wc -l)
  [[ "$raw_count" -gt 0 ]]     || { echo "  FAIL: 0 objects in data/raw/" >&2; ok=0; }
  [[ "$curated_count" -gt 0 ]] || { echo "  FAIL: 0 objects in data/curated/" >&2; ok=0; }
  [[ "$shaped_count" -ge 3 ]]  || { echo "  FAIL: <3 objects in data/shaped/ (expect train + val + test)" >&2; ok=0; }
  echo "  raw=$raw_count curated=$curated_count shaped=$shaped_count"

  echo "[smoke:through-shape] Step 9: tokenizer-stats + curation-stats"
  local tmp
  tmp=$(mktemp -d)
  s3_get "$fid" "metadata/tokenizer-stats.json" "$tmp/tokstats.json" >/dev/null 2>&1 || { echo "  FAIL: tokenizer-stats.json missing" >&2; ok=0; }
  s3_get "$fid" "metadata/curation-stats.json" "$tmp/curstats.json" >/dev/null 2>&1 || { echo "  FAIL: curation-stats.json missing" >&2; ok=0; }
  if [[ -f "$tmp/tokstats.json" ]]; then
    jq '{total_doc_count, split, approx_total_tokens: .token_stats.approx_total_tokens}' "$tmp/tokstats.json"
  fi
  rm -rf "$tmp"

  rm -f "$auto_spec_file"

  if (( ok == 1 )); then
    echo ""
    echo "[smoke:through-shape] PASS — data path verified end-to-end"
  else
    echo ""
    echo "[smoke:through-shape] FAIL" >&2
    exit 1
  fi
}

run_through_bootstrap_teardown() {
  local fixture_dir="${FIXTURE}"
  if [[ ! -f "${fixture_dir}/docs.jsonl" ]]; then
    echo "[smoke:m3] fixture missing at ${fixture_dir}/docs.jsonl" >&2
    exit 1
  fi

  echo "[smoke:m3] Step 1: bucket + identity sanity"
  s3_check_bucket
  local who
  who=$(_s3_aws sts get-caller-identity --query 'Arn' --output text)
  echo "  identity: $who"

  echo "[smoke:m3] Step 2: manifest init"
  local fid
  fid=$(manifest_init "smoke-m3" '{}')
  CLEANUP_FORGE_IDS+=("$fid")
  echo "  forge_id: $fid"

  # Always tear down on exit, even on failure
  # cleanup_m3 needs to see $fid from the EXIT trap (when the function
  # frame has unwound), so promote it to a script-level variable.
  M3_INSTANCE_ID=""
  M3_FORGE_ID="$fid"
  cleanup_m3() {
    # If forge-provision returned an instance_id, terminate by id.
    if [[ -n "${M3_INSTANCE_ID:-}" ]]; then
      echo "[smoke:m3:cleanup] best-effort terminate of $M3_INSTANCE_ID..." >&2
      _s3_aws ec2 terminate-instances --instance-ids "$M3_INSTANCE_ID" 2>/dev/null || true
      return
    fi
    # Else: scan for any running slm-forge-tagged instance for this forge.
    local orphans
    orphans=$(_s3_aws ec2 describe-instances \
      --filters "Name=tag:Project,Values=slm-forge" "Name=tag:forge-id,Values=${M3_FORGE_ID:-none}" \
                "Name=instance-state-name,Values=pending,running,stopping" \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")
    if [[ -n "$orphans" && "$orphans" != "None" ]]; then
      echo "[smoke:m3:cleanup] orphan instance(s) detected: $orphans — terminating" >&2
      _s3_aws ec2 terminate-instances --instance-ids $orphans 2>/dev/null || true
    fi
  }
  trap '_smoke_rc=$?; cleanup_m3; cleanup $_smoke_rc' EXIT

  echo "[smoke:m3] Step 3: write auto-spec fixture (tiny corpus, \$10 budget)"
  local auto_spec_file="${WORK_TMP:-/tmp}/.smoke-m3-spec-$$.json"
  jq -n \
    --arg ref "local:${fixture_dir}/docs.jsonl" \
    '{
      goal: "M3 smoke: provision + bootstrap + teardown on g5.xlarge",
      domain: "dental.patient-education",
      corpus_ref: $ref,
      target_use: "local-laptop",
      target_latency_ms: 500,
      target_quality: "smoke-test-only",
      license_preference: "apache-2.0",
      language: "en",
      constraints: {
        max_params: 200000000,
        budget_cap_usd: 10,
        max_wall_clock_hours: 1
      }
    }' > "$auto_spec_file"

  echo "[smoke:m3] Step 4: dispatch INTAKE → SHAPE (no spend)"
  bash "${ROOT}/scripts/dispatch.sh" "$fid" \
    --until SHAPE \
    --auto-approve-gates \
    --auto-spec "$auto_spec_file" >/dev/null

  echo "[smoke:m3] Step 5: forge-provision (REAL EC2 LAUNCH on g5.xlarge ~\$1.21/hr)"
  echo "          this is the first real-spend step — expect ~30-90s wait for SSM..."
  local prov_result
  prov_result=$(bash "${ROOT}/skills/forge-provision/run.sh" "$fid")
  echo "$prov_result" | jq .
  M3_INSTANCE_ID=$(echo "$prov_result" | jq -r .instance_id)
  if [[ -z "$M3_INSTANCE_ID" || "$M3_INSTANCE_ID" == "null" ]]; then
    echo "[smoke:m3] FAIL: forge-provision did not return an instance_id" >&2
    exit 1
  fi
  echo "  launched: $M3_INSTANCE_ID"

  if [[ "$SKIP_BOOTSTRAP" == "yes" ]]; then
    echo "[smoke:m3] Step 6: forge-bootstrap SKIPPED (--skip-bootstrap)"
    echo "  (lifecycle smoke validates provision+teardown; bootstrap re-tested on real GPU when quota available)"
  else
    echo "[smoke:m3] Step 6: forge-bootstrap (FORGE_BOOTSTRAP_FAST=${FORGE_BOOTSTRAP_FAST:-0} MINIMAL=${FORGE_BOOTSTRAP_MINIMAL:-0}; expect 1-15 min)"
    if FORGE_BOOTSTRAP_TIMEOUT="${FORGE_BOOTSTRAP_TIMEOUT:-1800}" \
       FORGE_BOOTSTRAP_FAST="${FORGE_BOOTSTRAP_FAST:-0}" \
       FORGE_BOOTSTRAP_MINIMAL="${FORGE_BOOTSTRAP_MINIMAL:-0}" \
       bash "${ROOT}/skills/forge-bootstrap/run.sh" "$fid"; then
      echo "  bootstrap: completed ✓"
    else
      echo "[smoke:m3] FAIL: forge-bootstrap did not complete" >&2
      exit 1
    fi
  fi

  echo "[smoke:m3] Step 7: forge-teardown --terminate"
  bash "${ROOT}/skills/forge-teardown/run.sh" "$fid" --terminate
  M3_INSTANCE_ID=""  # don't double-terminate via cleanup_m3

  echo "[smoke:m3] Step 8: verify final manifest state"
  local final phase compute_target cost
  final=$(manifest_load "$fid" 2>/dev/null)
  phase=$(echo "$final" | jq -r .phase)
  compute_target=$(echo "$final" | jq -r '.compute_target // "null"')
  cost=$(echo "$final" | jq -r '.cost_tracking.cost_to_date_usd // 0')

  local ok=1
  [[ "$phase" == "DONE" ]] || { echo "  FAIL: phase=$phase, expected DONE" >&2; ok=0; }
  [[ "$compute_target" == "null" ]] || { echo "  FAIL: compute_target should be cleared" >&2; ok=0; }
  echo "  phase:           $phase"
  echo "  compute_target:  $(echo "$compute_target" | head -c 60)..."
  echo "  cost_to_date_usd: \$${cost}"

  echo "[smoke:m3] Step 9: bootstrap log uploaded to S3"
  local tmp; tmp=$(mktemp -d)
  if s3_get "$fid" "logs/bootstrap.log" "$tmp/bootstrap.log" 2>/dev/null; then
    local lines; lines=$(wc -l < "$tmp/bootstrap.log")
    echo "  bootstrap.log: $lines lines"
    tail -3 "$tmp/bootstrap.log" | sed 's/^/    /'
  else
    echo "  WARN: bootstrap.log not found in S3 (may be expected if FORGE_BOOTSTRAP_FAST=1 finished too fast)"
  fi
  rm -rf "$tmp"

  rm -f "$auto_spec_file"

  if (( ok == 1 )); then
    echo ""
    echo "[smoke:m3] PASS — provision + bootstrap + teardown lifecycle verified"
  else
    echo ""
    echo "[smoke:m3] FAIL" >&2
    exit 1
  fi
}

run_full_train() {
  local fixture_dir="${FIXTURE}"
  if [[ ! -f "${fixture_dir}/docs.jsonl" ]]; then
    echo "[smoke:m4] fixture missing at ${fixture_dir}/docs.jsonl" >&2
    exit 1
  fi

  echo "[smoke:m4] Step 1: bucket + identity sanity"
  s3_check_bucket
  local who; who=$(_s3_aws sts get-caller-identity --query 'Arn' --output text)
  echo "  identity: $who"

  echo "[smoke:m4] Step 2: manifest init"
  local fid; fid=$(manifest_init "smoke-m4" '{}')
  CLEANUP_FORGE_IDS+=("$fid")
  echo "  forge_id: $fid"

  M3_INSTANCE_ID=""
  M3_FORGE_ID="$fid"
  cleanup_m3() {
    if [[ -n "${M3_INSTANCE_ID:-}" ]]; then
      echo "[smoke:m4:cleanup] terminate $M3_INSTANCE_ID..." >&2
      _s3_aws ec2 terminate-instances --instance-ids "$M3_INSTANCE_ID" 2>/dev/null || true
      return
    fi
    local orphans
    orphans=$(_s3_aws ec2 describe-instances \
      --filters "Name=tag:Project,Values=slm-forge" "Name=tag:forge-id,Values=${M3_FORGE_ID:-none}" \
                "Name=instance-state-name,Values=pending,running,stopping" \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")
    if [[ -n "$orphans" && "$orphans" != "None" ]]; then
      echo "[smoke:m4:cleanup] orphan(s): $orphans — terminating" >&2
      _s3_aws ec2 terminate-instances --instance-ids $orphans 2>/dev/null || true
    fi
  }
  trap '_smoke_rc=$?; cleanup_m3; cleanup $_smoke_rc' EXIT

  echo "[smoke:m4] Step 3: write auto-spec (tiny corpus, \$5 budget, override base→SmolLM2-135M, regime→lora-sft)"
  local auto_spec_file="${WORK_TMP:-/tmp}/.smoke-m4-spec-$$.json"
  jq -n \
    --arg ref "local:${fixture_dir}/docs.jsonl" \
    '{
      goal: "M4 smoke: full pipeline lora-sft on tiny corpus + tiny model",
      domain: "dental.patient-education",
      corpus_ref: $ref,
      target_use: "local-laptop",
      target_latency_ms: 500,
      target_quality: "smoke-test-only",
      license_preference: "apache-2.0",
      language: "en",
      constraints: {
        max_params: 200000000,
        budget_cap_usd: 5,
        max_wall_clock_hours: 1
      }
    }' > "$auto_spec_file"

  echo "[smoke:m4] Step 4: dispatch INTAKE → SHAPE (no spend) with architect overrides"
  FORGE_ARCHITECT_BASE_OVERRIDE="${FORGE_ARCHITECT_BASE_OVERRIDE:-HuggingFaceTB/SmolLM2-135M}" \
  FORGE_ARCHITECT_REGIME_OVERRIDE="${FORGE_ARCHITECT_REGIME_OVERRIDE:-lora-sft}" \
    bash "${ROOT}/scripts/dispatch.sh" "$fid" \
      --until SHAPE \
      --auto-approve-gates \
      --auto-spec "$auto_spec_file" >/dev/null

  echo "[smoke:m4] Step 5: forge-provision (REAL EC2 LAUNCH)"
  local prov_result; prov_result=$(bash "${ROOT}/skills/forge-provision/run.sh" "$fid")
  echo "$prov_result" | jq .
  M3_INSTANCE_ID=$(echo "$prov_result" | jq -r .instance_id)
  [[ -z "$M3_INSTANCE_ID" || "$M3_INSTANCE_ID" == "null" ]] && { echo "[smoke:m4] FAIL: no instance_id"; exit 1; }
  echo "  launched: $M3_INSTANCE_ID"

  echo "[smoke:m4] Step 6: forge-bootstrap (FAST mode; expect 5-12 min)"
  if FORGE_BOOTSTRAP_TIMEOUT="${FORGE_BOOTSTRAP_TIMEOUT:-1800}" \
     FORGE_BOOTSTRAP_FAST=1 \
     bash "${ROOT}/skills/forge-bootstrap/run.sh" "$fid"; then
    echo "  bootstrap: completed ✓"
  else
    echo "[smoke:m4] FAIL: bootstrap" >&2; exit 1
  fi

  echo "[smoke:m4] Step 7: forge-train (smoke params: short steps, small batch)"
  if FORGE_TRAIN_MAX_STEPS="${FORGE_TRAIN_MAX_STEPS:-20}" \
     FORGE_TRAIN_BATCH_SIZE="${FORGE_TRAIN_BATCH_SIZE:-2}" \
     FORGE_TRAIN_MAX_SEQ_LEN="${FORGE_TRAIN_MAX_SEQ_LEN:-256}" \
     FORGE_TRAIN_LOGGING_STEPS="${FORGE_TRAIN_LOGGING_STEPS:-2}" \
     FORGE_TRAIN_SAVE_STEPS="${FORGE_TRAIN_SAVE_STEPS:-10}" \
     FORGE_TRAIN_LORA_R=4 FORGE_TRAIN_LORA_ALPHA=8 \
     bash "${ROOT}/skills/forge-train/run.sh" "$fid"; then
    echo "  train: launched + 30s health probe PASS ✓"
  else
    echo "[smoke:m4] FAIL: forge-train" >&2; exit 1
  fi

  echo "[smoke:m4] Step 8: forge-monitor loop (wait for completion; max 25 polls × 30s = 12.5 min)"
  local poll
  for poll in $(seq 1 25); do
    sleep 30
    local mon_result; mon_result=$(bash "${ROOT}/skills/forge-monitor/run.sh" "$fid")
    local status; status=$(echo "$mon_result" | jq -r .status)
    local next_phase; next_phase=$(echo "$mon_result" | jq -r .next_phase)
    local loss; loss=$(echo "$mon_result" | jq -r '.heartbeat.loss // "?"')
    local step; step=$(echo "$mon_result" | jq -r '.heartbeat.step // "?"')
    echo "  [poll $poll/25]  status=$status  next=$next_phase  loss=$loss  step=$step"

    if [[ "$status" == "completed" && "$next_phase" == "EVAL" ]]; then
      echo "  ✓ training completed; final weights synced to S3"
      break
    fi
    if [[ "$status" == "failed" ]]; then
      echo "[smoke:m4] FAIL: monitor reported training failure" >&2
      echo "$mon_result" | jq .
      exit 1
    fi
  done

  echo "[smoke:m4] Step 9: forge-teardown --terminate"
  bash "${ROOT}/skills/forge-teardown/run.sh" "$fid" --terminate
  M3_INSTANCE_ID=""

  echo "[smoke:m4] Step 10: verify final manifest state"
  local final; final=$(manifest_load "$fid" 2>/dev/null)
  local phase; phase=$(echo "$final" | jq -r .phase)
  local final_uri; final_uri=$(echo "$final" | jq -r '.artifacts.final_weights_s3 // "null"')
  local cost; cost=$(echo "$final" | jq -r '.cost_tracking.cost_to_date_usd // 0')

  local ok=1
  [[ "$phase" == "DONE" ]] || { echo "  FAIL: phase=$phase, expected DONE" >&2; ok=0; }
  [[ "$final_uri" != "null" ]] || { echo "  FAIL: final_weights_s3 not set" >&2; ok=0; }

  echo "  phase:            $phase"
  echo "  final_weights_s3: $final_uri"
  echo "  cost_to_date_usd: \$${cost}"

  echo "[smoke:m4] Step 11: confirm safetensors exists in final/"
  local count; count=$(_s3_aws s3 ls "$final_uri" --recursive 2>/dev/null | grep -c safetensors || echo 0)
  [[ "$count" -gt 0 ]] || { echo "  FAIL: no safetensors in final_weights_s3" >&2; ok=0; }
  echo "  safetensors count: $count"

  rm -f "$auto_spec_file"

  if (( ok == 1 )); then
    echo ""
    echo "[smoke:m4] PASS — full training pipeline verified end-to-end"
  else
    echo ""
    echo "[smoke:m4] FAIL" >&2
    exit 1
  fi
}

run_full() {
  local fixture_dir="${FIXTURE}"
  if [[ ! -f "${fixture_dir}/docs.jsonl" ]]; then
    echo "[smoke:m5] fixture missing at ${fixture_dir}/docs.jsonl" >&2
    exit 1
  fi

  echo "[smoke:m5] Step 1: bucket + identity + HF token sanity"
  s3_check_bucket
  local who; who=$(_s3_aws sts get-caller-identity --query 'Arn' --output text)
  echo "  AWS identity: $who"
  # HF token check
  if [[ -z "${HF_TOKEN:-}" ]]; then
    local env_file="${ROOT}/../.env"
    HF_TOKEN=$(grep '^HF_TOKEN=' "$env_file" 2>/dev/null | cut -d= -f2 || true)
    export HF_TOKEN
  fi
  [[ -z "$HF_TOKEN" ]] && { echo "[smoke:m5] HF_TOKEN missing — can't run forge-register"; exit 1; }
  local hf_ns; hf_ns=$(curl -sS -H "Authorization: Bearer $HF_TOKEN" https://huggingface.co/api/whoami-v2 | jq -r '.name // ""')
  [[ -z "$hf_ns" ]] && { echo "[smoke:m5] HF_TOKEN invalid"; exit 1; }
  echo "  HF namespace: $hf_ns"

  echo "[smoke:m5] Step 2: manifest init"
  local fid; fid=$(manifest_init "smoke-m5" '{}')
  CLEANUP_FORGE_IDS+=("$fid")
  echo "  forge_id: $fid"

  M3_INSTANCE_ID=""
  M3_FORGE_ID="$fid"
  M5_MODEL_REPO=""
  M5_SPACE_REPO=""
  cleanup_m3() {
    if [[ -n "${M3_INSTANCE_ID:-}" ]]; then
      echo "[smoke:m5:cleanup] terminate $M3_INSTANCE_ID..." >&2
      _s3_aws ec2 terminate-instances --instance-ids "$M3_INSTANCE_ID" 2>/dev/null || true
    fi
    local orphans
    orphans=$(_s3_aws ec2 describe-instances \
      --filters "Name=tag:Project,Values=slm-forge" "Name=tag:forge-id,Values=${M3_FORGE_ID:-none}" \
                "Name=instance-state-name,Values=pending,running,stopping" \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")
    if [[ -n "$orphans" && "$orphans" != "None" ]]; then
      _s3_aws ec2 terminate-instances --instance-ids $orphans 2>/dev/null || true
    fi
    # HF cleanup: delete the throwaway model + space repos
    if [[ -n "${M5_MODEL_REPO:-}" ]]; then
      echo "[smoke:m5:cleanup] delete HF model $M5_MODEL_REPO..." >&2
      source "${LIB}/hf.sh" 2>/dev/null || true
      hf_delete_repo "$M5_MODEL_REPO" model 2>/dev/null || true
    fi
    if [[ -n "${M5_SPACE_REPO:-}" ]]; then
      echo "[smoke:m5:cleanup] delete HF space $M5_SPACE_REPO..." >&2
      hf_delete_repo "$M5_SPACE_REPO" space 2>/dev/null || true
    fi
  }
  trap '_smoke_rc=$?; cleanup_m3; cleanup $_smoke_rc' EXIT

  echo "[smoke:m5] Step 3: write auto-spec"
  local auto_spec_file="${WORK_TMP:-/tmp}/.smoke-m5-spec-$$.json"
  jq -n \
    --arg ref "local:${fixture_dir}/docs.jsonl" \
    '{
      goal: "M5 smoke: full pipeline SLM → eval → quantize → register",
      domain: "dental.patient-education",
      corpus_ref: $ref,
      target_use: "local-laptop",
      target_latency_ms: 500,
      target_quality: "smoke-test-only",
      license_preference: "apache-2.0",
      language: "en",
      constraints: {
        max_params: 200000000,
        budget_cap_usd: 10,
        max_wall_clock_hours: 2
      }
    }' > "$auto_spec_file"

  echo "[smoke:m5] Step 4: dispatch INTAKE → SHAPE"
  FORGE_ARCHITECT_BASE_OVERRIDE="${FORGE_ARCHITECT_BASE_OVERRIDE:-HuggingFaceTB/SmolLM2-135M}" \
  FORGE_ARCHITECT_REGIME_OVERRIDE="${FORGE_ARCHITECT_REGIME_OVERRIDE:-lora-sft}" \
    bash "${ROOT}/scripts/dispatch.sh" "$fid" \
      --until SHAPE --auto-approve-gates --auto-spec "$auto_spec_file" >/dev/null

  echo "[smoke:m5] Step 5: forge-provision"
  local prov; prov=$(bash "${ROOT}/skills/forge-provision/run.sh" "$fid")
  M3_INSTANCE_ID=$(echo "$prov" | jq -r .instance_id)
  echo "  launched: $M3_INSTANCE_ID"

  echo "[smoke:m5] Step 6: forge-bootstrap (FAST)"
  FORGE_BOOTSTRAP_TIMEOUT="${FORGE_BOOTSTRAP_TIMEOUT:-1800}" \
  FORGE_BOOTSTRAP_FAST=1 \
    bash "${ROOT}/skills/forge-bootstrap/run.sh" "$fid" >/dev/null || { echo "FAIL bootstrap"; exit 1; }
  echo "  bootstrap ✓"

  echo "[smoke:m5] Step 7: forge-train"
  FORGE_TRAIN_MAX_STEPS="${FORGE_TRAIN_MAX_STEPS:-20}" \
  FORGE_TRAIN_BATCH_SIZE="${FORGE_TRAIN_BATCH_SIZE:-2}" \
  FORGE_TRAIN_MAX_SEQ_LEN="${FORGE_TRAIN_MAX_SEQ_LEN:-256}" \
  FORGE_TRAIN_LOGGING_STEPS="${FORGE_TRAIN_LOGGING_STEPS:-5}" \
  FORGE_TRAIN_SAVE_STEPS="${FORGE_TRAIN_SAVE_STEPS:-10}" \
  FORGE_TRAIN_LORA_R=4 FORGE_TRAIN_LORA_ALPHA=8 \
    bash "${ROOT}/skills/forge-train/run.sh" "$fid" >/dev/null || { echo "FAIL train"; exit 1; }
  echo "  train launched ✓"

  echo "[smoke:m5] Step 8: monitor loop (up to 25×30s = 12.5 min)"
  local poll
  for poll in $(seq 1 25); do
    sleep 30
    local mon; mon=$(bash "${ROOT}/skills/forge-monitor/run.sh" "$fid")
    local status; status=$(echo "$mon" | jq -r .status)
    local next_phase; next_phase=$(echo "$mon" | jq -r .next_phase)
    local step; step=$(echo "$mon" | jq -r '.heartbeat.step // "?"')
    echo "  [mon $poll]  status=$status  next=$next_phase  step=$step"
    [[ "$status" == "completed" && "$next_phase" == "EVAL" ]] && { echo "  ✓ training complete"; break; }
    [[ "$status" == "failed" ]] && { echo "FAIL monitor"; exit 1; }
  done

  echo "[smoke:m5] Step 9: forge-eval"
  FORGE_EVAL_TIMEOUT="${FORGE_EVAL_TIMEOUT:-1800}" \
    bash "${ROOT}/skills/forge-eval/run.sh" "$fid" | jq '.summary // .'
  [[ $? -eq 0 ]] || { echo "FAIL eval"; exit 1; }

  echo "[smoke:m5] Step 10: forge-quantize"
  FORGE_QUANTIZE_TIMEOUT="${FORGE_QUANTIZE_TIMEOUT:-1800}" \
    bash "${ROOT}/skills/forge-quantize/run.sh" "$fid" | jq '.quantized // .'
  [[ $? -eq 0 ]] || { echo "FAIL quantize"; exit 1; }

  echo "[smoke:m5] Step 11: forge-register (private HF repo + space; cleanup on exit)"
  local reg_result; reg_result=$(HF_TOKEN="$HF_TOKEN" FORGE_REGISTER_NAME_PREFIX="smoke-" \
    bash "${ROOT}/skills/forge-register/run.sh" "$fid")
  echo "$reg_result" | jq .
  local repo; repo=$(echo "$reg_result" | jq -r '.hf_repo // ""')
  local space; space=$(echo "$reg_result" | jq -r '.hf_space // ""')
  M5_MODEL_REPO=$(echo "$repo" | sed 's#https://huggingface.co/##' | sed 's#/$##')
  if [[ -n "$space" ]]; then
    M5_SPACE_REPO=$(echo "$space" | sed 's#https://huggingface.co/spaces/##' | sed 's#/$##')
  fi
  [[ -n "$M5_MODEL_REPO" ]] || { echo "FAIL register"; exit 1; }

  echo "[smoke:m5] Step 12: forge-teardown"
  bash "${ROOT}/skills/forge-teardown/run.sh" "$fid" --terminate
  M3_INSTANCE_ID=""

  echo "[smoke:m5] Step 13: verify final state"
  local final; final=$(manifest_load "$fid" 2>/dev/null)
  local phase; phase=$(echo "$final" | jq -r .phase)
  local hf_repo; hf_repo=$(echo "$final" | jq -r '.artifacts.hf_repo // "null"')
  local q4; q4=$(echo "$final" | jq -r '.artifacts.quantized_s3.Q4_K_M.uri // "null"')
  local eval_uri; eval_uri=$(echo "$final" | jq -r '.artifacts.eval_reports_s3 // "null"')
  local cost; cost=$(echo "$final" | jq -r '.cost_tracking.cost_to_date_usd // 0')

  local ok=1
  [[ "$phase" == "DONE" ]]         || { echo "FAIL phase=$phase"; ok=0; }
  [[ "$hf_repo" != "null" ]]       || { echo "FAIL hf_repo missing"; ok=0; }
  [[ "$q4" != "null" ]]            || { echo "FAIL Q4_K_M missing"; ok=0; }
  [[ "$eval_uri" != "null" ]]      || { echo "FAIL eval_reports missing"; ok=0; }
  echo "  phase:             $phase"
  echo "  hf_repo:           $hf_repo"
  echo "  gguf_Q4_K_M:       $q4"
  echo "  eval_reports_s3:   $eval_uri"
  echo "  cost_to_date_usd:  \$${cost}"

  rm -f "$auto_spec_file"

  if (( ok == 1 )); then
    echo ""
    echo "[smoke:m5] PASS — full forge pipeline verified end-to-end"
  else
    echo ""
    echo "[smoke:m5] FAIL" >&2
    exit 1
  fi
}

case "$MODE" in
  init-only)
    run_init_only
    ;;
  through)
    case "$THROUGH" in
      SHAPE|shape) run_through_shape "tiny-corpus" ;;
      BOOTSTRAP|bootstrap)
        if [[ "$THEN_TEARDOWN" != "yes" ]]; then
          echo "[smoke] --through BOOTSTRAP must include --then-teardown (would leave EC2 running)" >&2
          exit 64
        fi
        run_through_bootstrap_teardown ;;
      *)
        echo "[smoke] --through $THROUGH not yet implemented" >&2
        exit 78
        ;;
    esac
    ;;
  full-train)
    run_full_train ;;
  full)
    run_full ;;
esac
