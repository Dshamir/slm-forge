"""
PDF plugin — per-page text extraction via pdfplumber.

Preserves behavior from prep-publications.py::emit_chunks_pdf exactly so
the v2.1 refactor is byte-for-byte compatible with v1 output.
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Iterator

from .orchestration_helpers import clean_text


class _PdfPlugin:
    extensions = (".pdf",)
    source_format = "pdf"
    requires = ("pdfplumber",)
    system_deps = ()
    default_on = True
    disable_env = "FORGE_DISABLE_PDF"

    def iter_chunks(self, path: Path, section: str, base_id: str, options: dict) -> Iterator[dict]:
        try:
            import pdfplumber
        except ImportError:
            sys.stderr.write(f"  [pdfplumber not installed; skip {path}]\n")
            return
        try:
            with pdfplumber.open(str(path)) as pdf:
                for i, page in enumerate(pdf.pages):
                    try:
                        text = page.extract_text() or ""
                    except Exception as e:
                        sys.stderr.write(f"  [{path} p{i}: {type(e).__name__}]\n")
                        continue
                    text = clean_text(text)
                    if not text:
                        continue
                    yield {
                        "id": f"{base_id}-p{i:03d}",
                        "text": text,
                        "format": "pretrain",
                        "metadata": {
                            "source_file": str(path),
                            "source_format": "pdf",
                            "section": section,
                            "doc_title": path.stem,
                            "chunk_type": "page",
                            "chunk_idx": i,
                            "char_count": len(text),
                        },
                    }
        except Exception as e:
            sys.stderr.write(f"  [{path}: {type(e).__name__}: {e}]\n")


PLUGIN = _PdfPlugin()
