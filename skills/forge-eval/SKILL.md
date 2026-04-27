---
name: forge-eval
description: Runs perplexity vs. baseline + 10 sample generations on the trained model, on the EC2 instance. Detects artifact patterns (repetition loops, GGUF tokenizer bugs, degenerate outputs) — fails the run when artifact_pct exceeds FORGE_EVAL_MAX_ARTIFACT_PCT (default 30%). The automated quality gate that replaces the v1 manual QUALITY_GATE.
---

# forge-eval

## When this fires

**Phase position: EVAL** — after `forge-monitor` returns `completed`.
On the v2 path, `forge-plan-fit` already did corpus-level QA before
spend; EVAL handles post-train output-quality validation.

## What it does

1. Verify `manifest.artifacts.final_weights_s3` exists
2. Upload `eval.py` to the instance via SSM
3. Run perplexity on the held-out test split (vs. the base model for diff)
4. Generate 10 sample completions on canonical prompts
5. **Artifact-pattern detection** — scan generations for:
   - >30% repetition (n-gram self-similarity)
   - GGUF tokenizer artifacts (mojibake / control chars)
   - Degenerate loops (same token N+ times)
   - Refusal-only outputs (model collapsed to "I cannot help")
6. Write `eval/{perplexity.json, samples.md, report.json}` and sync to S3
7. **Hard-fail** if `artifact_pct > FORGE_EVAL_MAX_ARTIFACT_PCT` (default 30%)
8. Advance to `QUANTIZE` (or `QUALITY_GATE` on legacy v1)

## Inputs
- `$1` = forge-id
- `manifest.artifacts.final_weights_s3` (LoRA adapter or merged weights)
- `manifest.compute_target.instance_id`
- `manifest.plan.base_model` (for baseline perplexity)
- `FORGE_EVAL_MAX_ARTIFACT_PCT` (env, default 30)

## Outputs
- `/workspace/eval/{perplexity.json, samples.md, report.json}` (on instance)
- `s3://.../eval/reports/`
- `manifest.artifacts.eval_reports_s3`
- `manifest.state.current_phase = QUANTIZE`

## Idempotency
If `manifest.artifacts.eval_reports_s3` is set, exits 0.

## Failure modes

| Exit | Reason |
|---|---|
| 0  | eval clean (artifact_pct under threshold) |
| 1  | LoRA merge failed OR `eval.py` timeout OR artifact_pct > threshold (training collapsed — model unfit to ship) |
| 64 | no forge-id provided |

A failure here is **terminal** — `dispatch-v2.sh` will tear down the
instance and skip QUANTIZE/REGISTER/PUBLISH. The repos stay private.

## External resources
- AWS EC2 (SSM RunCommand to execute eval.py)
- AWS S3 (sync reports)
- HuggingFace model cache (for the baseline diff)

## Cost class
**spends GPU time** — eval runs on the same hourly EC2 meter.

## Depends on
`forge-monitor` (must have synced `final_weights_s3`)
