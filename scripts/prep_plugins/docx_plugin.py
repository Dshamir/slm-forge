"""
DOCX plugin — ~20-paragraph chunks via python-docx.

Preserves behavior from prep-publications.py::emit_chunks_docx exactly.
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Iterator

from .orchestration_helpers import clean_text


class _DocxPlugin:
    extensions = (".docx",)
    source_format = "docx"
    requires = ("python-docx",)
    system_deps = ()
    default_on = True
    disable_env = "FORGE_DISABLE_DOCX"

    def iter_chunks(self, path: Path, section: str, base_id: str, options: dict) -> Iterator[dict]:
        try:
            from docx import Document
        except ImportError:
            sys.stderr.write(f"  [python-docx not installed; skip {path}]\n")
            return
        try:
            doc = Document(str(path))
        except Exception as e:
            sys.stderr.write(f"  [{path}: {type(e).__name__}: {e}]\n")
            return
        paragraphs = [p.text for p in doc.paragraphs if p.text and p.text.strip()]
        chunk_size = 20
        for i in range(0, len(paragraphs), chunk_size):
            text = "\n\n".join(paragraphs[i:i + chunk_size])
            text = clean_text(text)
            if not text:
                continue
            yield {
                "id": f"{base_id}-c{i//chunk_size:03d}",
                "text": text,
                "format": "pretrain",
                "metadata": {
                    "source_file": str(path),
                    "source_format": "docx",
                    "section": section,
                    "doc_title": path.stem,
                    "chunk_type": "paragraph",
                    "chunk_idx": i // chunk_size,
                    "char_count": len(text),
                },
            }


PLUGIN = _DocxPlugin()
