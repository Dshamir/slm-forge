---
name: forge-plan-fit
description: Pre-training plan validation gate. Runs after SHAPE and before PROVISION. Validates the corpus + Q/A + hyperparameters + budget headroom for the target domain. Hard PASS/FAIL on seven axes — all must pass. Replaces the post-training QUALITY_GATE (which arrived too late, after GPU $ was already spent).
---

# forge-plan-fit

## Why this exists

The post-training QUALITY_GATE arrived too late: by the time a human reviewed
trained-model samples, $2-5 of GPU time had already burned and the failure
mode was usually traceable to corpus / Q/A / hyperparameter problems that
could have been caught earlier and cheaper.

forge-plan-fit moves the quality gate to **before any GPU spend**. It validates
that the *plan is bulletproof for the target domain* by sampling artifacts and
running a structured 7-axis check.

## When this fires

Phase position: **PLAN_FIT** — runs after SHAPE (we have ready-to-train Q/A
data) and before PROVISION (no GPU launched yet). On PASS, dispatcher
auto-advances to PROVISION. On FAIL, the forge aborts with a structured
report telling the operator which axis to fix.

## The 7 axes (ALL must pass)

| Axis | Check | Pass criterion | Cost |
|---|---|---|---|
| **1. Corpus content** | Claude classifies a sample of chunks into domain subdomains vs off-topic | ≥95% in-domain, < 5% off-topic | ~$0.50 |
| **2. Coverage balance** | Distribution across subdomains (e.g. for dental: restorative / endo / perio / pros / ortho / oral surgery / dental-AI) | No subdomain < 5% | $0 |
| **3. Q/A accuracy** | Claude (acting as domain expert) grades sampled Q/A pairs on factual correctness + appropriateness (1-5 scale) | Mean ≥ 4.2, no individual < 3.0 | ~$1.00 |
| **4. Q/A diversity** | Q/A type distribution (factual / mechanism / clinical / methodology) | No single type > 40% | $0 |
| **5. Hyperparameter fit** | Rank vs token count, epochs vs corpus size, LR vs base size — heuristic ranges | All in known-safe envelopes | $0 |
| **6. Training format** | 5 random examples roundtripped through tokenizer.apply_chat_template | All produce well-formed `<\|im_start\|>` / `<\|im_end\|>` framing | $0 |
| **7. Budget fit** | Compare `actual_synth_usd` + projected `plan_fit` + `gpu` against `budget_cap_usd`; enforce minimum headroom | `spent + projected ≤ cap` AND `cap − projected ≥ cap × headroom_frac` (default 10%) | $0 |

## Inputs (manifest)
- `manifest.spec.domain`
- `manifest.plan.{base_model, regime, target_params}`
- `manifest.training_overrides.{batch_size, max_steps, max_seq_len, lora_r, lora_alpha, learning_rate, epochs}`
- `manifest.artifacts.shaped_corpus_s3` (Q/A pairs in chat format)

## Outputs (manifest)
- Writes 6-axis report to `s3://.../plan-fit/report.json`
- On PASS: advances to PROVISION
- On FAIL: writes recovery_hint per axis; phase stays at PLAN_FIT_GATE

## Domain expert grading

Uses Claude Opus 4.7 (`claude-opus-4-7`) for axis 3 (correctness grading) —
the most capable model available, since false positives here pass garbage to
GPU spend. Uses Claude Haiku 4.5 (`claude-haiku-4-5`) for axis 1 (subdomain
classification) — cheap, good enough for clear-cut category labels.

## Override env vars
- `FORGE_PLAN_FIT_SAMPLE_SIZE` (default 50) — Q/A pairs to grade
- `FORGE_PLAN_FIT_MIN_DOMAIN_PCT` (default 0.95)
- `FORGE_PLAN_FIT_MIN_QA_MEAN` (default 4.2)
- `FORGE_PLAN_FIT_MIN_QA_INDIVIDUAL` (default 3.0)
- `FORGE_PLAN_FIT_MIN_SUBDOMAIN_PCT` (default 0.05)
- `FORGE_PLAN_FIT_BUDGET_HEADROOM` (default 0.10) — fraction of `budget_cap_usd` that must remain after projected total

## Failure recovery

| Axis | Typical fail | Fix |
|---|---|---|
| 1 | < 95% in-domain | Tighten forge-audit's domain density threshold; re-run from CURATE |
| 2 | A subdomain has 0% representation | Either accept narrower model OR expand corpus to cover that subdomain |
| 3 | QA mean < 4.2 | Re-run forge-synth with stronger system prompt (more grounding language) |
| 4 | One QA type dominates | Re-run forge-synth balancing the type distribution |
| 5 | Hyperparams off | Update training_overrides in manifest (smaller rank, fewer epochs, etc.) |
| 6 | Template doesn't roundtrip | Bug in forge-shape's chat formatting; debug locally before re-dispatching |
| 7 | `OVER_CAP`: synth overran so badly that `spent + projected_gpu > cap` | Abort forge; re-plan with smaller corpus subsample or higher cap |
| 7 | `UNDER_HEADROOM`: projected total within cap but cushion too thin | Operator decision — lower `FORGE_PLAN_FIT_BUDGET_HEADROOM` if accepted, or raise cap, or subsample |

## Usage
```bash
bash slm-forge/skills/forge-plan-fit/run.sh <forge-id>
```
