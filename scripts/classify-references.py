#!/usr/bin/env python3
"""classify-references.py — Haiku-assisted keep/drop classification for the
DLATeeth-references folder. Removes general-methodology papers whose
content covers off-topic domains (drug design, NLP, etc.) while keeping
dental-applied and dental-foundational work.

Output:
  - references-classification.json (keep/drop per file with reasoning)
  - rewrites qa-filtered.jsonl in place (dropping Q/A from drop-flagged sources)
  - rewrites audited/cleaned.jsonl in place (same)
  - keeps a .pre-references-filter.bak alongside each rewritten file

Usage:
  classify-references.py --run-id <id> [--folder DLATeeth-references]
"""
from __future__ import annotations
import argparse, json, os, sys, asyncio, shutil
from collections import Counter
from pathlib import Path

PROMPT = """This paper is in a dental AI research team's references folder. \
Classify whether to KEEP or DROP it for training a dental research SLM.

KEEP: papers whose CONTENT focuses on dental AI, dental imaging, tooth \
segmentation, dental CAD/CAM, dental restoration, oral anatomy, OR \
foundational methodology papers with a single-domain focus that aligns \
with the dental application (e.g., a CNN tutorial paper, a 3D mesh \
analysis method paper).

DROP: papers whose main content surveys multiple unrelated domains \
(drug design + NLP + chemistry + vision in a single GNN survey), or \
whose main subject is non-dental (e.g., text-to-shape generation, \
general point cloud retrieval, drug discovery, language modeling).

Paper filename: {filename}

First excerpt of paper text:
---
{excerpt}
---

Respond with EXACTLY one line in the format:
DECISION: <keep|drop>
REASON: <one short clause>"""


def extract_first(path: Path, max_chars: int = 1800) -> str:
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
            text = "\n".join(p.text for p in doc.paragraphs[:80])
            return text[:max_chars]
    except Exception as e:
        return f"[extract failed: {type(e).__name__}: {e}]"
    return "[unsupported]"


async def classify_one(client, sem, path: Path, root: Path):
    rel_path = str(path.relative_to(root))
    excerpt = extract_first(path)
    if excerpt.startswith("[") and "failed" in excerpt:
        return rel_path, "keep", f"extract_fail (defaulting keep): {excerpt[:60]}"
    if not excerpt.strip():
        return rel_path, "keep", "empty extract (defaulting keep)"

    async with sem:
        try:
            r = await client.messages.create(
                model="claude-haiku-4-5-20251001",
                max_tokens=80,
                messages=[{"role": "user", "content": PROMPT.format(
                    filename=path.name, excerpt=excerpt
                )}],
            )
            raw = r.content[0].text.strip()
            decision = "keep"
            reason = ""
            for line in raw.splitlines():
                if line.upper().startswith("DECISION:"):
                    val = line.split(":", 1)[1].strip().lower()
                    if val in ("keep", "drop"):
                        decision = val
                elif line.upper().startswith("REASON:"):
                    reason = line.split(":", 1)[1].strip()
            return rel_path, decision, reason or raw[:80]
        except Exception as e:
            return rel_path, "keep", f"haiku_err (defaulting keep): {type(e).__name__}: {e}"


async def main_async(args):
    repo_root = Path(__file__).resolve().parent.parent.parent
    run_dir = repo_root / "slm-forge" / ".runs" / args.run_id
    pubs_root = Path(json.load(open(run_dir / "analysis.json"))["target_dir"])
    ref_root = pubs_root / args.folder

    if not ref_root.is_dir():
        print(f"error: {ref_root} not a directory", file=sys.stderr)
        return 1

    files = []
    for p in ref_root.rglob("*"):
        if p.suffix.lower() in (".pdf", ".docx") and p.is_file():
            files.append(p)
    print(f"[classify-refs] {len(files)} papers in {args.folder}", file=sys.stderr)

    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("error: ANTHROPIC_API_KEY not set", file=sys.stderr)
        return 1

    from anthropic import AsyncAnthropic
    client = AsyncAnthropic()
    sem = asyncio.Semaphore(8)
    results = await asyncio.gather(*[classify_one(client, sem, p, pubs_root) for p in files])

    # Write classification report
    report = {
        "folder": args.folder,
        "n_papers": len(results),
        "decisions": {rel_path: {"decision": dec, "reason": reason}
                      for rel_path, dec, reason in results},
    }
    out_report = run_dir / "references-classification.json"
    with open(out_report, "w") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    c = Counter(d for _, d, _ in results)
    print(f"\n[classify-refs] decisions:", file=sys.stderr)
    for k, v in c.most_common():
        print(f"  {k}: {v}", file=sys.stderr)

    drop_paths = {rp for rp, dec, _ in results if dec == "drop"}
    print(f"\n[classify-refs] {len(drop_paths)} papers flagged drop", file=sys.stderr)
    for rp, dec, reason in sorted(results, key=lambda x: x[1]):
        if dec == "drop":
            print(f"  DROP  {rp[:70]}  ({reason[:80]})", file=sys.stderr)

    # Filter qa-filtered.jsonl + audited/cleaned.jsonl by passage source path
    # Build passage_id → source_file map from cleaned.jsonl
    id2src = {}
    cleaned_path = run_dir / "audited" / "cleaned.jsonl"
    with open(cleaned_path) as f:
        for line in f:
            d = json.loads(line)
            sf = d["metadata"]["source_file"]
            try:
                rel = str(Path(sf).relative_to(pubs_root))
            except ValueError:
                rel = sf
            id2src[d["id"]] = rel

    # Filter qa-filtered.jsonl
    qa_path = run_dir / "qa-filtered.jsonl"
    qa_bak = qa_path.with_suffix(".jsonl.pre-references-filter.bak")
    if not qa_bak.exists():
        shutil.copy(qa_path, qa_bak)
    qa_in = qa_out = 0
    qa_dropped_by_subtopic = Counter()
    rows = []
    with open(qa_path) as f:
        for line in f:
            d = json.loads(line)
            qa_in += 1
            pid = d["metadata"].get("passage_id")
            src = id2src.get(pid, "")
            if src in drop_paths:
                qa_dropped_by_subtopic[d["metadata"].get("subtopic", "?")] += 1
                continue
            rows.append(json.dumps(d))
            qa_out += 1
    with open(qa_path, "w") as f:
        f.write("\n".join(rows) + "\n")

    print(f"\n[classify-refs] qa-filtered.jsonl: {qa_in} → {qa_out} (-{qa_in - qa_out})", file=sys.stderr)
    if qa_dropped_by_subtopic:
        print(f"  drops by subtopic:", file=sys.stderr)
        for k, v in qa_dropped_by_subtopic.most_common():
            print(f"    {k}: {v}", file=sys.stderr)

    # Filter cleaned.jsonl too (so any future re-runs don't see the bad chunks)
    cleaned_bak = cleaned_path.with_suffix(".jsonl.pre-references-filter.bak")
    if not cleaned_bak.exists():
        shutil.copy(cleaned_path, cleaned_bak)
    c_in = c_out = 0
    rows = []
    with open(cleaned_path) as f:
        for line in f:
            d = json.loads(line)
            c_in += 1
            sf = d["metadata"]["source_file"]
            try:
                rel = str(Path(sf).relative_to(pubs_root))
            except ValueError:
                rel = sf
            if rel in drop_paths:
                continue
            rows.append(json.dumps(d))
            c_out += 1
    with open(cleaned_path, "w") as f:
        f.write("\n".join(rows) + "\n")
    print(f"[classify-refs] cleaned.jsonl: {c_in} → {c_out} (-{c_in - c_out})", file=sys.stderr)

    print(json.dumps({
        "n_papers_classified": len(results),
        "n_drops": len(drop_paths),
        "qa_pairs": {"before": qa_in, "after": qa_out, "dropped": qa_in - qa_out},
        "cleaned_chunks": {"before": c_in, "after": c_out, "dropped": c_in - c_out},
        "report_path": str(out_report),
    }, indent=2))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--folder", default="DLATeeth-references")
    args = ap.parse_args()
    return asyncio.run(main_async(args))


if __name__ == "__main__":
    sys.exit(main())
