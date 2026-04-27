#!/usr/bin/env python3
"""classify-proceedings.py — Haiku-assisted subtopic classification for
multi-topic proceedings folders (ISBI, MICCAI, SPIE, JBHI, JMI, MEDIA, TMI).

Walks the named proceedings folders under the run's target dir, extracts
first ~1500 chars of each paper, asks Haiku to classify into one of:
  - crown_generation
  - margin_line
  - segmentation
  - dental_ai_general (default for unclear / general dental AI)

Writes results into <run-dir>/subtopic-map.json under "files" (exact-path
overrides; longest-prefix loses to exact match per the prep-orchestrator
mapper logic).

Usage:
  classify-proceedings.py --run-id <id> [--proceedings "ISBI 2022,MICCAI2023,..."]

If --proceedings omitted, uses the default list below.
"""
from __future__ import annotations
import argparse, json, os, sys, asyncio
from collections import Counter
from pathlib import Path

DEFAULT_PROCEEDINGS = [
    "ISBI 2022", "ISBI 2025", "ISBI 2026",
    "MICCAI2023", "MICCAI2024",
    "SPIE 2022", "SPIE2023", "SPIE 2024", "SPIE 2025", "SPIE2026",
    "JMI 2024", "JMI2025",
    "MEDIA 2025", "TMI 2022", "JBHI 2022",
]

VALID_SUBTOPICS = {"crown_generation", "margin_line", "segmentation", "dental_ai_general"}

PROMPT = """Classify this dental AI research paper into ONE subtopic.

Subtopic options (choose exactly one):
- crown_generation: AI for generating dental crowns / restorations / mesh completion / cusp recovery
- margin_line: Margin line detection or extraction for prepared teeth
- segmentation: Tooth, jaw, or anatomical segmentation from 3D scans / point clouds / meshes
- dental_ai_general: General dental AI, multimodal scan visualization, evaluation methods, datasets, surveys, or unclear

Paper filename: {filename}
Folder: {folder}

First excerpt of paper text:
---
{excerpt}
---

Respond with ONLY the subtopic name (one of the four above), nothing else."""


def extract_first(path: Path, max_chars: int = 1500) -> str:
    suffix = path.suffix.lower()
    try:
        if suffix == ".pdf":
            import pdfplumber
            with pdfplumber.open(path) as pdf:
                text = ""
                for page in pdf.pages[:3]:
                    text += (page.extract_text() or "") + "\n"
                    if len(text) >= max_chars:
                        break
                return text[:max_chars]
        elif suffix == ".docx":
            from docx import Document
            doc = Document(path)
            text = "\n".join(p.text for p in doc.paragraphs[:60])
            return text[:max_chars]
    except Exception as e:
        return f"[extract failed: {type(e).__name__}: {e}]"
    return "[unsupported format]"


async def classify_one(client, sem, path: Path, pubs_root: Path):
    rel_path = str(path.relative_to(pubs_root))
    folder = path.parent.name
    excerpt = extract_first(path)
    if excerpt.startswith("[") and "failed" in excerpt:
        return rel_path, "dental_ai_general", f"extract_fail: {excerpt[:60]}"
    if not excerpt.strip():
        return rel_path, "dental_ai_general", "empty extract"

    async with sem:
        try:
            r = await client.messages.create(
                model="claude-haiku-4-5-20251001",
                max_tokens=20,
                messages=[{"role": "user", "content": PROMPT.format(
                    filename=path.name, folder=folder, excerpt=excerpt
                )}],
            )
            label = r.content[0].text.strip().lower()
            if label not in VALID_SUBTOPICS:
                return rel_path, "dental_ai_general", f"invalid_label='{label[:40]}'"
            return rel_path, label, None
        except Exception as e:
            return rel_path, "dental_ai_general", f"haiku_err: {type(e).__name__}: {e}"


async def main_async(args):
    repo_root = Path(__file__).resolve().parent.parent.parent
    run_dir = repo_root / "slm-forge" / ".runs" / args.run_id
    map_path = run_dir / "subtopic-map.json"
    if not map_path.is_file():
        print(f"error: subtopic-map.json not found at {map_path}", file=sys.stderr)
        return 1

    # Find pubs root from existing analysis.json
    analysis = json.load(open(run_dir / "analysis.json"))
    pubs_root = Path(analysis["target_dir"])
    if not pubs_root.is_dir():
        print(f"error: target_dir not a dir: {pubs_root}", file=sys.stderr)
        return 1

    proceedings = (args.proceedings.split(",") if args.proceedings
                   else DEFAULT_PROCEEDINGS)

    files = []
    for d in proceedings:
        folder = pubs_root / d.strip()
        if not folder.exists():
            print(f"  [skip] folder not found: {d}", file=sys.stderr)
            continue
        for p in folder.rglob("*"):
            if p.suffix.lower() in (".pdf", ".docx") and p.is_file():
                files.append(p)
    print(f"[classify] {len(files)} papers across {len(proceedings)} proceedings folders", file=sys.stderr)

    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("error: ANTHROPIC_API_KEY not set", file=sys.stderr)
        return 1

    from anthropic import AsyncAnthropic
    client = AsyncAnthropic()
    sem = asyncio.Semaphore(8)
    tasks = [classify_one(client, sem, p, pubs_root) for p in files]
    results = await asyncio.gather(*tasks)

    with open(map_path) as f:
        m = json.load(f)

    issues = []
    for rel_path, subtopic, note in results:
        m["files"][rel_path] = subtopic
        if note:
            issues.append((rel_path, subtopic, note))
            print(f"  [issue] {rel_path}: {subtopic}  ({note})", file=sys.stderr)

    m["files"] = dict(sorted(m["files"].items()))
    with open(map_path, "w") as f:
        json.dump(m, f, indent=2, ensure_ascii=False)

    c = Counter(s for _, s, _ in results)
    print(f"\n[classify] wrote {len(results)} entries to files{{}}; distribution:", file=sys.stderr)
    for k, v in c.most_common():
        print(f"  {k}: {v}", file=sys.stderr)
    if issues:
        print(f"\n[classify] {len(issues)} issues (defaulted to dental_ai_general — review)", file=sys.stderr)

    # Emit JSON summary on stdout for downstream tooling
    summary = {
        "n_classified": len(results),
        "distribution": dict(c),
        "issues_count": len(issues),
        "map_path": str(map_path),
    }
    print(json.dumps(summary, indent=2))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--proceedings", help="comma-separated folder names; default = built-in list")
    args = ap.parse_args()
    return asyncio.run(main_async(args))


if __name__ == "__main__":
    sys.exit(main())
