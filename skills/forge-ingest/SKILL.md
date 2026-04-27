---
name: forge-ingest
description: Multi-source fan-out skill. Reads a config.yaml that combines N sources of 10 different kinds (local_dir, archive, http, jsonl, hf_dataset, database, git, s3, gcs, azure) and produces ONE merged prepped.jsonl ready for forge-audit. Each source is dispatched to the appropriate handler (forge-prep for files, forge-ingest-db for databases, cloud SDKs for object stores, git for repo clones). Cross-source deduplication catches the same passage appearing in multiple inputs. Within-source deduplication always runs. Supports --dry-run for cost/size preview before committing to a long-running ingest.
---

# forge-ingest

## When this fires

**Phase position: INGEST** — first phase fired when the input is a
`multi-source-config.yaml` (detected by forge-analyze). Replaces the
single-input `prep` phase for multi-source runs.

After INGEST, the standard pipeline continues from AUDIT:
```
INGEST → AUDIT → SYNTH → SHAPE → PLAN_FIT → ... (unchanged)
```

## Config format

```yaml
version: 1
run_name: dental-pubmed-jan2026     # optional
domain: dental.ai.research           # optional override
budget_usd: 75                       # optional override

sources:
  - name: local-papers
    kind: local_dir
    path: ./Publications/
    enable_plugins: [archive, ocr]   # opt-in heavy tiers per-source

  - name: papers-archive
    kind: archive
    path: ./papers-2024.tar.gz

  - name: pubmed-snapshot
    kind: http
    url: https://example.org/pubmed-dental.jsonl
    sha256: abc...                   # optional verification

  - name: pubmed-live
    kind: database
    config: ./db-sources.yaml        # delegates to forge-ingest-db

  - name: prior-run
    kind: jsonl
    path: ./prior-runs/2025-12.jsonl

  - name: hf-corpus
    kind: hf_dataset
    repo: nlpaueb/dental-qa
    split: train
    text_field: question

options:
  dedup_across_sources: true          # default true
  min_len: 200
  max_len: 100000
```

## Source `kind:` handlers

| kind | Handler | Auth / config | Added |
|---|---|---|---|
| `local_dir`  | `prep-orchestrator` (full plugin family)              | filesystem path                                     | v2.2 |
| `archive`    | `prep_plugins/archive.py` (zip-slip safe)             | filesystem path; nested ≤ depth 3                   | v2.2 |
| `http`       | `urllib` + sha256 verify; 3-attempt retry + `mirrors` | url + optional sha256                                | v2.2 |
| `jsonl`      | pass-through copy (already canonical)                  | filesystem path                                      | v2.2 |
| `hf_dataset` | `huggingface_hub` (gated/private auth pre-check)      | `HF_TOKEN` env or `token:` in source                | v2.2 |
| `database`   | delegates to `forge-ingest-db/run.sh`                 | sub-config path (10 adapter kinds inside)           | v2.2 |
| `git`        | `git clone --depth N --branch REF`; full-clone fallback for SHAs; include/exclude globs | url + optional `auth_token_ref` for private repos | **v2.3** |
| `s3`         | `boto3`; bucket+prefix or single key; `endpoint_url` for MinIO | `access_key_id_ref` + `secret_access_key_ref` (+ optional session_token) | **v2.3** |
| `gcs`        | `google-cloud-storage`; bucket+prefix or single object         | `credentials_json_path` or `credentials_json_ref` | **v2.3** |
| `azure`      | `azure-storage-blob`; container+prefix or single blob          | `sas_token_ref` / `account_key_ref` / `connection_string_ref` | **v2.3** |

All cloud sources support optional `include:` / `exclude:` glob filters
applied after the listing call.

## Output

`slm-forge/.runs/<run-id>/prepped.jsonl` — same canonical schema as
single-source forge-prep. Each chunk's `metadata.source_file` carries the
source name as prefix (`<source-name>:<original-path>`) so provenance
survives the merge.

`slm-forge/.runs/<run-id>/ingest-stats.json` — per-source breakdown +
cross-source dedup count.

## Cross-source dedup

When `options.dedup_across_sources: true` (default), a single SHA-256
set is maintained across all sources. So if the same paragraph appears in:
- a PDF in `local_dir`
- the same paragraph cached in a DB row from `database`

…only the first occurrence wins. **Source order matters** — the source
listed FIRST in `sources:` is the canonical winner; later sources lose
their duplicates. Stats record which source each dup was attributed to.

Within-source dedup ALWAYS runs (catches symlink loops + duplicated
files inside a single source) regardless of the `dedup_across_sources`
setting. The hash key is `text` for pretrain chunks and
`role:content\nrole:content...` for chat chunks (role differences DO
matter — same prompt with different system priming does not collapse).

## Dry-run

```bash
bash slm-forge/skills/forge-ingest/run.sh <run-id> --dry-run
```

Parses the config, validates handler dispatch for every source, sizes
locally-resolvable inputs, and prints a structured plan as JSON. NO
downloads, NO writes, NO `prepped.jsonl` produced. Use this to preview
"would this S3 prefix be 10 GB or 100 GB?" or "is the HF token I set
actually valid for this gated dataset?" before committing to a long run.

Returns rc=0 on a clean plan, non-zero if any handler dispatch failed.

## Disk-space pre-check

Before fan-out begins, the skill sums the bytes of all `local_dir` and
`jsonl` sources and refuses (rc=4) if free disk at `$RUN_DIR` is less
than 1.5x that estimate. Cloud / HF / DB sources are not pre-sized
(can't be cheaply); operators should `--dry-run` first if unsure.

## Re-run safety

If `prepped.jsonl` already exists in the run dir and is non-empty, the
skill refuses to clobber it (rc=3). Override with
`FORGE_INGEST_FORCE=1` or use a fresh run-id.

## Failure policy

Per source: failures (HTTP 404, DB unreachable, archive corrupt) are
logged but do not abort the overall run. Other sources continue. The
final `ingest-stats.json` carries `failures: [{source, error, ...}]`.

If ALL sources fail OR the merged JSONL is empty, the skill exits 1 and
the dispatcher tears down.
