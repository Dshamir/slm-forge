#!/usr/bin/env python3
"""
slm-forge/scripts/eval.py — simple eval runner for forge-eval (M5 v1).

Computes:
  1. Perplexity of the merged/final model on test.jsonl
  2. Perplexity of the baseline (plan.base_model) on test.jsonl
  3. 10 sample generations from the merged model (domain-agnostic prompts)

Skipped in M5 v1 (M5+ hardening):
  - lm-eval-harness tasks (hellaswag / arc_easy / winogrande) — requires
    task data downloads + extra 10-30 min eval time. Forge-eval's
    output is enough for the QUALITY_GATE prompt without it.

Outputs (to --out-dir):
  perplexity.json                {model_ppl, baseline_ppl, delta, samples}
  samples.md                     20 prompts × generations in readable form
  comparison-vs-baseline.md      table + executive summary
  domain-bench-report.md         placeholder in v1 (for router when domain eval sets land)

Usage:
  eval.py \
    --model-dir <hf path or local merged dir> \
    --baseline <hf repo id> \
    --test-jsonl <path> \
    --samples-prompts <path> \
    --out-dir <path> \
    [--max-test-docs 100] [--num-samples 10]
"""
from __future__ import annotations
import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any
from collections import defaultdict


def _lazy_torch():
    try:
        import torch
        return torch
    except ImportError as e:
        sys.stderr.write(f"eval: torch not installed: {e}\n")
        sys.exit(5)


def _lazy_tfs():
    try:
        from transformers import AutoModelForCausalLM, AutoTokenizer
        return AutoModelForCausalLM, AutoTokenizer
    except ImportError as e:
        sys.stderr.write(f"eval: transformers not installed: {e}\n")
        sys.exit(3)


def compute_perplexity(model, tokenizer, texts: list[str], max_length: int = 512) -> float:
    """Average per-token NLL over a list of texts → exp → perplexity."""
    torch = _lazy_torch()
    model.eval()
    device = next(model.parameters()).device

    total_nll = 0.0
    total_tokens = 0
    with torch.no_grad():
        for txt in texts:
            enc = tokenizer(txt, return_tensors="pt", truncation=True, max_length=max_length)
            input_ids = enc["input_ids"].to(device)
            if input_ids.shape[1] < 2:
                continue
            outputs = model(input_ids=input_ids, labels=input_ids)
            # outputs.loss is mean NLL over tokens in this sequence
            n_tokens = input_ids.shape[1] - 1
            total_nll += float(outputs.loss) * n_tokens
            total_tokens += n_tokens
    if total_tokens == 0:
        return float("inf")
    mean_nll = total_nll / total_tokens
    return math.exp(min(mean_nll, 20))  # cap to avoid inf/overflow for very bad models


def generate_samples(model, tokenizer, prompts: list[str], max_new_tokens: int = 100) -> list[dict[str, str]]:
    torch = _lazy_torch()
    model.eval()
    device = next(model.parameters()).device
    samples = []
    for prompt in prompts:
        try:
            enc = tokenizer(prompt, return_tensors="pt", truncation=True, max_length=256)
            input_ids = enc["input_ids"].to(device)
            with torch.no_grad():
                out = model.generate(
                    input_ids,
                    max_new_tokens=max_new_tokens,
                    do_sample=True,
                    temperature=0.7,
                    top_p=0.9,
                    pad_token_id=tokenizer.eos_token_id,
                )
            full = tokenizer.decode(out[0], skip_special_tokens=True)
            # Strip the prompt echo
            response = full[len(prompt):].strip() if full.startswith(prompt) else full.strip()
            samples.append({"prompt": prompt, "response": response})
        except Exception as e:
            samples.append({"prompt": prompt, "response": f"[generation failed: {type(e).__name__}: {e}]"})
    return samples


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", required=True, help="merged/final model directory OR HF repo id")
    ap.add_argument("--baseline", required=True, help="baseline HF repo id (plan.base_model)")
    ap.add_argument("--test-jsonl", required=True, help="test.jsonl from forge-shape")
    ap.add_argument("--samples-prompts", required=True, help="text file with one prompt per line")
    ap.add_argument("--out-dir", required=True, help="output directory for reports")
    ap.add_argument("--max-test-docs", type=int, default=100)
    ap.add_argument("--num-samples", type=int, default=10)
    ap.add_argument("--skip-baseline", action="store_true")
    args = ap.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    AutoModelForCausalLM, AutoTokenizer = _lazy_tfs()
    torch = _lazy_torch()

    # ---- Load test docs (preserving subtopic for per-subtopic eval) ----
    test_records: list[tuple[str, str]] = []
    with open(args.test_jsonl) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                doc = json.loads(line)
            except json.JSONDecodeError:
                continue
            # Unified schema: {id, domain, format, messages, raw_text, metadata}
            text = doc.get("raw_text") or doc.get("text") or ""
            if not text and doc.get("messages"):
                text = "\n".join(m.get("content", "") for m in doc["messages"])
            if text:
                st = doc.get("metadata", {}).get("subtopic", "unmapped")
                test_records.append((text, st))
            if len(test_records) >= args.max_test_docs:
                break
    test_texts = [t for t, _ in test_records]
    by_st: dict[str, list[str]] = defaultdict(list)
    for t, s in test_records:
        by_st[s].append(t)
    print(f"[eval] {len(test_texts)} test docs loaded", flush=True)
    print(f"[eval] subtopics: {dict((k, len(v)) for k, v in sorted(by_st.items()))}", flush=True)

    # ---- Load sample prompts ----
    prompts = []
    if Path(args.samples_prompts).exists():
        with open(args.samples_prompts) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    prompts.append(line)
                if len(prompts) >= args.num_samples:
                    break
    print(f"[eval] {len(prompts)} sample prompts loaded", flush=True)

    # ---- Load merged/final model ----
    print(f"[eval] loading merged model from {args.model_dir}...", flush=True)
    tokenizer = AutoTokenizer.from_pretrained(args.model_dir)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    model = AutoModelForCausalLM.from_pretrained(args.model_dir, torch_dtype=torch.bfloat16)
    model_params = sum(p.numel() for p in model.parameters())
    print(f"[eval] merged model loaded: {model_params:,} params", flush=True)

    # ---- Perplexity on merged model ----
    print("[eval] computing perplexity of merged model...", flush=True)
    model_ppl = compute_perplexity(model, tokenizer, test_texts)
    print(f"[eval] merged model perplexity = {model_ppl:.3f}", flush=True)

    # Per-subtopic perplexity (merged model)
    per_subtopic_ppl: dict[str, float] = {}
    for st in sorted(by_st):
        texts = by_st[st]
        if not texts:
            continue
        ppl = compute_perplexity(model, tokenizer, texts)
        per_subtopic_ppl[st] = round(ppl, 3)
        print(f"[eval]   merged   {st:24s} n={len(texts):>4d}  ppl={ppl:.3f}", flush=True)

    # ---- Sample generations ----
    print(f"[eval] generating {len(prompts)} sample responses...", flush=True)
    samples = generate_samples(model, tokenizer, prompts) if prompts else []

    # Per-subtopic samples: 2 seeds per subtopic from test docs (first ~80 chars).
    per_subtopic_samples: dict[str, list[dict]] = {}
    for st in sorted(by_st):
        seeds = [t[:80].strip() for t in by_st[st][:2]]
        per_subtopic_samples[st] = (
            generate_samples(model, tokenizer, seeds, max_new_tokens=120)
            if seeds else []
        )

    # ---- Baseline perplexity ----
    baseline_ppl = None
    per_subtopic_baseline_ppl: dict[str, float] = {}
    if not args.skip_baseline:
        print(f"[eval] loading baseline {args.baseline}...", flush=True)
        try:
            del model
            torch.cuda.empty_cache() if torch.cuda.is_available() else None
            baseline_tokenizer = AutoTokenizer.from_pretrained(args.baseline)
            if baseline_tokenizer.pad_token is None:
                baseline_tokenizer.pad_token = baseline_tokenizer.eos_token
            baseline_model = AutoModelForCausalLM.from_pretrained(args.baseline, torch_dtype=torch.bfloat16)
            print(f"[eval] computing perplexity of baseline...", flush=True)
            baseline_ppl = compute_perplexity(baseline_model, baseline_tokenizer, test_texts)
            print(f"[eval] baseline perplexity = {baseline_ppl:.3f}", flush=True)
            for st in sorted(by_st):
                texts = by_st[st]
                if not texts:
                    continue
                p = compute_perplexity(baseline_model, baseline_tokenizer, texts)
                per_subtopic_baseline_ppl[st] = round(p, 3)
                print(f"[eval]   baseline {st:24s} ppl={p:.3f}", flush=True)
        except Exception as e:
            print(f"[eval] baseline eval failed: {e} (skipping)", flush=True)

    # ---- Write reports ----
    delta = None
    if baseline_ppl is not None:
        delta = model_ppl - baseline_ppl

    summary = {
        "merged_model_dir": args.model_dir,
        "baseline_hf_repo": args.baseline,
        "test_doc_count": len(test_texts),
        "merged_model_ppl": round(model_ppl, 3),
        "baseline_ppl": round(baseline_ppl, 3) if baseline_ppl is not None else None,
        "delta_ppl": round(delta, 3) if delta is not None else None,
        "per_subtopic_ppl": per_subtopic_ppl,
        "per_subtopic_baseline_ppl": per_subtopic_baseline_ppl,
        "per_subtopic_test_counts": {k: len(v) for k, v in by_st.items()},
        "num_samples": len(samples),
    }

    with open(out_dir / "perplexity.json", "w") as f:
        json.dump(summary, f, indent=2)

    # Samples markdown
    with open(out_dir / "samples.md", "w") as f:
        f.write(f"# Sample generations ({len(samples)} prompts)\n\n")
        for i, s in enumerate(samples, 1):
            f.write(f"## {i}. Prompt\n\n> {s['prompt']}\n\n### Response\n\n{s['response']}\n\n---\n\n")
        f.write("\n# Per-subtopic samples\n\n")
        for st in sorted(per_subtopic_samples):
            f.write(f"\n## {st}\n\n")
            for j, s in enumerate(per_subtopic_samples[st], 1):
                f.write(f"### Seed {j}\n\n> {s['prompt']}\n\n**Continuation:** {s['response']}\n\n")

    # Comparison md
    with open(out_dir / "comparison-vs-baseline.md", "w") as f:
        f.write("# Forged model vs. baseline\n\n")
        f.write(f"| metric | merged model | baseline ({args.baseline}) | delta |\n")
        f.write("|---|---|---|---|\n")
        if baseline_ppl is not None:
            f.write(f"| perplexity | {model_ppl:.3f} | {baseline_ppl:.3f} | {delta:+.3f} |\n\n")
            f.write(f"**Lower perplexity is better.** Delta < 0 means forging improved over baseline on domain test split.\n")
        else:
            f.write(f"| perplexity | {model_ppl:.3f} | (baseline skipped) | — |\n")

        # Per-subtopic table
        if per_subtopic_ppl:
            f.write("\n## Per-subtopic perplexity\n\n")
            f.write("| subtopic | n_test | merged ppl | baseline ppl | delta |\n")
            f.write("|---|---|---|---|---|\n")
            for st in sorted(per_subtopic_ppl):
                n = len(by_st[st])
                mp = per_subtopic_ppl[st]
                bp = per_subtopic_baseline_ppl.get(st)
                d_str = f"{(mp - bp):+.3f}" if bp is not None else "—"
                bp_str = f"{bp:.3f}" if bp is not None else "—"
                f.write(f"| {st} | {n} | {mp:.3f} | {bp_str} | {d_str} |\n")
            f.write("\n**Watch:** if any subtopic's merged ppl is *worse* than baseline (delta > 0) while aggregate improved, the model is unevenly trained — likely a data-imbalance signal.\n")

    # Domain bench placeholder
    with open(out_dir / "domain-bench-report.md", "w") as f:
        f.write("# Domain-specific benchmark\n\n")
        f.write("*M5 v1: not yet implemented. Reserved for the domain → eval-set router (dental, legal, code, medical). Falls back to perplexity + samples.*\n")

    print(f"[eval] wrote reports to {out_dir}", flush=True)
    print(json.dumps(summary, indent=2), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
