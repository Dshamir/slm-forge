# forge-quantize — DESIGN.md

> **Status:** M5-prep design doc. Implementation lives in `run.sh`
> when M5 unblocks.

## Phase

`QUANTIZE → REGISTER`. Triggered after QUALITY_GATE approval.

## Inputs read from manifest

- `manifest.artifacts.final_weights_s3` (HF-format weights in `weights/final/`)
- `manifest.plan.{base_model, target_params}` (arch detection for convert_hf_to_gguf.py)
- `manifest.compute_target.{instance_id, workdir}`
- `manifest.spec.constraints.{}` (future: enable AWQ flag)

## Outputs written to manifest

- `s3://forge/<id>/weights/quantized/model-Q4_K_M.gguf`
- `s3://forge/<id>/weights/quantized/model-Q8_0.gguf`
- `s3://forge/<id>/weights/quantized/model-AWQ/` (optional, if enabled)
- `manifest.artifacts.quantized_s3.Q4_K_M`  = S3 URI
- `manifest.artifacts.quantized_s3.Q8_0`    = S3 URI
- `manifest.artifacts.quantized_s3.AWQ`     = S3 URI | null
- Phase advance: `QUANTIZE → REGISTER`

## Dependencies (from forge-bootstrap)

- `/workspace/llama.cpp/` — git-cloned + cmake-built in bootstrap step 4
- `/workspace/llama.cpp/convert_hf_to_gguf.py` — Python script that converts HF safetensors → GGUF base
- `/workspace/llama.cpp/build/bin/llama-quantize` — compiled binary
- `/workspace/llama.cpp/build/bin/llama-cli` — for GGUF sanity-check generation
- `/workspace/.venv/bin/python` — venv with transformers/safetensors (for convert script to load the HF model)

## Procedure

1. **Ensure llama.cpp present.**
   ```
   ssm exec "test -x /workspace/llama.cpp/build/bin/llama-quantize || echo MISSING"
   ```
   If MISSING: re-run the bootstrap llama.cpp step (`bash scripts/bootstrap.sh --just-llama-cpp` — NEW flag). This is the idempotency recovery path.

2. **Download final weights to /workspace/weights/final/** (if not already there from training).

3. **Convert HF → base GGUF.**
   ```
   /workspace/.venv/bin/python /workspace/llama.cpp/convert_hf_to_gguf.py \
     /workspace/weights/final \
     --outtype f16 \
     --outfile /workspace/weights/quantized/model-f16.gguf
   ```
   f16 is the intermediate; quantization operates on it. Architecture auto-detected from `config.json`.

4. **Quantize to targets.**
   ```
   /workspace/llama.cpp/build/bin/llama-quantize \
     /workspace/weights/quantized/model-f16.gguf \
     /workspace/weights/quantized/model-Q4_K_M.gguf \
     Q4_K_M

   /workspace/llama.cpp/build/bin/llama-quantize \
     /workspace/weights/quantized/model-f16.gguf \
     /workspace/weights/quantized/model-Q8_0.gguf \
     Q8_0
   ```
   Per D-009: Q4_K_M (smallest; "demo download" level) + Q8_0 (near-lossless; "serious use" level) are mandatory.

5. **AWQ (optional).** Only when `manifest.spec.constraints.enable_awq = true` (future flag):
   ```
   /workspace/.venv/bin/python -m awq.entry \
     --model /workspace/weights/final \
     --quantize --w_bit 4 --q_group_size 128 \
     --dump_quant /workspace/weights/quantized/model-AWQ
   ```
   Requires `autoawq` package (install conditionally to avoid bloating bootstrap).

6. **Sanity check each GGUF.**
   ```
   /workspace/llama.cpp/build/bin/llama-cli \
     -m /workspace/weights/quantized/model-Q4_K_M.gguf \
     -p "Hello, how are you?" \
     --n-predict 10 --simple-io --temp 0
   ```
   Accept: output contains printable ASCII, non-zero length, not an infinite loop of one token. Reject: gibberish (non-UTF8), empty, or pathological repetition (same token > 8 times). Same check for Q8_0.

7. **Delete the f16 intermediate** (it's huge and not shipped externally):
   ```
   rm /workspace/weights/quantized/model-f16.gguf
   ```

8. **Sync to S3 with tags.**
   ```
   aws s3 cp /workspace/weights/quantized/model-Q4_K_M.gguf \
     s3://forge/<id>/weights/quantized/model-Q4_K_M.gguf \
     --tagging "Project=slm-forge&forge-id=<id>&phase=QUANTIZE&quant=Q4_K_M"
   ```
   Same for Q8_0 and optionally AWQ.

9. **Record file sizes + checksums in manifest.**
   ```json
   "artifacts.quantized_s3": {
     "Q4_K_M": { "uri": "s3://...", "bytes": 142_000_000, "sha256": "abc123..." },
     "Q8_0":   { "uri": "s3://...", "bytes": 260_000_000, "sha256": "def456..." },
     "AWQ":    null
   }
   ```

10. **Return** `{"status":"completed","next_phase":"REGISTER","forge_id":"…","gguf_sizes":{...}}`.

## GGUF size rule-of-thumb (for reporting)

For a P-parameter model:
- f16 (intermediate):  ~2 × P bytes
- Q8_0:                ~1.06 × P bytes (near-lossless)
- Q4_K_M:              ~0.59 × P bytes (good default)
- Q4_0:                ~0.56 × P bytes (not used)
- Q5_K_M:              ~0.70 × P bytes (optional future)

200M-param model: Q4_K_M ≈ 118 MB, Q8_0 ≈ 212 MB.

## Failure modes (return contract)

| Failure | recoverable | recovery_hint |
|---|---|---|
| Architecture not supported by `convert_hf_to_gguf.py` | true | `fall back to AWQ only (if autoawq supports this arch); else flag for llama.cpp upstream PR` |
| llama.cpp missing (/workspace was wiped since bootstrap) | true | `re-run bootstrap.sh to rebuild llama.cpp (idempotent)` |
| Sanity check produces gibberish | true | `retry with a different quant method (try Q5_K_M); if all gguf levels produce gibberish, weights are corrupt — back to MONITOR for resume or ARCHITECT for retrain` |
| Disk full during conversion | true | `forge-provision with larger ebs_gb; the f16 intermediate is ~2× param count in bytes` |
| awq install fails (non-fatal) | true | `skip AWQ, complete Q4_K_M + Q8_0` |

## Idempotency

Check `artifacts.quantized_s3.Q4_K_M` before starting. If already set AND
S3 object exists AND sha256 matches the recorded value, short-circuit.

## CPU vs GPU

llama.cpp quantization runs on CPU. On g5.xlarge the 300M-param quantize
takes ~30-60 sec per level. No GPU is strictly required — forge-quantize
CAN run on a cheaper CPU box if forge-teardown had already stopped the
GPU instance. For M5-v1: run on the same GPU box (no re-provision
gymnastics). M5+ hardening: detect "GPU idle" and offer to downgrade.

## Key references

- `slm-forge-brief/skills/SKILL_SPECS.md § forge-quantize`
- `slm-forge-brief/DECISIONS.md § D-009` (GGUF quant levels)
- `slm-forge-brief/architecture/S3_LAYOUT.md` (weights/quantized/ layout)
