"""
Jupyter notebook plugin — concat code + markdown cells.

Each notebook becomes one chunk (chunk_type="notebook"). Code cells are
preserved as-is (they often contain the valuable domain terms). Output
cells are dropped (they're runtime state, not corpus content).
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Iterator

from .orchestration_helpers import clean_text


class _NotebookPlugin:
    extensions = (".ipynb",)
    source_format = "notebook"
    requires = ("nbformat",)
    system_deps = ()
    default_on = True
    disable_env = "FORGE_DISABLE_NOTEBOOK"

    def iter_chunks(self, path: Path, section: str, base_id: str, options: dict) -> Iterator[dict]:
        try:
            import nbformat
        except ImportError:
            # Fallback — raw JSON parse. Notebooks are JSON so we can still try.
            import json
            try:
                with open(path) as f:
                    nb = json.load(f)
                cells = nb.get("cells", [])
                pieces = []
                for cell in cells:
                    src = cell.get("source", "")
                    if isinstance(src, list):
                        src = "".join(src)
                    if cell.get("cell_type") == "code":
                        pieces.append(f"```python\n{src}\n```")
                    else:
                        pieces.append(src)
                text = clean_text("\n\n".join(p for p in pieces if p.strip()))
            except Exception as e:
                sys.stderr.write(f"  [{path}: {type(e).__name__}]\n")
                return
        else:
            try:
                nb = nbformat.read(str(path), as_version=4)
            except Exception as e:
                sys.stderr.write(f"  [{path}: {type(e).__name__}: {e}]\n")
                return
            pieces = []
            for cell in nb.cells:
                if cell.cell_type == "code":
                    pieces.append(f"```python\n{cell.source}\n```")
                elif cell.cell_type in ("markdown", "raw"):
                    pieces.append(cell.source)
            text = clean_text("\n\n".join(p for p in pieces if p.strip()))

        if not text:
            return
        yield {
            "id": f"{base_id}-nb",
            "text": text,
            "format": "pretrain",
            "metadata": {
                "source_file": str(path),
                "source_format": "notebook",
                "section": section,
                "doc_title": path.stem,
                "chunk_type": "notebook",
                "chunk_idx": 0,
                "char_count": len(text),
            },
        }


PLUGIN = _NotebookPlugin()
