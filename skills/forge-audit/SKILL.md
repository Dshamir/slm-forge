---
name: forge-audit
description: Pre-training corpus contamination audit — runs as the P-1 phase before SOURCE. Hard-fails the forge if the corpus contains LLM-generated content, near-duplicate paragraphs, OCR/scrape artifacts, safety boilerplate, off-domain content, or insufficient clean tokens.
---

# forge-audit

Permanent input-QC gate added to the SLM-Forge phase machine after the
2026-04-23 incident where forge-2026-04-23-publications-9j5m8d trained on a
corpus containing 35% off-topic 3D-mesh papers + LLM marketing slop, producing
a model that hallucinated "TrieBERT" / "DeepDentist" Chinese-translation
artifacts and looped paragraphs of marketing copy.

## When this fires

Phase position: **AUDIT (P-1)** — runs immediately after CURATE, before
SOURCE. If it fails, the forge aborts before any GPU spend.

## What it checks

Six independent detectors, ALL must pass for the gate to clear:

| # | Detector | Fail if |
|---|---|---|
| 1 | Speaker-label patterns | ≥ 5% of chunks contain `^(A\|B\|Q\|Host\|Guest):` markers |
| 2 | LLM marketing slop | ≥ 5% of chunks contain ≥2 slop phrases ("revolutionize", "exciting journey", etc.) |
| 3 | Triple-word OCR artifacts | Healed in-place (collapse to single occurrence); chunk kept |
| 4 | Safety/disclaimer boilerplate | Any chunk containing "I am not qualified", "please consult", etc. is dropped |
| 5 | Domain density | Each chunk requires ≥ 0.8% domain keyword density AND ≥ 2 distinct domain categories AND ≥ 5 absolute hits |
| 6 | Near-duplicate clusters | MinHash LSH at threshold 0.85 — duplicates dropped, first occurrence kept |

After all six detectors:
- Token count of cleaned corpus must be ≥ `FORGE_AUDIT_MIN_TOKENS` (default 500_000)
- Below that → hard fail with kill condition tripped

## Inputs (manifest)
- `manifest.spec.domain` (string) — selects the keyword category set (`dental`, `medical`, `legal`, `financial`, ...)
- `manifest.artifacts.curated_corpus_s3` (S3 URI) — output of forge-curate

## Outputs (manifest)
- Writes audit report to `s3://.../audit/audit-report.json`
- Writes cleaned corpus to `s3://.../data/audited/`
- Sets `manifest.artifacts.audited_corpus_s3`
- Advances `manifest.phase` to SHAPE

## Failure modes

| Failure | Recoverable? | Recovery hint |
|---|---|---|
| `kill_condition_tripped` (clean tokens < threshold) | NO | Corpus is too contaminated or too small for fine-tuning. Switch to RAG or expand the source corpus. |
| `domain_keyword_set_missing` | YES | Add a keyword category set for `domain={spec.domain}` in the audit script |
| `safety_boilerplate_excessive` (>20% of chunks) | NO | Source corpus contains too much LLM-generated content; clean upstream |

## Override env vars
- `FORGE_AUDIT_MIN_TOKENS` (default `500000`)
- `FORGE_AUDIT_MIN_DENSITY` (default `0.008`)
- `FORGE_AUDIT_MIN_CATEGORIES` (default `2`)
- `FORGE_AUDIT_MIN_ABSOLUTE` (default `5`)

## Usage
```bash
bash slm-forge/skills/forge-audit/run.sh <forge-id>
```
