#!/usr/bin/env python3
"""
slm-forge/scripts/prep-orchestrator.py

Walks a raw corpus directory, dispatches each file to the matching plugin
from prep_plugins/, emits a unified JSONL ready for the audit/synth/shape
pipeline.

This script is the v2.1 replacement for prep-publications.py. Behavior is
byte-for-byte compatible with v1 on PDF/DOCX/PPTX/TXT corpora. Additional
file types (HTML/MD/code/images/audio/DB/...) are handled by plugins added
in Commits B, C, E.

Canonical chunk schema (D-007):
  {
    "id":        "<source-stem>-<suffix>",
    "text":      "<extracted text>",
    "format":    "pretrain",
    "metadata": {
      "source_file":   "relative/path.ext",
      "source_format": "pdf|docx|pptx|txt|html|md|...",
      "section":       "<top-level section dir>",
      "doc_title":     "<filename stem>",
      "chunk_type":    "page|slide|paragraph|full|cell|row|ocr|transcript|metadata_only",
      "chunk_idx":     <int>,
      "char_count":    <int>
    }
  }

Filters (unchanged from v1):
  - length 200 <= chars <= 100_000 (long chunks are split at paragraph breaks)
  - dedup by SHA-256 of normalized text (whitespace-collapsed, lowercase)
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Iterator

# Make prep_plugins importable when script is run directly (not as a module)
sys.path.insert(0, str(Path(__file__).resolve().parent))

from prep_plugins import get_dispatcher, ALWAYS_IGNORE_EXTENSIONS, list_available_plugins
from prep_plugins.orchestration_helpers import (
    MIN_LEN, MAX_LEN, norm_id, hash_text,
)
from prep_plugins.schema import validate_chunk


def load_subtopic_map(path: Path | None) -> dict | None:
    """Load subtopic map JSON, or None if not provided / missing."""
    if path is None:
        return None
    if not path.is_file():
        sys.stderr.write(f"prep: subtopic-map file missing: {path}\n")
        return None
    with open(path) as f:
        return json.load(f)


def derive_subtopic(source_file: str, subtopic_map: dict | None) -> str:
    """Map a relative source path to a subtopic bucket.

    Schema: { "_default": str, "prefixes": {prefix: subtopic},
              "files": {exact_path: subtopic} }.
    files{} wins over prefixes{} (longest-prefix match within prefixes).
    Returns _default if no match. Returns "unmapped" when subtopic_map is None.
    """
    if subtopic_map is None:
        return "unmapped"
    files = subtopic_map.get("files", {})
    if source_file in files:
        return files[source_file]
    prefixes = subtopic_map.get("prefixes", {})
    matches = sorted(
        (p for p in prefixes if source_file.startswith(p)),
        key=len, reverse=True,
    )
    if matches:
        return prefixes[matches[0]]
    return subtopic_map.get("_default", "dental_ai_general")


def walk(raw_dir: Path, publications_root_hint: str = "Publications",
         dispatcher: dict | None = None,
         failures: list | None = None) -> Iterator[dict]:
    """Walk the corpus dir and yield chunks. Preserves v1 section-detection:
    first directory component == publications_root_hint → use second component
    as section; else first component.
    """
    if dispatcher is None:
        dispatcher = get_dispatcher()

    # Pre-walk so we know the total file count for progress reporting.
    # Cheap: just stats, no content reads. Enables Whisper/OCR ETA.
    files: list[Path] = []
    for p in sorted(raw_dir.rglob("*")):
        if p.is_file():
            ext = p.suffix.lower()
            if ext in ALWAYS_IGNORE_EXTENSIONS:
                continue
            if dispatcher.get(ext) is None:
                continue
            files.append(p)

    try:
        from prep_plugins.progress import Progress
        prog = Progress("prep", total=len(files))
    except ImportError:
        prog = None

    for p in files:
        ext = p.suffix.lower()
        plugin = dispatcher.get(ext)

        parts = p.relative_to(raw_dir).parts
        if parts and parts[0] == publications_root_hint and len(parts) > 1:
            section = parts[1]
        else:
            section = parts[0] if parts else "unknown"
        base_id = norm_id(p.stem)

        try:
            yield from plugin.iter_chunks(p, section, base_id, options={})
        except Exception as e:
            msg = f"{type(e).__name__}: {e}"
            sys.stderr.write(f"  [plugin-error] {p}: {msg}\n")
            if failures is not None:
                failures.append({
                    "path": str(p.relative_to(raw_dir)),
                    "ext": ext,
                    "plugin": type(plugin).__name__ if plugin else "?",
                    "error": msg,
                })
        if prog is not None:
            prog.tick()
    if prog is not None:
        prog.done()


def main() -> int:
    ap = argparse.ArgumentParser(description="Multi-format corpus preprocessor (v2.1)")
    ap.add_argument("--input", required=True, help="raw corpus directory")
    ap.add_argument("--output", required=True, help="output JSONL path")
    ap.add_argument("--stats", help="optional path to write a stats JSON")
    ap.add_argument("--subtopic-map",
                    help="optional path to subtopic-map.json (path-prefix → subtopic)")
    ap.add_argument("--list-plugins", action="store_true",
                    help="list available plugins + their extensions, then exit")
    args = ap.parse_args()

    if args.list_plugins:
        print(json.dumps(list_available_plugins(), indent=2))
        return 0

    raw_dir = Path(args.input)
    if not raw_dir.is_dir():
        sys.stderr.write(f"prep: input not a dir: {raw_dir}\n")
        return 64

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    subtopic_map = load_subtopic_map(Path(args.subtopic_map)) if args.subtopic_map else None
    if args.subtopic_map and subtopic_map is None:
        sys.stderr.write(f"prep: subtopic-map could not be loaded; emitting subtopic='unmapped'\n")

    dispatcher = get_dispatcher()

    seen_hashes: set[str] = set()
    total_in = 0
    total_out = 0
    by_format: dict[str, int] = {}
    by_section: dict[str, int] = {}
    by_subtopic: dict[str, int] = {}
    plugin_failures: list = []
    rejected_short = 0
    rejected_long = 0
    rejected_dup = 0
    total_chars = 0

    schema_failures = 0
    with open(out_path, "w") as f:
        for chunk in walk(raw_dir, dispatcher=dispatcher, failures=plugin_failures):
            total_in += 1
            # Schema guard — catch off-spec plugin output before it corrupts
            # the downstream pipeline. On failure, skip + log.
            ok, reason = validate_chunk(chunk)
            if not ok:
                schema_failures += 1
                if schema_failures <= 5:
                    sys.stderr.write(f"  [schema] {chunk.get('id','?')}: {reason}\n")
                continue
            # Inject subtopic from path-prefix map. Propagates to sub-chunks
            # via dict() copy below. Plugins set source_file to absolute path
            # but the map uses paths relative to raw_dir — convert here.
            src = chunk["metadata"]["source_file"]
            try:
                src_for_map = str(Path(src).relative_to(raw_dir))
            except ValueError:
                src_for_map = src  # fallback: outside raw_dir, use as-is
            chunk["metadata"]["subtopic"] = derive_subtopic(src_for_map, subtopic_map)
            text = chunk["text"]
            n = len(text)
            if n < MIN_LEN:
                rejected_short += 1
                continue
            if n > MAX_LEN:
                rejected_long += 1
                mid = n // 2
                split = text.rfind("\n\n", 0, mid)
                if split == -1:
                    split = mid
                halves = [text[:split], text[split:]]
                for j, half in enumerate(halves):
                    if MIN_LEN <= len(half) <= MAX_LEN:
                        sub = dict(chunk)
                        sub["id"] = f"{chunk['id']}-part{j}"
                        sub["text"] = half
                        sub["metadata"] = dict(
                            chunk["metadata"],
                            char_count=len(half),
                            chunk_type=chunk["metadata"]["chunk_type"] + "-split",
                        )
                        h = hash_text(half)
                        if h in seen_hashes:
                            rejected_dup += 1
                            continue
                        seen_hashes.add(h)
                        f.write(json.dumps(sub) + "\n")
                        total_out += 1
                        total_chars += len(half)
                        fmt = sub["metadata"]["source_format"]
                        by_format[fmt] = by_format.get(fmt, 0) + 1
                        sec = sub["metadata"]["section"]
                        by_section[sec] = by_section.get(sec, 0) + 1
                        st = sub["metadata"]["subtopic"]
                        by_subtopic[st] = by_subtopic.get(st, 0) + 1
                continue
            h = hash_text(text)
            if h in seen_hashes:
                rejected_dup += 1
                continue
            seen_hashes.add(h)
            f.write(json.dumps(chunk) + "\n")
            total_out += 1
            total_chars += n
            fmt = chunk["metadata"]["source_format"]
            by_format[fmt] = by_format.get(fmt, 0) + 1
            sec = chunk["metadata"]["section"]
            by_section[sec] = by_section.get(sec, 0) + 1
            st = chunk["metadata"]["subtopic"]
            by_subtopic[st] = by_subtopic.get(st, 0) + 1

    stats = {
        "total_chunks_input": total_in,
        "total_chunks_output": total_out,
        "total_chars": total_chars,
        "approx_total_tokens": total_chars // 4,
        "by_format": by_format,
        "by_section_top10": dict(sorted(by_section.items(), key=lambda kv: -kv[1])[:10]),
        "by_subtopic": by_subtopic,
        "plugin_failure_count": len(plugin_failures),
        "plugin_failures": plugin_failures[:20],  # cap to keep stats file readable
        "rejected": {
            "length_short": rejected_short,
            "length_long_split": rejected_long,
            "dedup": rejected_dup,
            "schema_failures": schema_failures,
        },
    }
    print(json.dumps(stats, indent=2))

    if args.stats:
        with open(args.stats, "w") as f:
            json.dump(stats, f, indent=2)

    return 0


if __name__ == "__main__":
    sys.exit(main())
