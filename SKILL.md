---
name: slm-forge
description: SLM-Forge master skill (v2.3). Single-gate, fully-autonomous pipeline that takes a directory of ~138 file extensions (19 plugins covering documents, code, archives, OCR, audio/video, mesh, email, DICOM, geo, scientific, and orphaned MySQL data dirs), a JSONL, OR a multi-source config.yaml combining 10 source kinds (local_dir, archive, http, jsonl, hf_dataset, database, git, s3, gcs, azure) with cross-source dedup, plus a budget cap — and produces a trained, evaluated, quantized, published small language model on HuggingFace. 10 first-class DB adapters (sqlite/postgres/mysql/mongodb/duckdb/mssql/clickhouse/snowflake/bigquery/cassandra). Credentials via env / file / Vault refs with stack-trace-safe Secret wrappers. Use when the user says "forge an SLM", "train a small language model from this corpus", "build a domain SLM", "fine-tune a model", "make a quantized model for LM Studio/Ollama", or invokes /slm-forge. Invocation: /slm-forge <target-dir-or-jsonl-or-yaml> <budget-usd> [--domain LABEL]. Runs preflight → analyze → plan, then halts at ONE human gate (PLAN_GATE). After approve-plan.sh fires, dispatch-v2 runs every remaining phase autonomously and emits after-action.md + qa-report.md.
---

# slm-forge — master orchestrator (v2.3)

**Status:** v2.3 shipped. v2 plan-executor is the baseline; v2.1 added
plugin-driven multi-format extraction + the SQLite/Postgres ingest skill;
v2.2 added MySQL/MongoDB adapters, a Python vault-client, multi-source
`config.yaml` fan-out, and a MySQL auto-revive plugin. v2.2.1/v2.2.2
hardened the surface (zip-slip, chat-dedup, schema, HTTP retries, disk
checks). v2.3 expanded coverage: 4 new file plugins (email/DICOM/geo/
scientific), 6 new DB adapters (duckdb/mssql/clickhouse/snowflake/
bigquery/cassandra), 4 new source kinds (git/s3/gcs/azure), `--dry-run`
mode, progress reporting, and the stack-trace-safe `Secret` wrapper.
All skills committed on branch `poly_updates`.

## What this skill is

The user-facing entry point for the SLM-Forge skill tree. In v2 the
orchestrator is **three separate stages**:

1. **`forge.sh`** (preflight → analyze → plan) → produces `plan.md`
2. **PLAN_GATE** (human reads plan.md, runs `approve-plan.sh <run-id>`)
3. **`dispatch-v2.sh`** (autonomous, plan-executor) → produces `after-action.md` + `qa-report.md`

No more inline human loops in the dispatcher. No more stopping at
`BUDGET_GATE` and `QUALITY_GATE` mid-run — those have been respectively
rolled into `PLAN_GATE` and replaced by the automated `forge-plan-fit`
gate that fires BEFORE GPU spend.

## Trigger patterns

- Slash command: `/slm-forge <target> <budget> [--domain LABEL]`
- Natural language: "forge an SLM for X", "train a small model from this corpus", "build a dental/legal/medical SLM"

## Procedure

### Stage 1 — forge.sh (no spend, ~1 min)

Fired by the slash command. Runs in order:

1. **PREFLIGHT** (`forge-preflight`) — checks creds, host tools, vCPU quota, AZ availability, disk. Hard-fails with structured "what to fix" if anything's missing.
2. **ANALYZE** (`forge-analyze`) — walks target dir, classifies file types, detects format (raw-documents | pretrain-jsonl | chat-jsonl | mixed), suggests domain via Claude Haiku.
3. **PLAN** (`forge-plan`) — picks base model from the budget-size ladder (0.5B/1.5B/3B/7B), derives hyperparameters for the 24 GB VRAM ceiling, computes cost estimate, writes `plan.json` + `plan.md`. Refuses (exit 2, writes `plan-refused.md`) if projected cost > budget × 1.2.

### Stage 2 — PLAN_GATE (human, ~5 min)

The operator reads `plan.md` and runs one of:
- **APPROVE:** `bash slm-forge/scripts/approve-plan.sh <run-id>` — touches `approved` marker, fires `dispatch-v2` via setsid-detached nohup
- **REJECT:** `bash slm-forge/scripts/teardown-run.sh <run-id>` — cancels, no spend

### Stage 3 — dispatch-v2 (autonomous, ~60-120 min, GPU billed)

Reads `plan.json.phase_sequence` and executes each phase in order. The
sequence is dynamic — it was derived from the input format:

| Input format | phase_sequence |
|---|---|
| raw documents | prep → audit → synth → shape → plan_fit → provision → bootstrap → train → monitor → eval → quantize → register → card_validator → smoketest → publish → teardown → report |
| pretrain jsonl | (skips prep) audit → synth → ... |
| chat jsonl | (skips prep/audit/synth) shape → plan_fit → ... |
| multi-source config.yaml (v2.2+) | **ingest** → audit → synth → ... (replaces prep with the fan-out merger) |

Mixed pretrain+chat JSONL in one directory is **rejected** at analyze
(exit 65) — the operator must split or pre-merge to a single schema.

For each phase:
- **pre-check:** if already completed per `state.json.completed_phases`, skip (idempotent re-run)
- **run:** exec the skill's `run.sh` with the run-id; skill is responsible for its own work + manifest/state updates
- **post-check:** on success → mark completed, advance; on failure → call on_failure

**on_failure:**
1. Terminate any live EC2 (reads `state.json.instance_id`)
2. Write `failure-report.md` with: failed phase, exit code, completed phases, state snapshot, recovery hint
3. Exit 1 — operator wakes up to a clean state (no live billing)

**The 3 automated quality gates embedded in the sequence:**
- `plan_fit` — 7 axes (corpus/coverage/Q&A accuracy/diversity/hyperparams/format/budget), fails → teardown before GPU
- `eval` — artifact-pattern detection on samples (repetition/GGUF artifacts/loops), >30% bad → fails → teardown
- `card_validator` + `smoketest` — card leak grep + live Space probe; fails → PUBLISH never runs → repos stay private

## Library layer (sourced by skills, not invoked directly)

| File | Purpose |
|---|---|
| `lib/manifest.sh` | jq + aws s3api wrappers; optimistic concurrency via S3 versioning |
| `lib/compute_aws.sh` | AWS EC2 lifecycle. Auto-retry across AZs on InsufficientInstanceCapacity. ca-central-1 pinned. |
| `lib/s3.sh` | S3 helpers. SSE-KMS via `alias/<YOUR_S3_BUCKET>`. |
| `lib/hf.sh` | HuggingFace Hub wrappers. |
| `lib/secrets.py` (v2.2) | Python credential resolver: env: / file: / vault: refs, TTL-cached, redact_for_logging helper. Used by every DB adapter and the multi-source ingest fan-out. |

## Configuration

- `config/whitelist.json` — v1 base model whitelist (v2 ladder is in forge-plan/run.sh)
- `config/pricing.json` — ca-central-1 GPU instance rate snapshot
- `templates/` — model-card.md.tmpl, space-app.py.tmpl, ollama-modelfile.*.tmpl, eval-config.yaml.tmpl

## Deliverables at `slm-forge/.runs/<run-id>/`

On success:
- `after-action.md` — final URLs, cost ledger, sample generations, caveats
- `qa-report.md` — gate-by-gate PASS/FAIL + verdict line (READY-FOR-DEMO | PUBLISHED-WITH-CAVEATS | FAILED-DO-NOT-USE)

On failure:
- `failure-report.md` — phase that died, recovery hint, state snapshot
- `dispatch.log` — streaming log of everything

## See

- `README.md` — user-facing entry + prerequisites
- `docs/TOMORROW.md` — cold-start playbook
- `scripts/forge.sh` — Stage 1 entry point
- `scripts/approve-plan.sh` — PLAN_GATE firing mechanism
- `scripts/dispatch-v2.sh` — Stage 3 plan executor
- `scripts/teardown-run.sh` — cancel handler
- `slm-forge-brief/` — original architectural brief (v1 era; retained for context)
