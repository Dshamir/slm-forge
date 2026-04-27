#!/bin/bash
# dispatch-v2: plan-executor for slm-forge v2.
#
# Reads the phase sequence from plan.json, executes each phase in order.
# Each phase has: pre-check (idempotent skip), run, post-check (validate).
# On any failure: teardown any live instance, write failure-report.md, exit 1.
#
# Usage: bash dispatch-v2.sh <run-id>
#
# Expected state when invoked:
#   slm-forge/.runs/<run-id>/plan.json      exists (from forge-plan)
#   slm-forge/.runs/<run-id>/approved       exists (touched by approve-plan.sh)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."
SKILLS_DIR="${REPO_ROOT}/slm-forge/skills"
CREDS_FILE="${FORGE_CREDS_FILE:-/tmp/forge-creds.env}"

RUN_ID="${1:-}"
if [[ -z "$RUN_ID" ]]; then
  echo "usage: $0 <run-id>" >&2; exit 64
fi
RUN_DIR="${REPO_ROOT}/slm-forge/.runs/${RUN_ID}"
PLAN="$RUN_DIR/plan.json"
STATE="$RUN_DIR/state.json"
LOG="$RUN_DIR/dispatch.log"

if [[ ! -f "$PLAN" ]]; then
  echo "dispatch: no plan.json at $PLAN" >&2; exit 1
fi
if [[ ! -f "$RUN_DIR/approved" ]]; then
  echo "dispatch: plan not approved (missing $RUN_DIR/approved)" >&2; exit 1
fi

# Load creds
[[ -f "$CREDS_FILE" ]] && set -a && source "$CREDS_FILE" && set +a

# Helper: append timestamped line to dispatch log
logm() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG" >&2; }

# --- v1 manifest bridge ----------------------------------------------------
# The GPU-era skills (shape, provision, bootstrap, train, monitor, eval,
# quantize, register, teardown) are v1-oriented: they call manifest_load()
# against an S3-resident manifest keyed by forge-id. V2 runs only have a
# local plan.json. This bridge synthesizes the v1 manifest shape from
# plan.json + state.json and writes it to S3 once, before the first
# v1-bridged phase. Forge-id = "v2-<run-id>" so it's distinguishable from
# v1-originated forges in S3 and cost-explorer tags.
#
# Idempotent: if state.json.forge_id is already set, re-use it; the v1
# skills are themselves idempotent against the S3 manifest.

V1_BRIDGED_PHASES="shape provision bootstrap train monitor eval quantize register teardown"

is_v1_bridged_phase() {
  local phase="$1"
  for p in $V1_BRIDGED_PHASES; do
    [[ "$phase" == "$p" ]] && return 0
  done
  return 1
}

bridge_to_v1_manifest() {
  # Idempotent: if forge_id already set in state, bridge has fired
  local existing_fid
  existing_fid=$(jq -r '.forge_id // ""' "$STATE")
  if [[ -n "$existing_fid" && "$existing_fid" != "null" ]]; then
    logm "bridge: reusing forge_id=$existing_fid from state.json"
    echo "$existing_fid"
    return 0
  fi

  local forge_id="v2-${RUN_ID}"
  local created_at
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  logm "bridge: synthesizing v1 manifest for forge_id=$forge_id"

  # Source manifest lib so we can call its helpers. manifest.sh sets
  # `set -euo pipefail` on source; save and restore so we don't alter
  # dispatch-v2's (more permissive) error behavior globally.
  local saved_errexit
  case $- in *e*) saved_errexit=1 ;; *) saved_errexit=0 ;; esac
  # shellcheck source=../lib/manifest.sh
  source "${REPO_ROOT}/slm-forge/lib/manifest.sh"
  (( saved_errexit )) || set +e

  # Read all the fields the v1 skills will consume from plan.json
  local base_repo params_label regime framework chat_tmpl domain cap_usd
  local gpu_cost_usd instance_type clean_tokens shape_s3
  base_repo=$(jq -r '.base_model.hf_repo' "$PLAN")
  params_label=$(jq -r '.base_model.params_label' "$PLAN")
  regime=$(jq -r '.regime' "$PLAN")
  framework=$(jq -r '.framework' "$PLAN")
  chat_tmpl=$(jq -r '.chat_template' "$PLAN")
  domain=$(jq -r '.domain' "$PLAN")
  cap_usd=$(jq -r '.budget_cap_usd' "$PLAN")
  gpu_cost_usd=$(jq -r '.estimates.cost.gpu_usd' "$PLAN")
  instance_type=$(jq -r '.compute.instance_type' "$PLAN")
  clean_tokens=$(jq -r '.estimates.clean_tokens' "$PLAN")
  # Shaped corpus URI: v2 phases write it to state.json.artifacts
  # when shape completes; on first bridge firing this is empty and
  # the v1 shape skill itself will populate the manifest.
  shape_s3=$(jq -r '.artifacts.shape_out_s3 // ""' "$STATE")

  # A usable spec.goal for the register card. Corpus basename is a
  # reasonable human-readable seed; operator can override post-register.
  local target_basename
  target_basename=$(jq -r '.target_dir | split("/") | .[-1]' "$PLAN")

  local manifest
  manifest=$(jq -n \
    --arg sv "$FORGE_SCHEMA_VERSION" \
    --arg fid "$forge_id" \
    --arg ts "$created_at" \
    --arg by "${USER:-dispatch-v2}@$(hostname -s)" \
    --arg bucket "$FORGE_BUCKET" \
    --arg prefix "$FORGE_PREFIX" \
    --arg base "$base_repo" \
    --arg plabel "$params_label" \
    --arg regime "$regime" \
    --arg framework "$framework" \
    --arg chat "$chat_tmpl" \
    --arg domain "$domain" \
    --argjson cap "$cap_usd" \
    --argjson gpu_cost "$gpu_cost_usd" \
    --arg inst "$instance_type" \
    --argjson tokens "$clean_tokens" \
    --arg shape "$shape_s3" \
    --arg corpus "$target_basename" \
    '{
      schema_version: $sv,
      forge_id: $fid,
      name: $fid,
      created_at: $ts,
      updated_at: $ts,
      created_by: $by,
      spec: {
        goal: ("SLM trained on " + $corpus + " corpus"),
        domain: $domain,
        language: "en",
        target_use: "domain-qa",
        license_preference: "apache-2.0",
        constraints: { budget_cap_usd: $cap }
      },
      plan: {
        base_model: $base,
        training_regime: $regime,
        training_framework: $framework,
        chat_template: $chat,
        tokenizer_strategy: "reuse-base",
        target_params: $plabel,
        trust_remote_code: false
      },
      estimate: {
        estimated_compute_cost_usd: $gpu_cost,
        instance_type: $inst
      },
      token_stats: { approx_total_tokens: $tokens },
      phase: "SHAPE",
      phase_history: [
        { phase: "BRIDGED_FROM_V2", entered_at: $ts, exited_at: $ts, status: "completed" }
      ],
      compute_target: null,
      artifacts: {
        raw_corpus_s3: null,
        curated_corpus_s3: null,
        shaped_corpus_s3: (if $shape == "" then null else $shape end),
        checkpoints_s3: null,
        final_weights_s3: null,
        quantized_s3: { Q4_K_M: null, Q8_0: null, AWQ: null },
        eval_reports_s3: null,
        model_card_s3: null,
        hf_repo: null,
        hf_space: null
      },
      training_runtime: null,
      cost_tracking: {
        budget_cap_usd: $cap,
        cost_to_date_usd: 0,
        cost_by_phase_usd: {},
        last_reconciled_at: null,
        reconciliation_source: null
      },
      gates: {
        budget_gate:  { required_at: "post-ESTIMATE", status: "passed",  passed_at: $ts, passed_by_user: true },
        quality_gate: { required_at: "post-EVAL",    status: "pending", passed_at: null, passed_by_user: false }
      },
      logs_s3_prefix: ("s3://" + $bucket + "/" + $prefix + "/" + $fid + "/logs/"),
      errors: [],
      notes: [("bridged from v2 run " + $fid)]
    }')

  # Validate + persist locally, then write to S3
  manifest_validate "$manifest" || {
    logm "bridge: manifest_validate FAILED"
    return 1
  }

  mkdir -p "$(dirname "$(_local_manifest_path "$forge_id")")"
  echo "$manifest" | jq . > "$(_local_manifest_path "$forge_id")"

  local local_path mount_dir base_name
  local_path=$(_local_manifest_path "$forge_id")
  mount_dir=$(dirname "$local_path")
  base_name=$(basename "$local_path")

  _forge_aws_mount "$mount_dir" s3api put-object \
    --bucket "$FORGE_BUCKET" \
    --key "$(_forge_id_to_key "$forge_id")" \
    --content-type "application/json" \
    --tagging "Project=slm-forge&forge-id=$forge_id&phase=BRIDGED" \
    --body "/work/$base_name" >/dev/null

  # Persist forge_id into state.json so subsequent phases / resumes find it
  jq --arg fid "$forge_id" '.forge_id = $fid' "$STATE" > "$STATE.new"
  mv "$STATE.new" "$STATE"

  logm "bridge: manifest written to s3://$FORGE_BUCKET/$(_forge_id_to_key "$forge_id")"
  echo "$forge_id"
}

# Initialize state.json if not present
if [[ ! -f "$STATE" ]]; then
  jq -n --arg rid "$RUN_ID" --arg st "$(date -u +%FT%TZ)" '{
    run_id: $rid,
    started_at: $st,
    current_phase: null,
    completed_phases: [],
    failed_phases: [],
    instance_id: null,
    artifacts: {},
    total_cost_usd: 0
  }' > "$STATE"
fi

# Read phase sequence
PHASES=$(jq -r '.phase_sequence[]' "$PLAN")

# --- Phase dispatch helpers ------------------------------------------------
run_phase() {
  local phase="$1"
  # Phase names use underscores (valid bash identifiers); skill dirs use hyphens.
  local phase_dir="${phase//_/-}"
  local skill_dir="${SKILLS_DIR}/forge-${phase_dir}"

  # Each phase can be implemented as a skill dir (forge-<phase>/run.sh) OR
  # a known v1 skill we're still bridging to (with different name).
  local run_sh=""
  case "$phase" in
    # v2 native skills
    ingest|prep|audit|synth|plan_fit|card_validator|smoketest|publish|report)
      run_sh="${SKILLS_DIR}/forge-${phase_dir}/run.sh"
      ;;
    # v1 skills we're bridging (map phase → legacy skill name)
    shape)         run_sh="${SKILLS_DIR}/forge-shape/run.sh" ;;
    provision)     run_sh="${SKILLS_DIR}/forge-provision/run.sh" ;;
    bootstrap)     run_sh="${SKILLS_DIR}/forge-bootstrap/run.sh" ;;
    train)         run_sh="${SKILLS_DIR}/forge-train/run.sh" ;;
    monitor)       run_sh="${SKILLS_DIR}/forge-monitor/run.sh" ;;
    eval)          run_sh="${SKILLS_DIR}/forge-eval/run.sh" ;;
    quantize)      run_sh="${SKILLS_DIR}/forge-quantize/run.sh" ;;
    register)      run_sh="${SKILLS_DIR}/forge-register/run.sh" ;;
    teardown)      run_sh="${SKILLS_DIR}/forge-teardown/run.sh" ;;
    *)
      logm "phase $phase has no skill implementation"
      return 1
      ;;
  esac

  if [[ ! -x "$run_sh" ]]; then
    logm "phase $phase: $run_sh not executable (skill not yet wired)"
    return 127
  fi

  # Bridge to v1 manifest before the first v1-bridged phase. Idempotent —
  # safe to call multiple times; only the first creates the S3 manifest.
  # V1 skills receive the forge-id (v2-<run-id>), v2-native skills get run-id.
  local skill_arg="$RUN_ID"
  if is_v1_bridged_phase "$phase"; then
    local forge_id
    forge_id=$(bridge_to_v1_manifest) || {
      logm "phase=$phase: bridge_to_v1_manifest FAILED"
      return 1
    }
    skill_arg="$forge_id"
  fi

  logm "phase=$phase start (arg=$skill_arg)"
  local t0=$(date +%s)

  # Monitor is special: it's a single-shot poll that can return
  # {"status":"in-progress"} while training runs on EC2. Re-invoke on an
  # interval until it returns {"status":"completed"} OR {"status":"failed"}.
  # Without this loop, dispatch advances to eval before training finishes
  # and eval trips on missing weights.
  if [[ "$phase" == "monitor" ]]; then
    local poll_interval="${FORGE_MONITOR_POLL_SECONDS:-120}"
    local attempt=0
    while true; do
      attempt=$((attempt + 1))
      local mon_out
      mon_out=$(bash "$run_sh" "$skill_arg" 2>&1 | tee -a "$LOG")
      local mon_rc=$?
      # Extract the last JSON object from stdout (monitor emits progress
      # text before the final JSON heartbeat). jq handles multi-object
      # streams; `last` gives the final one.
      local mon_status
      mon_status=$(echo "$mon_out" | grep -oE '"status"[[:space:]]*:[[:space:]]*"[^"]+"' | tail -1 | sed -E 's/.*"status"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
      if (( mon_rc != 0 )); then
        logm "phase=monitor FAILED (rc=$mon_rc, attempt=$attempt)"
        return $mon_rc
      fi
      case "$mon_status" in
        completed)
          logm "phase=monitor: training completed (attempt=$attempt)"
          break
          ;;
        failed)
          logm "phase=monitor: training FAILED reported by monitor (attempt=$attempt)"
          return 1
          ;;
        in-progress|"")
          logm "phase=monitor: in-progress (attempt=$attempt); sleeping ${poll_interval}s"
          sleep "$poll_interval"
          ;;
        *)
          logm "phase=monitor: unknown status=$mon_status — treating as in-progress"
          sleep "$poll_interval"
          ;;
      esac
    done
    local dt=$(( $(date +%s) - t0 ))
    logm "phase=monitor complete (${dt}s, ${attempt} polls)"
    return 0
  fi

  bash "$run_sh" "$skill_arg" 2>&1 | tee -a "$LOG" || {
    local rc=$?
    logm "phase=$phase FAILED (rc=$rc)"
    return $rc
  }
  local dt=$(( $(date +%s) - t0 ))
  logm "phase=$phase complete (${dt}s)"
  return 0
}

on_failure() {
  local phase="$1" rc="$2"
  logm "on_failure: phase=$phase rc=$rc — tearing down"

  jq --arg ph "$phase" --argjson rc "$rc" \
    '.failed_phases += [{phase:$ph, rc:$rc, at:(now|todate)}]' "$STATE" > "$STATE.new"
  mv "$STATE.new" "$STATE"

  # If we provisioned an EC2, terminate it
  local iid=$(jq -r '.instance_id // ""' "$STATE")
  if [[ -n "$iid" && "$iid" != "null" ]]; then
    logm "terminating instance $iid"
    if [[ -x "${SKILLS_DIR}/forge-teardown/run.sh" ]]; then
      bash "${SKILLS_DIR}/forge-teardown/run.sh" "$RUN_ID" --terminate 2>&1 | tee -a "$LOG" || true
    fi
  fi

  # Write failure-report.md
  cat > "$RUN_DIR/failure-report.md" <<EOF
# 🛑 FORGE FAILED — ${RUN_ID}

**Failed phase:** \`${phase}\`
**Exit code:** ${rc}
**Time:** $(date -u +%FT%TZ)

## Completed phases
$(jq -r '.completed_phases[] | "- `\(.)`"' "$STATE" 2>/dev/null || echo "(none)")

## What to do
- Review the tail of \`${LOG}\` for error detail
- If the failure was transient (AWS capacity, network), re-run:
    \`bash slm-forge/scripts/dispatch-v2.sh ${RUN_ID}\`
  Dispatcher is idempotent — completed phases skip automatically.
- If structural (plan error, corpus problem), fix input + regenerate plan.

## State snapshot
\`\`\`json
$(cat "$STATE")
\`\`\`
EOF
  logm "failure-report.md written"
  exit 1
}

# --- Execute phases --------------------------------------------------------
SKIP_PHASES=$(jq -r '.skip_phases | join(" ")' "$PLAN")
for phase in $PHASES; do
  # Check if already completed
  if jq -e --arg p "$phase" '.completed_phases | index($p)' "$STATE" >/dev/null 2>&1; then
    logm "phase=$phase already completed — skip"
    continue
  fi

  # Check if in skip list (shouldn't happen since plan doesn't include them, but defensive)
  if [[ " $SKIP_PHASES " == *" $phase "* ]]; then
    logm "phase=$phase in skip list — skip"
    continue
  fi

  # Update current phase
  jq --arg p "$phase" '.current_phase = $p' "$STATE" > "$STATE.new" && mv "$STATE.new" "$STATE"

  if run_phase "$phase"; then
    jq --arg p "$phase" '.completed_phases += [$p] | .current_phase = null' "$STATE" > "$STATE.new"
    mv "$STATE.new" "$STATE"

    # Honor STOP_AFTER_PHASE — exit cleanly with state.json consistent.
    # Resume by re-running dispatch without the env var; completed_phases
    # skip logic above picks up at the next phase.
    if [[ -n "${STOP_AFTER_PHASE:-}" && "$phase" == "$STOP_AFTER_PHASE" ]]; then
      logm "STOP_AFTER_PHASE=$STOP_AFTER_PHASE matched — exiting cleanly. Resume by re-running without STOP_AFTER_PHASE."
      exit 0
    fi
  else
    on_failure "$phase" $?
  fi
done

# All phases done
jq --arg st "$(date -u +%FT%TZ)" '.current_phase = "DONE" | .finished_at = $st' "$STATE" > "$STATE.new"
mv "$STATE.new" "$STATE"
logm "✓ ALL PHASES COMPLETE — run ${RUN_ID}"
echo "DONE"
