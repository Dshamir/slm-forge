"""
prep_plugins/base.py — plugin ABC for slm-forge's multi-format extractor.

Every plugin declares which file extensions it handles and yields chunks in
the canonical schema. The orchestrator auto-discovers plugins via
prep_plugins/__init__.py and builds a DISPATCH dict keyed by extension.

Canonical chunk schema (v1, preserved from prep-publications.py):
  {
    "id": "<source-stem>-<chunk-suffix>",
    "text": "<extracted text>",
    "format": "pretrain",
    "metadata": {
      "source_file": "relative/path.ext",
      "source_format": "pdf|docx|pptx|txt|html|md|...",
      "section": "<top-level dir name>",
      "doc_title": "<filename stem>",
      "chunk_type": "page|slide|paragraph|full|cell|row|ocr|transcript|metadata_only",
      "chunk_idx": <int 0-based>,
      "char_count": <int>
    }
  }

Plugins that produce sparse "metadata-only" output (mesh, binary) should
set chunk_type="metadata_only" so forge-audit can filter them if desired.
"""
from __future__ import annotations

from pathlib import Path
from typing import Iterator, Protocol, Tuple


class Plugin(Protocol):
    """Plugin protocol. Each plugin module defines a PLUGIN instance with:

      extensions:    file extensions this plugin handles (lowercased, with dot)
      source_format: value for metadata.source_format
      requires:      pip deps (warn if missing)
      system_deps:   apt deps (e.g. 'tesseract-ocr', 'ffmpeg')
      default_on:    whether the plugin runs by default when its extensions
                     are present in the corpus. Heavy plugins (OCR, whisper)
                     are default_on=True but can be disabled by env var.
      disable_env:   env var that disables this plugin if set to "1"
    """

    extensions: Tuple[str, ...]
    source_format: str
    requires: Tuple[str, ...]
    system_deps: Tuple[str, ...]
    default_on: bool
    disable_env: str

    def iter_chunks(
        self, path: Path, section: str, base_id: str, options: dict
    ) -> Iterator[dict]:
        """Yield chunks in the canonical schema for one file on disk."""
        ...
