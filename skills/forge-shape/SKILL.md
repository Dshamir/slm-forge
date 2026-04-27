---
name: forge-shape
description: Converts the curated corpus to the unified {id, domain, format, messages[], raw_text, metadata} schema, shuffles, splits 90/5/5 (train/val/test), computes coarse token stats. Prefers local v2 run-dir inputs (qa-filtered.jsonl / audited/cleaned.jsonl) over the legacy S3 data/curated/ path. Output is what forge-train consumes.
---

# forge-shape

## When this fires

**Phase position: SHAPE** — after `forge-curate` (v1) or `forge-synth` (v2),
before `forge-plan-fit` and `forge-provision`. Always runs locally; no GPU.

## What it does

1. Locate input. Cascade through local v2 candidates first:
   `qa-filtered.jsonl` → `qa.jsonl` → `audited/cleaned.jsonl` → `prepped.jsonl`.
   Falls back to `s3 sync data/curated/` if no local input.
2. Read each record, normalize to the unified schema:
   `{id, domain, format: "chat" | "pretrain", messages[], raw_text, metadata}`
3. Shuffle deterministically (seed = forge_id) for reproducibility
4. Split 90 / 5 / 5 → train / val / test
5. Compute approx token counts (chars ÷ 4) into `tokenizer-stats.json`
6. Upload `data/shaped/{train,val,test}.jsonl` to S3
7. Set `manifest.artifacts.shaped_corpus_s3` and advance to `PROVISION`

## Inputs
- `$1` = forge-id (or `v2-<run-id>` — prefix stripped to find local run dir)
- Local: any of `$RUN_DIR/{qa-filtered, qa, audited/cleaned, prepped}.jsonl`
- S3 fallback: `s3://.../data/curated/`
- `manifest.plan.{chat_template, base_model}` (template choice)

## Outputs
- `s3://.../data/shaped/{train,val,test}.jsonl`
- `s3://.../metadata/tokenizer-stats.json`
- `manifest.artifacts.shaped_corpus_s3`
- `manifest.state.current_phase = PROVISION`

## Idempotency
If `manifest.artifacts.shaped_corpus_s3` is set, exits 0.

## Failure modes

| Exit | Reason |
|---|---|
| 0  | shaped or already-set |
| 1  | zero docs found (no local input AND no S3 curated corpus) |
| 64 | no forge-id provided |

## External resources
- Local disk (v2 run dir — preferred)
- AWS S3 (read curated fallback, write shaped + stats)

## Cost class
**free** — local CPU + S3 PUTs.

## Depends on
- v1: `forge-curate` (curated corpus in S3)
- v2: `forge-synth` (qa-filtered.jsonl in run dir) OR `forge-audit` (audited/cleaned.jsonl) OR `forge-prep` (prepped.jsonl)
