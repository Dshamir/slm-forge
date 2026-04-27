"""
EPUB plugin — per-chapter text extraction via ebooklib + BeautifulSoup.

Each EPUB chapter becomes one chunk (chunk_type="chapter").
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Iterator

from .orchestration_helpers import clean_text


class _EpubPlugin:
    extensions = (".epub",)
    source_format = "epub"
    requires = ("ebooklib", "beautifulsoup4")
    system_deps = ()
    default_on = True
    disable_env = "FORGE_DISABLE_EPUB"

    def iter_chunks(self, path: Path, section: str, base_id: str, options: dict) -> Iterator[dict]:
        try:
            import ebooklib
            from ebooklib import epub
            from bs4 import BeautifulSoup
        except ImportError:
            sys.stderr.write(f"  [ebooklib/bs4 not installed; skip {path}]\n")
            return
        try:
            book = epub.read_epub(str(path))
        except Exception as e:
            sys.stderr.write(f"  [{path}: {type(e).__name__}: {e}]\n")
            return
        i = 0
        for item in book.get_items():
            if item.get_type() != ebooklib.ITEM_DOCUMENT:
                continue
            try:
                soup = BeautifulSoup(item.get_body_content(), "html.parser")
                text = soup.get_text(separator="\n")
            except Exception:
                continue
            text = clean_text(text)
            if not text:
                continue
            yield {
                "id": f"{base_id}-ch{i:03d}",
                "text": text,
                "format": "pretrain",
                "metadata": {
                    "source_file": str(path),
                    "source_format": "epub",
                    "section": section,
                    "doc_title": path.stem,
                    "chunk_type": "chapter",
                    "chunk_idx": i,
                    "char_count": len(text),
                },
            }
            i += 1


PLUGIN = _EpubPlugin()
