#!/usr/bin/env python3
"""
slm-forge/scripts/merge-adapter.py — merge a LoRA adapter into its base
model and save as a standalone HF-format model (ready for quantization).

Input:  --adapter <path>  directory with adapter_model.safetensors + adapter_config.json
Input:  --base <hf-repo>  base model id (must match plan.base_model)
Output: --out <path>      directory to write the merged model
        (config.json, model.safetensors, tokenizer files)

This is the canonical "lora-sft → distributable model" bridge. After
forge-monitor syncs adapter weights to /workspace/checkpoints/final/,
forge-quantize invokes this merge before running llama.cpp.

Exit codes:
  0  merge success
  2  adapter or base load failure
  3  merge conflict (mismatched target_modules etc.)
  4  output disk full
"""
from __future__ import annotations
import argparse
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--adapter", required=True, help="adapter directory (with adapter_config.json)")
    ap.add_argument("--base", required=True, help="base model HF repo id")
    ap.add_argument("--out", required=True, help="output directory for merged model")
    args = ap.parse_args()

    adapter_dir = Path(args.adapter)
    out_dir = Path(args.out)

    if not (adapter_dir / "adapter_config.json").exists():
        sys.stderr.write(f"merge-adapter: {adapter_dir}/adapter_config.json missing\n")
        return 2
    out_dir.mkdir(parents=True, exist_ok=True)

    try:
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer
        from peft import PeftModel
    except ImportError as e:
        sys.stderr.write(f"merge-adapter: missing deps: {e}\n")
        return 2

    # Load in bf16 — fp32 needs 4 bytes × 7B = 28 GB just for weights, OOM-kills
    # the merge on g5.2xlarge (32 GB RAM). bf16 cuts it to 14 GB; PEFT + merge
    # peaks at ~18 GB. Quantize converts to GGUF afterward so dtype here doesn't
    # affect final output precision (Q4_K_M / Q8_0 are llama.cpp-defined).
    print(f"[merge] loading base model: {args.base} (dtype=bf16)", flush=True)
    base = AutoModelForCausalLM.from_pretrained(args.base, torch_dtype=torch.bfloat16)

    print(f"[merge] loading adapter: {adapter_dir}", flush=True)
    peft_model = PeftModel.from_pretrained(base, str(adapter_dir))

    print("[merge] merging adapter into base (merge_and_unload)...", flush=True)
    merged = peft_model.merge_and_unload()

    print(f"[merge] saving merged model to {out_dir}", flush=True)
    try:
        merged.save_pretrained(str(out_dir), safe_serialization=True)
    except OSError as e:
        if "No space left on device" in str(e):
            sys.stderr.write(f"merge-adapter: disk full at {out_dir}\n")
            return 4
        raise

    # Copy tokenizer too (adapter dir usually has it; fall back to base)
    tokenizer_src = adapter_dir
    if not (adapter_dir / "tokenizer_config.json").exists():
        tokenizer_src = args.base
    print(f"[merge] saving tokenizer from {tokenizer_src}", flush=True)
    tokenizer = AutoTokenizer.from_pretrained(str(tokenizer_src) if isinstance(tokenizer_src, Path) else tokenizer_src)
    tokenizer.save_pretrained(str(out_dir))

    # Quick sanity: confirm config.json + model.safetensors are present
    if not (out_dir / "config.json").exists():
        sys.stderr.write(f"merge-adapter: {out_dir}/config.json missing after save\n")
        return 3
    model_files = list(out_dir.glob("*.safetensors"))
    if not model_files:
        sys.stderr.write(f"merge-adapter: no .safetensors in {out_dir}\n")
        return 3

    total_bytes = sum(f.stat().st_size for f in model_files)
    print(f"[merge] DONE — {len(model_files)} safetensors file(s), {total_bytes/1e6:.1f} MB total", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
