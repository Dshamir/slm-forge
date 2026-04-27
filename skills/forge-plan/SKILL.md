---
name: forge-plan
description: Takes analysis.json + budget cap → derives the full phase sequence, hyperparameters, instance type, cost estimate, and acceptance thresholds. Emits plan.md (the single human gate document) and plan.json (the machine-readable spec that dispatch-v2 consumes). Refuses to plan if estimated cost exceeds budget×1.2.
---

# forge-plan

## When this fires

**Phase position: PLAN** — third skill fired by `forge.sh`, after PREFLIGHT and ANALYZE. The last thing that runs before the single human gate.

## What it does

1. Reads `analysis.json` (from forge-analyze) + budget cap (from operator)
2. Picks base model from a **budget-size ladder**:
   - `< $5`   → Qwen2.5-0.5B (494M, `lora-sft`)
   - `< $50`  → Qwen2.5-1.5B-Instruct (1.54B, `lora-sft`)
   - `< $100` → Qwen2.5-3B-Instruct (3.09B, `lora-sft`, r=16)
   - `≥ $100` → Qwen2.5-7B-Instruct (7.62B, `qlora-sft` 4-bit, r=32)
3. Picks instance + hyperparameters to fit the 24 GB VRAM ceiling of ca-central-1 GPUs:
   - 0.5B → g5.xlarge, batch=4, seq=1024, no grad_ckpt
   - 1.5B → g5.xlarge, batch=2, seq=512, grad_ckpt
   - 3B → g5.2xlarge, batch=2, seq=1024, grad_ckpt
   - 7B → g5.2xlarge + QLoRA, batch=2, seq=2048, grad_ckpt
4. Computes `max_steps` for ~2.5 epochs, capped at 1500 to prevent memorization
5. Estimates costs: Claude SYNTH (Haiku), PLAN_FIT grading (Sonnet), SMOKETEST probe (Haiku), GPU compute
6. Estimates total wall-clock from per-phase timing heuristics
7. Writes `plan.json` + `plan.md`
8. **Budget guardrail:** if `cost_total > budget × 1.2`, exits with code 2 and writes `plan-refused.md` instead — operator must raise budget, subsample corpus, or switch to a cheaper base

## Inputs
- `$1` = path to analysis.json
- `$2` = budget cap in USD (bare number)

## Outputs
- Writes `slm-forge/.runs/<run-id>/plan.json` — the machine-readable spec
- Writes `slm-forge/.runs/<run-id>/plan.md` — the human-readable gate document
- On over-budget: writes `plan-refused.md`, exits 2
- On success: prints the path to plan.md on stdout

## plan.json schema (key fields)

```json
{
  "run_id": "...",
  "target_dir": "...",
  "domain": "...",
  "detected_format": "raw-documents|pretrain-jsonl|chat-jsonl|mixed",
  "budget_cap_usd": 25,
  "base_model": {"hf_repo": "Qwen/Qwen2.5-1.5B-Instruct", "params_label": "1.54B"},
  "regime": "lora-sft|qlora-sft",
  "framework": "huggingface-trainer",
  "chat_template": "qwen2",
  "training_overrides": {
    "max_steps": 625, "batch_size": 2, "grad_accum": 4,
    "max_seq_len": 512, "grad_ckpt": true,
    "lora_r": 8, "lora_alpha": 16, "learning_rate": "1e-4", "epochs": 1
  },
  "compute": {"instance_type": "g5.xlarge", "hourly_usd": 1.212, "subnet_strategy": "auto-retry-azs"},
  "estimates": {"clean_tokens": N, "qa_pairs": N, "total_wall_clock_minutes": N, "cost": {...}},
  "phase_sequence": ["shape", "plan_fit", "provision", ...],
  "skip_phases": ["prep", "audit", "synth"],
  "acceptance_thresholds": {
    "audit_min_clean_tokens": 500000,
    "plan_fit_min_qa_mean": 4.0,
    "plan_fit_min_qa_individual": 2.0,
    "plan_fit_min_in_domain_pct": 0.95,
    "plan_fit_max_type_pct": 0.50,
    "eval_max_artifact_pct": 0.30,
    "eval_perplexity_must_beat_baseline": true
  }
}
```

## Usage
```bash
bash slm-forge/skills/forge-plan/run.sh <analysis.json> <budget-usd>
```
Typically called indirectly via `forge.sh <target> <budget>` — not run standalone.
