"""
text_simple plugin — covers text-like formats that reduce to plain prose:
  .txt   plain text
  .md    Markdown (stripped of formatting markers but preserved as prose)
  .rst   reStructuredText
  .org   org-mode
  .log   log files
  .html  HTML (via BeautifulSoup, stripped to visible text)
  .htm   HTML alias
  .xml   XML (treated as text; structured extraction per-schema is out of scope)
  .tex   LaTeX (stripped of commands)
  .rtf   RTF (stripped of control words)

For each file: read the full content, clean, emit one chunk_type="full" record.
Large files are handled by the orchestrator's long-chunk splitter.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Iterator

from .orchestration_helpers import clean_text


_HTML_EXTS = (".html", ".htm")
_MD_EXTS = (".md", ".markdown", ".mdx")
_TEX_EXTS = (".tex",)
_RTF_EXTS = (".rtf",)
_RAW_EXTS = (".txt", ".rst", ".org", ".log", ".xml")


def _read_html(path: Path) -> str:
    try:
        from bs4 import BeautifulSoup
    except ImportError:
        sys.stderr.write(f"  [beautifulsoup4 not installed; falling back to raw read for {path}]\n")
        return path.read_text(encoding="utf-8", errors="replace")
    html = path.read_text(encoding="utf-8", errors="replace")
    soup = BeautifulSoup(html, "html.parser")
    # Drop script/style noise
    for tag in soup(["script", "style", "noscript"]):
        tag.decompose()
    return soup.get_text(separator="\n")


def _read_md(path: Path) -> str:
    """Keep markdown as prose. Strip code fences' triple-backticks but keep content."""
    txt = path.read_text(encoding="utf-8", errors="replace")
    # Remove fenced code-block markers but keep the code (may hold valuable domain terms)
    txt = re.sub(r"^```[a-zA-Z0-9_+-]*\s*$", "", txt, flags=re.MULTILINE)
    txt = re.sub(r"^```\s*$", "", txt, flags=re.MULTILINE)
    return txt


def _read_tex(path: Path) -> str:
    txt = path.read_text(encoding="utf-8", errors="replace")
    # Remove common LaTeX commands but keep their textual args (best-effort)
    txt = re.sub(r"\\(section|subsection|chapter|paragraph|title|author)\{([^}]*)\}",
                 r"\2", txt)
    txt = re.sub(r"\\(textbf|textit|emph|underline)\{([^}]*)\}", r"\2", txt)
    # Drop bare commands without args: \alpha, \cite{...}
    txt = re.sub(r"\\[a-zA-Z]+\*?(\[[^\]]*\])?\{[^}]*\}", "", txt)
    txt = re.sub(r"\\[a-zA-Z]+\*?", "", txt)
    # Comments
    txt = re.sub(r"(?<!\\)%.*$", "", txt, flags=re.MULTILINE)
    return txt


def _read_rtf(path: Path) -> str:
    try:
        from striprtf.striprtf import rtf_to_text
        rtf = path.read_text(encoding="utf-8", errors="replace")
        return rtf_to_text(rtf)
    except ImportError:
        sys.stderr.write(f"  [striprtf not installed; raw-read fallback for {path}]\n")
        rtf = path.read_text(encoding="utf-8", errors="replace")
        # Primitive fallback: strip {\<word> ...} control words
        return re.sub(r"\\[a-z]+-?\d*\s?", "", rtf)


class _TextSimplePlugin:
    extensions = _RAW_EXTS + _MD_EXTS + _HTML_EXTS + _TEX_EXTS + _RTF_EXTS
    source_format = "text"   # overridden per-file in iter_chunks via metadata
    requires = ("beautifulsoup4", "striprtf")  # optional — plugin degrades if missing
    system_deps = ()
    default_on = True
    disable_env = "FORGE_DISABLE_TEXT"

    def iter_chunks(self, path: Path, section: str, base_id: str, options: dict) -> Iterator[dict]:
        ext = path.suffix.lower()
        try:
            if ext in _HTML_EXTS:
                text = _read_html(path); source_format = "html"
            elif ext in _MD_EXTS:
                text = _read_md(path); source_format = "md"
            elif ext in _TEX_EXTS:
                text = _read_tex(path); source_format = "tex"
            elif ext in _RTF_EXTS:
                text = _read_rtf(path); source_format = "rtf"
            else:
                text = path.read_text(encoding="utf-8", errors="replace")
                source_format = ext.lstrip(".") or "txt"
        except Exception as e:
            sys.stderr.write(f"  [{path}: {type(e).__name__}: {e}]\n")
            return
        text = clean_text(text)
        if not text:
            return
        yield {
            "id": f"{base_id}-full",
            "text": text,
            "format": "pretrain",
            "metadata": {
                "source_file": str(path),
                "source_format": source_format,
                "section": section,
                "doc_title": path.stem,
                "chunk_type": "full",
                "chunk_idx": 0,
                "char_count": len(text),
            },
        }


PLUGIN = _TextSimplePlugin()
