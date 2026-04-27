---
name: forge-register
description: Publishes the forged model to HuggingFace as a model repo (weights + GGUFs + vendor-neutral model card) AND a Gradio Space (browser demo) AND an Ollama Modelfile (terminal). Repos are PRIVATE by default — forge-publish flips them public after card-validator + smoketest pass. D-018 vendor-neutral check rejects NEXLESS / MGMO / SIF branding leaks before upload.
---

# forge-register

## When this fires

**Phase position: REGISTER** — after `forge-quantize`, before `forge-card-validator`.
Runs **locally** (on the operator's host, not on EC2) — pure HF API
work, no GPU needed. Downloads release assets from S3 first.

## What it does

1. Read `HF_TOKEN` (env or `.env` via vault-client pattern)
2. Render the model card from `templates/model-card.md.tmpl` — substitutes
   plan + spec + eval-report values. **D-018 vendor-neutral check**:
   grep for NEXLESS / MGMO / SIF / Anthropic-internal branding and
   refuse to upload if any leaks.
3. Create the HF model repo as **private**
4. Download merged weights + Q4_K_M + Q8_0 GGUFs + eval reports from S3
   into a local staging dir
5. Upload everything to the HF model repo (model card, weights, GGUFs, eval/)
6. Render `app.py` from `templates/space-app.py.tmpl`, create the HF Space
   (Gradio ChatInterface), upload `app.py` + `requirements.txt`
7. Render the Ollama `Modelfile` from the right template
   (`ollama-modelfile.{chatml,llama-3,phi-3,qwen2}.tmpl` based on `plan.chat_template`)
8. Set `manifest.artifacts.{hf_repo, hf_space, model_card_s3}` and advance to `TEARDOWN`

## Inputs
- `$1` = forge-id
- `HF_TOKEN` env (or `.env`) — write-scoped fineGrained token
- `manifest.plan` + `manifest.spec` + `manifest.artifacts.*`

## Outputs
- HF model repo (private; weights + GGUFs + model card + eval reports)
- HF Space (private; Gradio ChatInterface)
- Local + S3 `release/` staging dir (Modelfile, README, etc.)
- `manifest.artifacts.{hf_repo, hf_space, model_card_s3}`
- `manifest.state.current_phase = TEARDOWN`

## Idempotency
If `manifest.artifacts.hf_repo` is set, exits 0.

## Failure modes

| Exit | Reason |
|---|---|
| 0  | published or already-set |
| 1  | `HF_TOKEN` missing OR D-018 vendor-neutral check failed (branding leak detected — refuses to upload). HF API errors are retried. |
| 64 | no forge-id provided |

## External resources
- HuggingFace API (model repo + Space create / upload)
- AWS S3 (download release assets)
- Local docker (huggingface-cli runs in a container)
- Local disk (release staging)

## Cost class
**free** — HF bandwidth is free at this size class.

## Depends on
- `forge-quantize` (Q4_K_M GGUF required for the model repo)
- `forge-eval` (reports optional but preferred — model card cites them)
