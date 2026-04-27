"""
Code file plugin — handles 30+ language file extensions.

For v2.1: whole-file ingest with chunk_type="code_file". Real semantic
chunking (tree-sitter-backed per-function/class) is v3 work.

For files larger than MAX_LEN, the orchestrator's long-chunk splitter kicks
in on paragraph breaks — which for code means blank lines (usually between
functions). Good enough for v2.1.
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Iterator

from .orchestration_helpers import clean_text


# Language mapping — extension → canonical language label (recorded in metadata).
LANG_MAP = {
    ".py": "python", ".pyw": "python",
    ".js": "javascript", ".mjs": "javascript", ".cjs": "javascript",
    ".ts": "typescript", ".tsx": "typescript", ".jsx": "javascript",
    ".java": "java", ".kt": "kotlin", ".kts": "kotlin",
    ".scala": "scala", ".sc": "scala",
    ".cpp": "cpp", ".cc": "cpp", ".cxx": "cpp", ".hpp": "cpp", ".hh": "cpp", ".hxx": "cpp",
    ".c": "c", ".h": "c",
    ".go": "go",
    ".rs": "rust",
    ".rb": "ruby", ".rake": "ruby",
    ".php": "php",
    ".cs": "csharp",
    ".swift": "swift",
    ".sh": "bash", ".bash": "bash", ".zsh": "bash",
    ".sql": "sql",
    ".yaml": "yaml", ".yml": "yaml",
    ".toml": "toml",
    ".ini": "ini", ".cfg": "ini",
    ".r": "r",
    ".jl": "julia",
    ".lua": "lua",
    ".pl": "perl", ".pm": "perl",
    ".ex": "elixir", ".exs": "elixir",
    ".erl": "erlang", ".hrl": "erlang",
    ".hs": "haskell",
    ".clj": "clojure", ".cljs": "clojure",
    ".dart": "dart",
    ".groovy": "groovy",
    ".m": "objective-c",
}


class _CodePlugin:
    extensions = tuple(LANG_MAP.keys())
    source_format = "code"
    requires = ()
    system_deps = ()
    default_on = True
    disable_env = "FORGE_DISABLE_CODE"

    def iter_chunks(self, path: Path, section: str, base_id: str, options: dict) -> Iterator[dict]:
        ext = path.suffix.lower()
        lang = LANG_MAP.get(ext, "text")
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except Exception as e:
            sys.stderr.write(f"  [{path}: {type(e).__name__}]\n")
            return
        # Don't clean_text on code — collapsing whitespace breaks indentation.
        # Only strip trailing whitespace on each line + normalize line endings.
        text = "\n".join(line.rstrip() for line in text.splitlines()).strip()
        if not text:
            return
        yield {
            "id": f"{base_id}-code",
            "text": text,
            "format": "pretrain",
            "metadata": {
                "source_file": str(path),
                "source_format": "code",
                "section": section,
                "doc_title": path.stem,
                "chunk_type": "code_file",
                "chunk_idx": 0,
                "char_count": len(text),
                "language": lang,
            },
        }


PLUGIN = _CodePlugin()
