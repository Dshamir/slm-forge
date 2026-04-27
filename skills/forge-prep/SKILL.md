---
name: forge-prep
description: Walks a directory of mixed documents and emits a unified canonical JSONL. Plugin-driven (v2.1) — handles ~30 file formats including documents, code, notebooks, tabular data, archives, images (OCR), audio/video (transcription), 3D meshes, and orphaned MySQL data dirs (v2.2 auto-revive). Runs as the first DATA-PHASE in the pipeline (after PREFLIGHT/ANALYZE/PLAN, before AUDIT). Skipped when input is already JSONL.
---

# forge-prep

## When this fires

**Phase position: PREP** — first data-phase. Skipped when input is already
JSONL or a multi-source config.yaml (the latter routes to `forge-ingest`
instead).

## What it does

Dispatches each file in `target_dir` to a plugin in
`scripts/prep_plugins/` based on the file extension. Plugins are
auto-discovered from the registry in `prep_plugins/__init__.py` and emit
chunks in the canonical schema (see `prep_plugins/base.py`).

### Plugin family (v2.1 + v2.2)

| Plugin | Source format | Extensions | Default | Disable env |
|---|---|---|---|---|
| `pdf` | pdf | .pdf | on | – |
| `docx_plugin` | docx | .docx | on | – |
| `pptx_plugin` | pptx | .pptx | on | – |
| `text_simple` | txt/md/html/... | .txt .md .markdown .mdx .rtf .html .htm .xml .tex .rst .org .log | on | – |
| `epub` | epub | .epub | on | – |
| `notebook` | ipynb | .ipynb | on | – |
| `code` | code-* | 30+ language extensions | on | – |
| `tabular` | csv/xlsx/parquet | .csv .tsv .xlsx .ods .parquet .pq | on | – |
| `archive` | archive | .zip .tar .gz .tgz .bz2 .tbz2 .7z .rar (recursive, depth ≤ 3) | on | – |
| `mesh_metadata` | mesh | .stl .vtp .obj .ply (sparse, metadata-only) | on | `FORGE_DISABLE_MESH_METADATA=1` |
| `binary_metadata` | binary | .bin .so .dll .exe .o .a .class .jar .db ... (sparse) | on | `FORGE_DISABLE_BINARY_METADATA=1` |
| `ocr` | image (OCR) | .png .jpg .jpeg .tif .tiff .bmp .gif .webp .heic .heif | on | `FORGE_DISABLE_OCR=1` |
| `audio` | audio (transcription) | .mp3 .wav .m4a .flac .ogg .opus .aac | on | `FORGE_DISABLE_TRANSCRIBE=1` |
| `video` | video (transcription) | .mp4 .mkv .mov .avi .webm .wmv .flv | on | `FORGE_DISABLE_TRANSCRIBE=1` |
| **`mysql_revive`** (v2.2) | mysql_revive | .frm .myi .myd .ibd .ibdata (auto-revive via `docker run mysql:8`) | on (needs docker) | `FORGE_DISABLE_MYSQL_REVIVE=1` |

Heavy plugins (`ocr`, `audio`, `video`) install their system deps lazily
when their extensions appear in the corpus. The orchestrator does a
dry-walk first to compute `extraction_profile.plugins_needed` so
`forge-prep/run.sh` only materializes the install tier you actually need.

### Canonical chunk schema

Every plugin emits chunks in this shape (validated by
`prep_plugins/schema.py` before write):

```json
{
  "id": "<source-stem>-<chunk-suffix>",
  "text": "...",
  "format": "pretrain",
  "metadata": {
    "source_file": "...",
    "source_format": "pdf|docx|...|mysql_revive|...",
    "section": "<top-level-dir>",
    "doc_title": "...",
    "chunk_type": "page|slide|paragraph|full|cell|row|ocr|transcript|metadata_only",
    "chunk_idx": 0,
    "char_count": 1479
  }
}
```

Sparse "metadata-only" chunks (mesh, binary, fallback paths) set
`chunk_type: "metadata_only"` so `forge-audit` can filter them out if
the operator wants to keep the training corpus dense.

## Inputs
- `target_dir` (from analysis.json)
- `run_id`

## Outputs
- `slm-forge/.runs/<run_id>/prepped.jsonl`
- `slm-forge/.runs/<run_id>/prep-stats.json` (per-plugin chunk counts)

## Idempotent — if `prepped.jsonl` exists, skip and emit existing.
