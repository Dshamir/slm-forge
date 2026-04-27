---
name: forge-report
description: Final phase — emits two markdown deliverables to slm-forge/.runs/<run-id>/ summarizing the run. After-action.md covers what was built (URLs, cost ledger, sample outputs, caveats). QA-report.md covers every gate's verbatim PASS/FAIL plus a VERDICT line (READY-FOR-DEMO | PUBLISHED-WITH-CAVEATS | FAILED-DO-NOT-USE).
---

# forge-report

## When this fires

**Phase position: REPORT** — last phase in the sequence. Runs after TEARDOWN. The two MD files it writes are what the operator reads in the morning.

## What it does

1. Reads every artifact in `slm-forge/.runs/<run-id>/`:
   - `plan.json`, `analysis.json`, `state.json`
   - `eval-report.json`, `plan-fit-report-final.json`
   - `card-validator-report.json`, `smoketest-report.json`, `publish-report.json`
   - `samples.md` (if EVAL ran)
2. Computes the final verdict:
   - `READY-FOR-DEMO` — all gates passed cleanly
   - `PUBLISHED-WITH-CAVEATS` — published but one of PLAN_FIT / CARD_VALIDATOR / SMOKETEST had a soft fail
   - `FAILED-DO-NOT-USE` — fundamental failure (e.g. forged perplexity ≥ baseline)
3. Writes `after-action.md` with:
   - Final HF URLs
   - Plan vs. reality (estimated vs actual cost + wall-clock)
   - Eval summary (perplexity forged vs baseline, delta)
   - PLAN_FIT summary (axis 1 in-domain %, axis 3 Q/A grader mean)
   - Input recap (source, format, domain, base model, budget)
   - Phase ledger with ✅ per completed phase
   - First 3 sample generations (best-of)
4. Writes `qa-report.md` with gate-by-gate details + final verdict line

## Inputs
- `$1` = run-id

## Outputs
- `slm-forge/.runs/<run-id>/after-action.md`
- `slm-forge/.runs/<run-id>/qa-report.md`
- Stdout JSON: `{"status":"completed","after_action_report":"...","qa_report":"...","verdict":"..."}`

## Usage
```bash
bash slm-forge/skills/forge-report/run.sh <run-id>
```
