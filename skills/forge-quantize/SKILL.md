---
name: forge-quantize
description: Merges the LoRA adapter into the base model (if regime is lora-sft / qlora-sft), converts HF weights to f16 GGUF via llama.cpp, then quantizes to Q4_K_M and Q8_0. Sanity-loads each GGUF + generates one sample to catch broken builds. Builds llama.cpp on demand if forge-bootstrap's background clone hasn't finished.
---

# forge-quantize

## When this fires

**Phase position: QUANTIZE** — after `forge-eval`, before `forge-register`.
Runs on the same EC2 instance — uses the GPU for the LoRA merge if needed
and the CPU for the GGUF conversion + quantization.

## What it does

1. Verify `manifest.artifacts.final_weights_s3` exists
2. If `regime` is `lora-sft` or `qlora-sft`, merge the adapter into the base
3. Ensure `llama.cpp` is built — falls back to a fresh `git clone + make`
   if `forge-bootstrap`'s background install didn't finish
4. Run `convert_hf_to_gguf.py` to produce f16 GGUF
5. Run `llama-quantize` for **Q4_K_M** (LM Studio / Ollama default)
6. Run `llama-quantize` for **Q8_0** (higher-fidelity option)
7. Sanity-test each: `llama-cli` loads + generates 5 tokens (catches
   convert-time tokenizer breakage)
8. Sync both GGUFs to `s3://.../weights/quantized/`
9. Set `manifest.artifacts.quantized_s3.{Q4_K_M, Q8_0}` and advance to `REGISTER`

## Inputs
- `$1` = forge-id
- `manifest.artifacts.final_weights_s3`
- `manifest.plan.{base_model, regime}`
- `manifest.compute_target.instance_id`

## Outputs
- `s3://.../weights/quantized/model-Q4_K_M.gguf`
- `s3://.../weights/quantized/model-Q8_0.gguf`
- `manifest.artifacts.quantized_s3.{Q4_K_M, Q8_0}` (S3 paths + bytes)
- `manifest.state.current_phase = REGISTER`

## Idempotency
If `manifest.artifacts.quantized_s3.Q4_K_M` is set AND the S3 object
exists, exits 0.

## Failure modes

| Exit | Reason |
|---|---|
| 0  | both GGUFs produced + verified, or already-set |
| 1  | LoRA merge failed OR llama.cpp build failed OR convert/quantize timeout (30 min SSM command default) OR sanity-load produced gibberish |
| 64 | no forge-id provided |

## External resources
- AWS EC2 (SSM RunCommand)
- AWS S3 (read final weights, write GGUFs)
- GitHub (llama.cpp clone — only if bootstrap's background build didn't finish)
- HuggingFace model cache (for the LoRA merge)

## Cost class
**spends GPU time** — LoRA merge uses the GPU briefly; rest is CPU on the
same instance that's still billing hourly.

## Depends on
`forge-monitor` (final weights synced) — `forge-eval` is upstream but
EVAL output is informational; QUANTIZE doesn't read it.
