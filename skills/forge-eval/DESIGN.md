# forge-eval — DESIGN.md

> **Status:** M5-prep design doc. Implementation lives in `run.sh`
> when M5 unblocks (M5 starts after M4 produces final weights).

## Phase

`EVAL → QUALITY_GATE`. Triggered after MONITOR returns `completed` with
`artifacts.final_weights_s3` populated.

## Inputs read from manifest

- `manifest.artifacts.final_weights_s3` (downloaded to `/workspace/weights/final/`)
- `manifest.spec.{domain, language, target_quality}`
- `manifest.plan.{base_model, chat_template}`
- `manifest.compute_target.{instance_id}`
- `manifest.cost_tracking.budget_cap_usd` (cost gate)

## Outputs written to manifest

- `s3://forge/<id>/eval/reports/domain-bench-report.{json,md}`
- `s3://forge/<id>/eval/reports/generic-bench-report.{json,md}`
- `s3://forge/<id>/eval/reports/comparison-vs-baseline.{json,md}`
- `s3://forge/<id>/eval/samples.md` (20 generations covering domain tasks)
- `manifest.artifacts.eval_reports_s3` = `s3://forge/<id>/eval/reports/`
- Phase advance: `EVAL → QUALITY_GATE`

## Procedure

1. **Cost-gate.** `cost_to_date + estimated_eval_cost ≤ budget_cap_usd`. Eval is GPU-bound (~15-60 min). Pre-estimate using corpus token count × 2 epochs × eval rate.

2. **Push eval driver to instance.** `slm-forge/scripts/eval-harness.sh` (NEW M5) handles:
   - `pip install lm-eval` (idempotent)
   - Routes per regime + domain
   - Writes structured outputs to `/workspace/eval/`

3. **Run generic eval (lm-eval-harness subset).**
   ```
   lm_eval --model hf \
           --model_args pretrained=/workspace/weights/final,trust_remote_code=False \
           --tasks hellaswag,arc_easy,winogrande \
           --batch_size auto \
           --output_path /workspace/eval/generic-bench.json
   ```
   - Tasks chosen: small + fast (15 min total on g5.xlarge for 300M model). Replace with deeper task set for production-grade eval (M5+ hardening).

4. **Run baseline diff.**
   - Same eval, same tasks, but `pretrained=$plan.base_model`.
   - Side-by-side delta table (forged - base, per task).

5. **Run domain-specific eval.** Domain → eval-set router:

   | spec.domain prefix | Eval set | Source |
   |---|---|---|
   | `dental.*` | curated dental QA (50 prompts) | `slm-forge/eval-sets/dental-qa.jsonl` (NEW) |
   | `legal.*` | CUAD-lite subset | HF dataset `theatticusproject/cuad-qa` |
   | `code.*` | humaneval subset | HF dataset `openai/openai_humaneval` |
   | `medical.*` | MedQA subset | HF dataset `bigbio/med_qa` |
   | (other) | perplexity on test split only | data/shaped/test.jsonl |

   For M5-v1: implement `dental.*` + perplexity-fallback. Other domains land as M5+ hardening.

6. **Run perplexity on test split.**
   ```python
   # eval-harness.sh helper
   python -c "from transformers import ...; ppl = compute_perplexity(...); print(json.dumps({'perplexity': ppl}))"
   ```

7. **Generate 20 samples.**
   - 20 prompts from `slm-forge/eval-sets/<domain>-sample-prompts.txt` (with generic fallback covering "explain X", "what is Y", "how do I Z", etc.).
   - Use llama.cpp `llama-cli` (already built by bootstrap) at temperature 0.7, max 200 tokens.
   - Write to `samples.md` as `## Prompt N\n<prompt>\n### Response\n<output>` blocks.

8. **Sync reports to S3.** All four reports (JSON + MD pairs) + samples.md.

9. **Generate executive summary** for the master skill to print at QUALITY_GATE:
   ```
   forge-id: ...
   domain: dental.patient-education
   generic eval (acc):    arc_easy=0.45  hellaswag=0.31  winogrande=0.55
   baseline (Qwen2.5-0.5B): arc_easy=0.51  hellaswag=0.34  winogrande=0.58
   delta:                  -0.06         -0.03         -0.03
   domain eval (dental):  pass=14/20  partial=4/20  fail=2/20
   perplexity (test):     12.3
   sample (1/20): "What is a dental crown?" → "A dental crown is a tooth-shaped cap..."
   ```

10. **Return** `{"status":"completed","next_phase":"QUALITY_GATE","forge_id":"…","summary":{...}}`.

## Failure modes (return contract)

| Failure | recoverable | recovery_hint |
|---|---|---|
| lm-eval OOM at batch_size=auto | true | `re-run with batch_size=1` (the harness will accept env override) |
| Domain eval set missing for domain | true | `falls back to perplexity-only; add eval-set under slm-forge/eval-sets/ for full coverage` |
| All samples produce gibberish (output is < 10 chars or repeats) | false | `training failed silently — back to ARCHITECT, amend plan` |
| Baseline download fails (HF rate-limit / token) | true | `retry; if persistent, skip baseline diff with warning` |
| Disk full (eval intermediates) | true | `forge-provision with larger ebs_gb` |

## Idempotency

If `artifacts.eval_reports_s3` is already populated, short-circuit. Re-running
forge-eval explicitly requires deleting that field first (or `--force`).

## Notes on quality gate

forge-eval does NOT decide pass/fail — that's the master skill's QUALITY_GATE
prompt to the user. forge-eval's job is to surface evidence. The user
(Daniel) reads the executive summary + samples and decides:
- Approve → master advances to QUANTIZE
- Reject → master routes back to ARCHITECT (amend plan + restart) or to TEARDOWN (abandon)

## Key references

- `slm-forge-brief/skills/SKILL_SPECS.md § forge-eval`
- `slm-forge-brief/architecture/PHASE_TABLE.md § QUALITY_GATE`
- `slm-forge-brief/DEMO_REQUIREMENTS.md § Eval section in model card`
