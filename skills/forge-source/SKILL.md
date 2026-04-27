---
name: forge-source
description: Ingests the raw corpus from manifest.spec.corpus_ref into the forge's S3 raw/ prefix. v1 implementation supports local: paths only; s3:/hf:/http: schemes are stubbed (exit 78) — use multi-source config.yaml + forge-ingest for those instead. Writes a per-shard manifest. Hard-caps at 500 GB per D-006.
---

# forge-source

## When this fires

**Phase position: SOURCE** — first data phase in the legacy v1 flow,
between `forge-intake` and `forge-curate`. v2 runs use `forge-prep` or
`forge-ingest` instead.

## What it does

1. Read `manifest.spec.corpus_ref` and detect scheme (local: / s3: / hf: / http:)
2. For `local:`, walk the path, copy to `s3://FORGE_BUCKET/forge/<id>/data/raw/`
3. Write `data/raw/_raw-corpus-manifest.json` listing every shard + its bytes
4. Hard-fail if total bytes > 500 GB (D-006 S3 layout cap)
5. Set `manifest.artifacts.raw_corpus_s3` and advance to `CURATE`

## Inputs
- `$1` = forge-id
- `manifest.spec.corpus_ref` (currently `local:/abs/path` only)
- `FORGE_BUCKET` env or default

## Outputs
- `s3://FORGE_BUCKET/forge/<id>/data/raw/<shards>`
- `s3://.../data/raw/_raw-corpus-manifest.json` (sizes + sha256 of each shard)
- `manifest.artifacts.raw_corpus_s3`
- `manifest.state.current_phase = CURATE`

## Idempotency
If `manifest.artifacts.raw_corpus_s3` is set, exits 0.

## Failure modes

| Exit | Reason |
|---|---|
| 0  | corpus uploaded or already-set |
| 1  | local path missing OR corpus > 500 GB cap |
| 64 | no forge-id provided |
| 78 | scheme is `s3:` / `hf:` / `http:` (not yet implemented in v1; use multi-source `config.yaml`) |

## External resources
- AWS S3 (writes raw shards)
- Local filesystem (reads `local:` source)

## Cost class
**free** — local I/O + S3 PUTs (negligible at the M2 size class).

## Depends on
`forge-intake` (populated `corpus_ref` in spec)

## See also
For non-local sources (HF dataset, S3 prefix, GCS, Azure, git, archive,
HTTP), prefer the v2.2+ multi-source path: write a `config.yaml` and
invoke via `/slm-forge ./config.yaml <budget>`. That route uses
`forge-ingest` which has all 10 source kinds wired.
