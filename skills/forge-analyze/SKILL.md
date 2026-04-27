---
name: forge-analyze
description: Walks the user-supplied target (a directory, single JSONL, or a multi-source config.yaml) and produces a structured inventory + format detection + extraction profile + domain signal. The output drives forge-plan's phase-sequence derivation. Recognizes ~138 extensions across 19 plugins; detects multi-source config.yaml when both a top-level `sources:` key AND a recognized `kind:` value are present. Hard-fails on mixed pretrain+chat JSONL in one directory (exit 65) since shape + synth assume one schema.
---

# forge-analyze

## When this fires

**Phase position: ANALYZE (-1)** — after PREFLIGHT, before PLAN.

## What it does

1. **Multi-source config detection** (v2.2): if target is a `.yaml` file
   with both `^sources:` AND `^[[:space:]]+kind:[[:space:]]+(local_dir|
   archive|http|jsonl|hf_dataset|database|git|s3|gcs|azure)`, classify
   as `multi-source-config`, copy to `$RUN_DIR/config.yaml`, set
   `needs[0]=ingest` and `skip_phases=[prep]`. Done — no inventory walk.
2. Walk the target dir (recursive, capped at maxdepth=8)
3. Classify files by extension; recognized extensions count toward
   `extraction_profile.plugins_needed` (drives the tiered installer)
4. For each JSONL, peek the first record to detect format
   (pretrain / chat). If MULTIPLE jsonl files exist with conflicting
   formats, exit 65 with a clear "split or pre-merge" message.
5. Sample 3 short documents → ask Claude Haiku for a one-line domain label
6. Emit `analysis.json`

## Output schema

```json
{
  "target_dir": "/path/to/input",
  "input_inventory": {
    "by_ext": {"pdf": 47, "docx": 12, "pptx": 3, "txt": 8, "jsonl": 1, "md": 4},
    "total_files": 75,
    "total_size_mb": 234,
    "estimated_raw_tokens": 1840000
  },
  "detected_format": "raw-documents" | "pretrain-jsonl" | "chat-jsonl" | "mixed" | "multi-source-config",
  "format_evidence": {...},
  "domain_signal": {
    "label": "dental.ai.research",
    "confidence": 0.85,
    "via": "claude-haiku-classifier",
    "samples_used": 3
  },
  "needs": ["prep","audit","synth","shape","train","eval","quantize","register","publish","report"],
  "skip_phases": []
}
```

## Output → needs derivation

| Detected format | needs | skip_phases |
|---|---|---|
| `raw-documents` | prep + audit + synth + shape + ... | [] |
| `pretrain-jsonl` | (skip prep) + audit + synth + shape + ... | [prep] |
| `chat-jsonl` | (skip prep + audit + synth) + shape + ... | [prep, audit, synth] |
| `mixed` | prep + audit + synth + shape + ... | [] |
| `multi-source-config` (v2.2+) | **ingest** + audit + synth + shape + ... | [prep] |

## Hard-fail conditions (exit codes)

| Code | Reason | Fix |
|---|---|---|
| 64 | missing target arg | pass a path |
| 65 | mixed pretrain + chat JSONL files in same target dir | split into separate runs OR pre-merge to one schema |

## Inputs
- `$1` = target dir (required)
- `$2` = optional explicit domain label

## Outputs
- `slm-forge/.runs/<runtime-id>/analysis.json`
- Stdout: same JSON (machine-readable for piping to forge-plan)

## Usage
```bash
bash slm-forge/skills/forge-analyze/run.sh /path/to/dir [domain-override]
```
