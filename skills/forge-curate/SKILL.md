---
name: forge-curate
description: Filters the raw corpus by length and dedups, normalizes to the unified {id, text, metadata} schema, writes per-shard curated JSONL to S3. Runs LOCALLY (not on EC2) — pure CPU work that doesn't justify GPU spend. Replaced by forge-audit on v2 runs (audit also covers slop / off-domain / safety).
---

# forge-curate

## When this fires

**Phase position: CURATE** — after `forge-source`, before `forge-shape`.
v1-only phase; v2 runs use `forge-audit` which adds slop detection,
off-domain filtering, and safety boilerplate scrubbing on top of the
v1 length+dedup baseline.

## What it does

1. Stream-read every shard from `s3://.../data/raw/`
2. Apply length filters (drops too-short and too-long) and SHA-based dedup
3. Normalize each surviving doc to `{id, text, metadata}`
4. Write curated shards to `s3://.../data/curated/shard-NNNN.jsonl`
5. Write a curation stats file (input/output counts, rejection histogram)
6. Set `manifest.artifacts.curated_corpus_s3` and advance to `SHAPE`

## Inputs
- `$1` = forge-id
- `s3://FORGE_BUCKET/forge/<id>/data/raw/*` (shards from `forge-source`)
- `manifest.spec.domain` (only used for the metadata tag, not filtering in M2)

## Outputs
- `s3://.../data/curated/shard-NNNN.jsonl` (each ≤ 100k docs)
- `s3://.../metadata/curation-stats.json`
- `manifest.artifacts.curated_corpus_s3`
- `manifest.state.current_phase = SHAPE`

## Idempotency
If `manifest.artifacts.curated_corpus_s3` is set, exits 0.

## Failure modes

| Exit | Reason |
|---|---|
| 0  | curated or already-set |
| 1  | zero docs survive filtering (corpus is junk) |
| 64 | no forge-id provided |

A non-fatal warning is emitted when output / input < 10% (severe loss).

## External resources
- AWS S3 (read raw, write curated, write stats)

## Cost class
**free** — runs on the operator's laptop; no GPU spend.

## Depends on
`forge-source` (raw corpus already in S3)
