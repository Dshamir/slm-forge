# Forged model vs. baseline (Qwen2.5-3B-Instruct)

> **Skeleton drafted pre-eval, 2026-04-25.** Numbers TBD when eval phase completes. Replace TBD placeholders with values from `perplexity.json`.

## Decision criteria (pre-committed before eval)

**Locked in before data arrives. Do not adjust thresholds after seeing numbers.** The point of pre-commitment is to prevent the failure mode where the bar moves to match whatever the result was. If the data lands between bands, follow the rules; don't re-litigate.

### Criterion 1 — Aggregate held-out perplexity reduction vs baseline

| Reduction | Verdict |
|---|---|
| **≥ 20%** | READY direction |
| 10% – 20% | WITH-CAVEATS |
| **< 10%** | DO-NOT-PUBLISH |

*Reasoning:* QLoRA SFT on 5,875 Q/A from a domain-specific corpus, evaluated on held-out chunks from same corpus, should comfortably hit 15-30% reduction. Below 10% means fine-tuning effectively didn't take — corpus too noisy, lr too low, or the base already covered this distribution. Not worth shipping. ≥20% is the empirically-typical "fine-tune worked" band; 10-20% is "did something useful but underwhelming," ship with caveats.

### Criterion 2 — Per-subtopic floor (worst subtopic with n≥30 test pairs)

| Worst subtopic improvement (as fraction of aggregate improvement) | Verdict |
|---|---|
| **≥ 40%** | READY direction |
| 0% – 40% (still beats baseline, but weakly) | WITH-CAVEATS |
| **< 0% (regressed vs baseline)** | DO-NOT-PUBLISH |

*Examples:* if aggregate reduction is -25%, worst large subtopic must show ≥-10% (40% of 25) for READY, between 0 and -10% for CAVEATS, > 0 (regressed) is DO-NOT-PUBLISH.

*Subtopics with n<30 test pairs* (i.e., `segmentation` n=6, `crown_generation` n=31 — borderline): reported in the per-subtopic table but **not gated** because n is too small for a confident regression signal. Their numbers go in the model card as "directional only."

*Reasoning:* Z=40% means the worst large subtopic gets at least 40% of the aggregate's lift. That's lenient enough to accept some unevenness (some bucket will always be the worst), but strict enough that we don't ship a model where one subtopic is silently broken while the dominant bucket carries the average. Hard floor at 0%: a regressed subtopic means the fine-tune actively *hurt* on that bucket — that's the failure mode this whole per-subtopic eval was built to catch.

### Criterion 3 — Train vs held-out gap (overfitting signature)

Compute: `train_reduction_pct / held_out_reduction_pct` from final-100-step training loss vs held-out test perplexity, both as % reduction from baseline.

| Ratio (train_reduction / held_out_reduction) | Verdict |
|---|---|
| **≤ 1.5×** | READY direction |
| 1.5× – 2.5× | WITH-CAVEATS |
| **> 2.5×** | DO-NOT-PUBLISH |

*Reasoning:* Healthy fine-tunes show training and held-out improving together — ratio close to 1.0×. A widening gap is the classic overfitting signature. 1.5× tolerates normal generalization gap. >2.5× means the LoRA memorized training-Q/A patterns without learning generalizable dental knowledge — symptomatic of either too many steps for the corpus size, or LoRA rank too high. The fix is replan with fewer steps or r=16, not ship.

*Source data:* training loss from forge-train's log (final 100 steps averaged), or `train_loss` from any monitor checkpoint. Convert to perplexity = exp(loss). Compare `train_ppl` reduction to `merged_ppl` (held-out) reduction. **eval.py does not compute this today** — needs a one-off bash to extract train ppl from the training log post-eval. Trivial; the numbers are in the log.

### Criterion 4 — Artifact rate in sample generations

| Artifact rate | Verdict |
|---|---|
| **< 10%** | READY direction |
| 10% – 30% | WITH-CAVEATS |
| **> 30%** | DO-NOT-PUBLISH |

*Reasoning:* The existing eval-phase gate is 30%, so >30% already triggers a hard fail in the auto-pipeline. Tightening the READY band to <10% reflects that "10-30% artifacts" means noticeable degenerate generations (repetition loops, GGUF tokenizer artifacts, hallucinated technical terms) even though the model is shippable. <10% means clean.

### Combining rule (mechanical, no judgment)

The overall verdict is the **worst level across all four criteria.**

- Any DO-NOT-PUBLISH → overall **DO-NOT-PUBLISH**
- Else any WITH-CAVEATS → overall **PUBLISH-WITH-CAVEATS**
- Else all four READY → overall **READY-FOR-DEMO**

No re-weighting. No "well, criterion 3 was almost 1.5× so let's call it READY." If the ratio was 1.6×, it's WITH-CAVEATS. The mechanical rule is the entire point of pre-committing.

---



## Test set composition

Held-out test split, stratified across all 4 subtopics. Built by `forge-shape` from the post-filter `qa-filtered.jsonl` (5,875 Q/A pairs after off-topic references removed).

| Subtopic | Test pairs |
|---|---|
| crown_generation | 31 |
| dental_ai_general | 183 |
| margin_line | 78 |
| segmentation | 6 |
| **Total** | **298** |

Note: `segmentation` test set is very small (n=6). Treat its perplexity number as a directional signal, not a statistically meaningful comparison.

---

## Aggregate perplexity

| metric | merged model | baseline (Qwen2.5-3B-Instruct) | delta |
|---|---|---|---|
| perplexity | TBD | TBD | TBD |

**Lower perplexity is better.** Delta < 0 means forging improved over baseline on the dental research test split.

**Acceptance:** delta < 0 required by `eval_perplexity_must_beat_baseline: true` in plan.json acceptance_thresholds.

---

## Per-subtopic perplexity

The per-subtopic split was added specifically to detect the failure mode where one subtopic silently degrades while crown_generation pulls the aggregate up.

| subtopic | n_test | merged ppl | baseline ppl | delta | interpretation |
|---|---|---|---|---|---|
| crown_generation | 31 | TBD | TBD | TBD | TBD |
| dental_ai_general | 183 | TBD | TBD | TBD | TBD |
| margin_line | 78 | TBD | TBD | TBD | TBD |
| segmentation | 6 | TBD | TBD | TBD | TBD (n=6, weak signal) |

**Watch:** if any subtopic's merged ppl is *worse* than baseline (delta > 0) while aggregate improved, the model is unevenly trained — likely a data-imbalance signal. The most-likely subtopic to fail this check is **segmentation** (only 99 training Q/A) followed by **crown_generation** (the model may overfit to the dominant team's voice).

---

## Sample generations — generic prompts (10 from `samples-prompts`)

Standard domain-agnostic prompts, no subtopic seed. Demonstrates the model's general voice and coherence.

[Filled in from `samples.md` post-eval]

---

## Sample generations — per subtopic (2 seeds × 4 subtopics = 8 samples)

Each subtopic gets 2 generation seeds drawn from the first ~80 chars of test docs in that subtopic. Demonstrates whether the model can continue domain-appropriate research text per bucket.

### crown_generation

**Seed 1:** TBD
**Continuation:** TBD

**Seed 2:** TBD
**Continuation:** TBD

### margin_line

**Seed 1:** TBD
**Continuation:** TBD

**Seed 2:** TBD
**Continuation:** TBD

### segmentation

**Seed 1:** TBD
**Continuation:** TBD

**Seed 2:** TBD
**Continuation:** TBD

### dental_ai_general

**Seed 1:** TBD
**Continuation:** TBD

**Seed 2:** TBD
**Continuation:** TBD

---

## Artifact rate (eval phase auto-check)

The eval phase scans samples for repetition loops, GGUF artifacts, hallucination markers, and degenerate generations. Acceptance threshold: **<30% artifact rate**.

| Metric | Value |
|---|---|
| Total samples checked | TBD |
| Samples flagged as artifacts | TBD |
| Artifact rate | TBD% |
| Gate (<30%) | TBD: PASS / FAIL |

---

## Verdict

**Decision: TBD** — one of:
- ✅ **READY-TO-PUBLISH** — aggregate beats baseline, all subtopics deltas <0 OR within ±10% of baseline, artifact rate <30%, samples coherent
- ⚠️ **PUBLISH-WITH-CAVEATS** — aggregate beats baseline but ≥1 subtopic regressed; document weakness in model card, publish anyway
- ⛔ **DO-NOT-PUBLISH** — aggregate worse than baseline OR multiple subtopics regressed OR artifact rate >30%; replan with adjusted training (more steps / different LoRA rank / smaller base / corpus expansion)

**Reasoning:** TBD

**Recommended next step:**
- If READY-TO-PUBLISH: fire `bash scripts/approve-plan.sh 20260425-163412-4b31` (no STOP_AFTER_PHASE) — runs quantize → register → card_validator → smoketest → publish → teardown → report. Estimated ~25 min, ~$0.50 idle GPU.
- If PUBLISH-WITH-CAVEATS: same fire, but update `model-card-draft.md` with caveats first, then proceed.
- If DO-NOT-PUBLISH: `bash scripts/teardown-run.sh 20260425-163412-4b31` to terminate instance immediately. Replan adjustments — typical fixes: increase training steps to 2500, drop LoRA rank to r=16 (less capacity = less overfitting), or accept the model and document the regressions.

---

## Spend reconciliation

| Line item | Projected | Actual | Variance |
|---|---|---|---|
| Synth (Haiku 4.5) | $358.03 | $6.49 | -98% (corpus 50× smaller than analyzed) |
| Plan-fit grading (Sonnet) | $0.30 × 4 runs = $1.20 | $1.20 | 0% |
| Folder/refs classification (Haiku) | ~$0.50 | ~$0.50 | — |
| GPU (g5.2xlarge × ~3.5hr) | $5.10 | TBD | TBD |
| **Total at eval** | **~$13.30** | **TBD** | |
| Headroom vs $500 cap | ~$486.70 | TBD | |

The original $358 synth projection assumed 96M clean tokens. Actual was 1.64M post-filter — analyze.json had estimated raw tokens by file size (11 GB), but most of that was non-text (videos, STL meshes, MySQL dumps, image files). Lesson for future runs: file-size → token estimate is unreliable for mixed-media corpora; analyze should sample-extract before estimating.

---

*Skeleton last updated: 2026-04-25 pre-eval. Replace all TBDs with values from `perplexity.json`, `samples.md`, and the eval phase output.*
