#!/usr/bin/env python3
"""
Phase 2 — Q/A synthesis from cleaned corpus.

For each cleaned passage, call Claude Haiku 4.5 to generate 3 Q/A pairs:
  1. Factual recall
  2. Mechanism / "why does this work"
  3. Compare / contrast / clinical context

Output: slm-forge/.overnight/qa.jsonl in proper SFT chat format:
  {"id": ..., "format": "chat", "messages": [{"role":"user", ...}, {"role":"assistant", ...}], "metadata": {...}}

Concurrency: 12 parallel requests. ~1500 docs × ~1.2 sec/req @ 12 parallel = ~3 min.
Budget: ~$4-8 (Haiku 4.5 at $1/$5 per M tokens in/out).
"""
from __future__ import annotations
import asyncio
import json
import os
import sys
from pathlib import Path

try:
    from anthropic import AsyncAnthropic
except ImportError:
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", "anthropic"])
    from anthropic import AsyncAnthropic


CLEAN = Path(os.environ.get("FORGE_SYNTH_INPUT", "slm-forge/.overnight/cleaned.jsonl"))
OUT = Path(os.environ.get("FORGE_SYNTH_OUTPUT", "slm-forge/.overnight/qa.jsonl"))
PROGRESS = Path(os.environ.get("FORGE_SYNTH_PROGRESS", str(OUT) + "-progress.json"))
ERRORS = Path(os.environ.get("FORGE_SYNTH_ERRORS", str(OUT) + "-errors.jsonl"))

MODEL = "claude-haiku-4-5"
CONCURRENCY = 12
MAX_PASSAGE_CHARS = 6000  # truncate gigantic passages

SYSTEM_PROMPT = """You generate training examples for a small dental-research assistant model.

For the given passage from a dental research publication, produce exactly 3 high-quality Q&A pairs in JSON.

Pair types (one of each, in this order):
1. **Factual recall** — a specific fact the passage states.
2. **Mechanism** — "why" or "how does this work" — explain a process the passage describes.
3. **Clinical/practical** — a question a dental student or clinician might ask, answered using the passage's content.

Strict rules:
- Answers MUST be grounded in the passage. Do not speculate or add external knowledge.
- If the passage doesn't support a clinical question (e.g. it's pure ML methodology), generate a comparative/methodology question instead.
- Questions should be natural English, NOT "according to the passage" framing — the model should learn the knowledge, not the meta-frame.
- Answers should be 2-5 sentences, plain prose, no markdown lists.
- NO marketing language ("revolutionize", "exciting journey", "game-changer", "in conclusion"). Plain technical writing only.
- Use specific dental terminology where the passage does.

Output exactly this JSON (no preamble, no commentary):
{"qa": [
  {"q": "...", "a": "...", "type": "factual"},
  {"q": "...", "a": "...", "type": "mechanism"},
  {"q": "...", "a": "...", "type": "clinical"}
]}"""


async def synth_one(client: AsyncAnthropic, sem: asyncio.Semaphore, doc: dict) -> dict | None:
    text = doc["text"][:MAX_PASSAGE_CHARS]
    async with sem:
        try:
            resp = await client.messages.create(
                model=MODEL,
                max_tokens=1500,
                system=SYSTEM_PROMPT,
                messages=[{"role": "user", "content": f"Passage:\n\n{text}"}],
            )
            raw = resp.content[0].text.strip()
            # Strip code-fence if present
            if raw.startswith("```"):
                raw = raw.split("```", 2)[1]
                if raw.startswith("json"):
                    raw = raw[4:]
                raw = raw.strip()
            data = json.loads(raw)
            qa_list = data.get("qa", [])
            if not isinstance(qa_list, list) or len(qa_list) < 1:
                return None
            return {
                "id": doc["id"],
                "qa": qa_list,
                "input_tokens": resp.usage.input_tokens,
                "output_tokens": resp.usage.output_tokens,
                "source_section": doc.get("metadata", {}).get("section"),
                "source_subtopic": doc.get("metadata", {}).get("subtopic", "unmapped"),
            }
        except Exception as e:
            ERRORS.parent.mkdir(parents=True, exist_ok=True)
            with ERRORS.open("a") as f:
                f.write(json.dumps({"id": doc["id"], "error": f"{type(e).__name__}: {e}"}) + "\n")
            return None


async def main() -> int:
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ANTHROPIC_API_KEY not set", file=sys.stderr)
        return 64

    docs = []
    with CLEAN.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            docs.append(json.loads(line))
    print(f"[synth] loaded {len(docs)} cleaned docs", file=sys.stderr)

    # Resume support
    done_ids = set()
    if OUT.exists():
        with OUT.open() as f:
            for line in f:
                try:
                    done_ids.add(json.loads(line)["passage_id"])
                except (json.JSONDecodeError, KeyError):
                    pass
    todo = [d for d in docs if d["id"] not in done_ids]
    print(f"[synth] {len(done_ids)} already done, {len(todo)} remaining", file=sys.stderr)

    if not todo:
        print("[synth] nothing to do — all passages already synthesized", file=sys.stderr)
        return 0

    client = AsyncAnthropic(api_key=api_key)
    sem = asyncio.Semaphore(CONCURRENCY)

    total_in = 0
    total_out = 0
    total_pairs = 0
    n_done = len(done_ids)
    n_failed = 0

    out_f = OUT.open("a")
    try:
        tasks = [synth_one(client, sem, d) for d in todo]
        for i, future in enumerate(asyncio.as_completed(tasks)):
            res = await future
            if res is None:
                n_failed += 1
            else:
                total_in += res["input_tokens"]
                total_out += res["output_tokens"]
                # Emit one chat-format example PER Q/A pair
                for qa_idx, qa in enumerate(res["qa"]):
                    if not isinstance(qa, dict) or "q" not in qa or "a" not in qa:
                        continue
                    rec = {
                        "id": f"{res['id']}-qa{qa_idx}",
                        "passage_id": res["id"],
                        "format": "chat",
                        "messages": [
                            {"role": "user", "content": qa["q"]},
                            {"role": "assistant", "content": qa["a"]},
                        ],
                        "metadata": {
                            "qa_type": qa.get("type", "unknown"),
                            "source_section": res["source_section"],
                            "subtopic": res.get("source_subtopic", "unmapped"),
                            "passage_id": res["id"],
                        },
                    }
                    out_f.write(json.dumps(rec) + "\n")
                    total_pairs += 1
                out_f.flush()
                n_done += 1

            if (i + 1) % 50 == 0:
                pct = 100 * (i + 1) / len(tasks)
                # Haiku 4.5 pricing: $1/M in, $5/M out
                cost = total_in * 1.0 / 1_000_000 + total_out * 5.0 / 1_000_000
                print(f"[synth] {i+1}/{len(tasks)} ({pct:.1f}%) "
                      f"pairs={total_pairs} failed={n_failed} "
                      f"in={total_in:,} out={total_out:,} cost=${cost:.3f}",
                      file=sys.stderr)
                PROGRESS.write_text(json.dumps({
                    "completed": i + 1, "total": len(tasks),
                    "pairs": total_pairs, "failed": n_failed,
                    "input_tokens": total_in, "output_tokens": total_out,
                    "estimated_cost_usd": round(cost, 3),
                }, indent=2))

    finally:
        out_f.close()
        client = None

    cost = total_in * 1.0 / 1_000_000 + total_out * 5.0 / 1_000_000
    final = {
        "input_passages": len(docs),
        "synthesized_passages": n_done,
        "failed_passages": n_failed,
        "total_qa_pairs": total_pairs,
        "input_tokens": total_in,
        "output_tokens": total_out,
        "actual_cost_usd": round(cost, 3),
    }
    PROGRESS.write_text(json.dumps(final, indent=2))
    print(json.dumps(final, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
