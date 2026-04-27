# 🦷 SLM-Forge plan — 20260425-163412-4b31

**Generated:** 2026-04-25T16:34:12Z

## Input

- **Target:** `slm-forge/corpora2/extracted/Publications`
- **Detected format:** `raw-documents`
- **Domain (auto):** `dental-research`
- **Estimated raw tokens:** 722,944,801
- **Estimated clean tokens after audit:** 96,392,640
- **Estimated Q/A pairs after synth:** 413,111

## Budget

- **Cap:** $430
- **Estimated total spend:** **$365.7790** (84% of cap)
  - Claude SYNTH: $358.0278 (Haiku 4.5)
  - Claude PLAN_FIT grading: $0.30 (Sonnet 4.6)
  - Claude SMOKETEST validator: $0.05
  - GPU compute: $7.4012 (g5.2xlarge @ $1.456/hr × ~5.0 hr)

## Plan

- **Base model:** `Qwen/Qwen2.5-7B-Instruct` (7.62B)
- **Regime:** `qlora-sft` (4-bit NF4 base + bf16 LoRA — fits 7B in 24 GB GPU)
- **LoRA:** r=32, alpha=64
- **Training:** 1500 steps, batch_size=2, grad_accum=4 (effective 8), max_seq_len=2048, grad_ckpt=true, lr=1e-4
- **Instance:** g5.2xlarge (24GB A10G) in ca-central-1 (auto-retry AZs)

## Phase sequence (computed from input format)

| # | Phase | Est | What |
|---|---|---|---|
| 1 | `prep` | 8 min | Extract text from raw documents (PDF/DOCX/PPTX/TXT) → unified JSONL |
| 2 | `audit` | 3 min | Drop contamination (LLM slop, off-domain, near-dup, safety boilerplate) |
| 3 | `synth` | 12 min | Generate Q/A pairs via Claude Haiku (factual + mechanism + clinical) |
| 4 | `shape` | 1 min | 80/10/10 train/val/test split, deterministic shuffle |
| 5 | `plan_fit` | 3 min | 🛡️ 7-axis pre-spend validation (Q/A quality + budget headroom — replaces post-train QUALITY_GATE) |
| 6 | `provision` | 2 min | Launch g5.2xlarge (auto-retry across AZs) |
| 7 | `bootstrap` | 7 min | Install training stack + llama.cpp on instance |
| 8 | `train` | 275 min | QLoRA 4-bit SFT, 1500 steps, batch=2×4, seq=2048 |
| 9 | `monitor` | 0 min | Poll training PID + sync checkpoints (auto, no human) |
| 10 | `eval` | 5 min | Perplexity vs baseline + 10 sample generations + auto artifact checks |
| 11 | `quantize` | 5 min | GGUF Q4_K_M + Q8_0 via llama.cpp |
| 12 | `register` | 4 min | Push HF model repo + Space + Modelfile (PRIVATE) |
| 13 | `card_validator` | 0 min | 🛡️ D-018 leak grep + template placeholder check |
| 14 | `smoketest` | 1 min | 🛡️ Live API call to Space, verify response is non-degenerate |
| 15 | `publish` | 1 min | Flip both repos PUBLIC + emit final URLs |
| 16 | `teardown` | 2 min | Terminate EC2 + reconcile cost via Cost Explorer |
| 17 | `report` | 1 min | Emit after-action.md + qa-report.md |


**Skipped phases** (not needed for `raw-documents` input): ``

**Total estimated wall-clock:** 330 min

## Acceptance thresholds (auto-checked, no human)

| Gate | Threshold | What happens on fail |
|---|---|---|
| AUDIT min clean tokens | ≥ 500,000 | Forge aborts; switch to RAG or expand corpus |
| PLAN_FIT mean Q/A score | ≥ 4.0 (Sonnet grader) | Forge aborts; re-synth with stronger prompt |
| PLAN_FIT min individual | ≥ 2.0 | Forge aborts |
| PLAN_FIT % in-domain | ≥ 95% | Forge aborts; tighten audit thresholds |
| PLAN_FIT budget fit | actual_synth + projected_plan_fit + projected_gpu ≤ budget_cap, with ≥10% cap headroom | Forge aborts BEFORE GPU spend; re-plan with smaller corpus or higher cap |
| EVAL artifact rate in samples | < 30% | Forge aborts; fix sampling params |
| EVAL forged perplexity | < baseline | Forge aborts; model didn't actually learn |
| CARD_VALIDATOR D-018 leaks | 0 | Forge aborts; fix template render |
| SMOKETEST live response | non-empty + non-degenerate | Forge aborts; investigate Space |

## Failure escalation

If ANY phase fails: forge tears down EC2 immediately, saves partial state to S3, emits `failure-report.md`, exits 1. **No recursive retry.** Surfacing the failure is the right behavior — operator wakes up to a clean state, not a frozen pipeline.

## After success

Two MD files written to `slm-forge/.runs/20260425-163412-4b31/`:
- `after-action.md` — final URLs, cost ledger, sample outputs (3 best, 3 worst), caveats
- `qa-report.md` — verbatim PASS/FAIL on every gate, verdict line: `READY-FOR-DEMO` | `PUBLISHED-WITH-CAVEATS` | `FAILED-DO-NOT-USE`

---

## To approve

```bash
bash slm-forge/scripts/approve-plan.sh 20260425-163412-4b31
```

## To reject + adjust

```bash
bash slm-forge/scripts/teardown-run.sh 20260425-163412-4b31
# Then either re-run /slm-forge with different args, or edit slm-forge/skills/forge-plan/../../../slm-forge/.runs/20260425-163412-4b31/plan.json
# manually and re-approve.
```
