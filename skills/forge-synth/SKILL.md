---
name: forge-synth
description: Generates Q/A pairs from cleaned passages via Claude Haiku. Converts a pretrain corpus (raw text chunks) into proper SFT chat-format training data (3 Q/A pairs per passage — factual + mechanism + clinical). Critical phase — without this, lora-sft regimes degenerate into raw-text continuation pretending to be SFT.
---

# forge-synth

## When this fires

**Phase position: SYNTH** — after AUDIT, before SHAPE.
**Skipped** when input is already chat-jsonl format.

## What it does

1. Reads the audited pretrain corpus from `data/audited/cleaned.jsonl` (or `prepped.jsonl` if no audit phase ran)
2. For each passage, calls Claude Haiku to generate exactly 3 Q/A pairs:
   - factual recall
   - mechanism / "why does this work"
   - clinical / practical
3. Strict grounding (answers must come from passage)
4. Filter rule-based junk (short answers, "according to the passage" framing, generic AI questions)
5. Emit chat-format JSONL: `{id, format:"chat", messages:[{role:user,content:Q},{role:assistant,content:A}], metadata}`

## Inputs
- `run_id`
- Reads `audited/cleaned.jsonl` or `prepped.jsonl` from run dir or S3
- `ANTHROPIC_API_KEY` (from /tmp/forge-creds.env)

## Outputs
- `slm-forge/.runs/<run_id>/qa.jsonl` — raw synthesis output (one record per Q/A pair)
- `slm-forge/.runs/<run_id>/qa-filtered.jsonl` — after rule-based filter
- `slm-forge/.runs/<run_id>/synth-stats.json` — token usage + cost
- Updates manifest: `artifacts.synth_corpus_s3`

## Concurrency

12 parallel requests via asyncio.Semaphore. ~50 sec per 100 passages.

## Cost

Haiku 4.5 at $1/M input + $5/M output. Average ~$0.0026 per passage.
1500 passages → ~$4.

## Idempotent

If `qa.jsonl` exists, resumes from where it left off (uses `passage_id` as the dedup key).
