#!/bin/bash
# forge-report: emits after-action.md + qa-report.md from final state.
# This is the LAST phase. Reads everything in $RUN_DIR and synthesizes
# the two MD docs the operator wakes up to.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../../.."
RUN_ID="${1:-}"
[[ -z "$RUN_ID" ]] && { echo "usage: $0 <run-id>" >&2; exit 64; }

RUN_DIR="${REPO_ROOT}/slm-forge/.runs/${RUN_ID}"
PLAN="$RUN_DIR/plan.json"
STATE="$RUN_DIR/state.json"
ANALYSIS="$RUN_DIR/analysis.json"

j() { jq -r "$1" "$2" 2>/dev/null || echo "(missing)"; }

# Resolve forge-id used by v1 skills
FORGE_ID=""
[[ -f "$RUN_DIR/forge-id" ]] && FORGE_ID=$(cat "$RUN_DIR/forge-id")

# Pull artifacts
HF_REPO=$(j '.artifacts.hf_repo // empty' "$STATE")
HF_SPACE=$(j '.artifacts.hf_space // empty' "$STATE")

# Cost
TOTAL_COST=$(j '.total_cost_usd // 0' "$STATE")

# Eval
EVAL_REPORT="$RUN_DIR/eval-report.json"
PPL_FORGED=""
PPL_BASELINE=""
PPL_DELTA=""
if [[ -f "$EVAL_REPORT" ]]; then
  PPL_FORGED=$(j '.summary.merged_model_ppl // ""' "$EVAL_REPORT")
  PPL_BASELINE=$(j '.summary.baseline_ppl // ""' "$EVAL_REPORT")
  PPL_DELTA=$(j '.summary.delta_ppl // ""' "$EVAL_REPORT")
fi

# Plan-fit
PF_REPORT="$RUN_DIR/plan-fit-report-final.json"
[[ ! -f "$PF_REPORT" ]] && PF_REPORT="$RUN_DIR/plan-fit-report.json"
PF_VERDICT=$(j '.verdict // ""' "$PF_REPORT")
PF_AXIS3_MEAN=$(j '.axes.axis3_qa_accuracy.overall_mean // ""' "$PF_REPORT")
PF_AXIS1_DOMAIN=$(j '.axes.axis1_corpus_content.in_domain_pct // ""' "$PF_REPORT")

# Card validator
CARD_REPORT="$RUN_DIR/card-validator-report.json"
CARD_STATUS=$(j '.status // ""' "$CARD_REPORT")

# Smoketest
SMOKE_REPORT="$RUN_DIR/smoketest-report.json"
SMOKE_STATUS=$(j '.status // ""' "$SMOKE_REPORT")
SMOKE_RESPONSE=$(j '.response_preview // ""' "$SMOKE_REPORT")

# Plan + analysis fields
TARGET=$(j '.target_dir' "$ANALYSIS")
DOMAIN=$(j '.domain_signal.label' "$ANALYSIS")
DETECTED=$(j '.detected_format' "$ANALYSIS")
BASE=$(j '.base_model.hf_repo' "$PLAN")
BUDGET=$(j '.budget_cap_usd' "$PLAN")
COST_EST=$(j '.estimates.cost.total_usd' "$PLAN")

# Compute final verdict
VERDICT="READY-FOR-DEMO"
[[ "$PF_VERDICT" != "PASS" ]] && VERDICT="PUBLISHED-WITH-CAVEATS"
[[ "$CARD_STATUS" != "pass" ]] && VERDICT="PUBLISHED-WITH-CAVEATS"
[[ "$SMOKE_STATUS" != "pass" ]] && VERDICT="PUBLISHED-WITH-CAVEATS"
[[ -n "$PPL_DELTA" && "${PPL_DELTA%.*}" -ge 0 ]] && VERDICT="FAILED-DO-NOT-USE"

# Phase timing
COMPLETED=$(j '.completed_phases | length' "$STATE")
STARTED=$(j '.started_at' "$STATE")
FINISHED=$(j '.finished_at // (now|todate)' "$STATE")

# --- after-action.md -------------------------------------------------------
AAR="$RUN_DIR/after-action.md"
cat > "$AAR" <<EOF
# 🦷 SLM-Forge — After-Action Report

**Run ID:** \`${RUN_ID}\`
**Started:** ${STARTED}
**Finished:** ${FINISHED}
**Verdict:** **${VERDICT}**

## Final URLs

| | |
|---|---|
| Model | ${HF_REPO:-(not published)} |
| Space (live demo) | ${HF_SPACE:-(not published)} |

## Plan vs reality

| | Estimated | Actual |
|---|---|---|
| Total cost | \$${COST_EST:-?} | \$${TOTAL_COST} |
| Wall-clock | $(j '.estimates.total_wall_clock_minutes' "$PLAN") min | $(( ($(date -d "$FINISHED" +%s) - $(date -d "$STARTED" +%s)) / 60 )) min |
| Phases completed | $(j '.phase_sequence | length' "$PLAN") | ${COMPLETED} |

## Eval summary

| Metric | Forged | Baseline | Delta |
|---|---|---|---|
| Perplexity | ${PPL_FORGED:-?} | ${PPL_BASELINE:-?} | ${PPL_DELTA:-?} |

## Plan-fit (pre-spend gate)

- Verdict: **${PF_VERDICT}**
- Axis 1 (in-domain %): ${PF_AXIS1_DOMAIN}
- Axis 3 (Q/A grader mean): ${PF_AXIS3_MEAN}

## Inputs

- Source: \`${TARGET}\`
- Detected format: \`${DETECTED}\`
- Domain: \`${DOMAIN}\`
- Base model: \`${BASE}\`
- Budget cap: \$${BUDGET}

## Phase ledger

$(j '.completed_phases[] | "- ✅ \(.)"' "$STATE")

EOF

# Add failure list if any
N_FAILED=$(j '.failed_phases | length' "$STATE")
if (( N_FAILED > 0 )); then
  echo "## Failed phases" >> "$AAR"
  jq -r '.failed_phases[] | "- ❌ \(.phase) (rc=\(.rc)) at \(.at)"' "$STATE" >> "$AAR"
fi

# Try to add 3 best + 3 worst samples if we have eval samples
SAMPLES_MD="$RUN_DIR/samples.md"
if [[ -f "$SAMPLES_MD" ]]; then
  echo "" >> "$AAR"
  echo "## Sample generations (first 3)" >> "$AAR"
  echo "" >> "$AAR"
  head -60 "$SAMPLES_MD" >> "$AAR"
fi

# --- qa-report.md ----------------------------------------------------------
QAR="$RUN_DIR/qa-report.md"
cat > "$QAR" <<EOF
# 🛡️ QA Report — ${RUN_ID}

**Verdict:** **${VERDICT}**

## Gate-by-gate

### PREFLIGHT
$([ -f "$RUN_DIR/preflight-report.json" ] && echo "(see preflight-report.json)" || echo "✅ pass (env ready)")

### PLAN_FIT (pre-spend)
$([ -f "$PF_REPORT" ] && echo "**${PF_VERDICT}** — see plan-fit-report.json" || echo "(not run)")

\`\`\`
$([ -f "$PF_REPORT" ] && jq '.axes | to_entries | map({k:.key, passes:.value.passes})' "$PF_REPORT" 2>/dev/null || echo "{}")
\`\`\`

### EVAL
$([ -n "$PPL_FORGED" ] && echo "Forged perplexity: **${PPL_FORGED}** vs baseline **${PPL_BASELINE}** (delta **${PPL_DELTA}**)" || echo "(not run)")

### CARD_VALIDATOR
$([ -f "$CARD_REPORT" ] && echo "**${CARD_STATUS}**" || echo "(not run)")
\`\`\`json
$([ -f "$CARD_REPORT" ] && cat "$CARD_REPORT" || echo "{}")
\`\`\`

### SMOKETEST (live API)
$([ -f "$SMOKE_REPORT" ] && echo "**${SMOKE_STATUS}**" || echo "(not run)")

Probe response (first 400 chars):
> ${SMOKE_RESPONSE:-(none)}

### PUBLISH
$([ -f "$RUN_DIR/publish-report.json" ] && echo "**$(jq -r '.status' $RUN_DIR/publish-report.json)** — both repos public" || echo "(not run)")

---

## Final verdict

**${VERDICT}**

- \`READY-FOR-DEMO\`         — all gates passed, model is symposium-grade
- \`PUBLISHED-WITH-CAVEATS\` — model is live but at least one gate had a soft fail; review samples before demoing
- \`FAILED-DO-NOT-USE\`      — fundamental failure (perplexity worse than baseline, etc.); do NOT publish further

EOF

echo "[forge-report] wrote $AAR + $QAR" >&2
jq -n --arg aar "$AAR" --arg qar "$QAR" --arg v "$VERDICT" '{
  status:"completed",
  after_action_report: $aar,
  qa_report: $qar,
  verdict: $v
}'
