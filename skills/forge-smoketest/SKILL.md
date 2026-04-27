---
name: forge-smoketest
description: Live API call to the freshly-registered HF Space. Verifies the model is serving and produces a non-degenerate response to a canonical probe prompt. Blocks forge-publish if the Space can't be reached OR the response shows degeneration patterns (triple-word, run-together tokens, paragraph loops).
---

# forge-smoketest

## When this fires

**Phase position: SMOKETEST** — between CARD_VALIDATOR and PUBLISH. The last automated check before the model goes public.

## What it does

1. Reads `hf_space` URL from state/manifest
2. Polls `https://huggingface.co/api/spaces/<id>` for `runtime.stage == RUNNING` (up to 8 min)
3. Verifies `<subdomain>.hf.space/` returns HTTP 200
4. Sends probe prompt to Gradio `/run/predict`:
   ```json
   {"data": ["What is a dental crown?"]}
   ```
5. Parses response and runs degeneration-pattern checks:
   - too short (< 30 chars)
   - triple-word repetition (`\b(\w+)\s+\1\s+\1\b`)
   - paragraph-level loops (same 40+ char substring repeated 3+ times)
   - GGUF detokenize artifacts (`ttiuser`, `ttiassistant`)
6. Falls back to homepage-only check if `/run/predict` isn't reachable (custom endpoint / auth required)

## Inputs
- Reads `slm-forge/.runs/<run-id>/state.json` for `hf_space` URL
- Needs `HF_TOKEN` for private Space access during the gate (Space is still private at this phase)

## Outputs
- Writes `slm-forge/.runs/<run-id>/smoketest-report.json`:
  ```json
  {"status":"pass","url":"https://...","prompt":"...","response_preview":"..."}
  ```
- On fail: exit 1, PUBLISH never runs, repos stay private

## Failure modes

| Failure | Typical cause | Recovery |
|---|---|---|
| Space never reached RUNNING | Build failure, bad `requirements.txt`, sdk_version mismatch | Check Space build log on HF; fix template; re-register |
| HTTP 200 but empty response | Model died loading GGUF; llama-cpp-python crash | Check Space runtime log |
| Degenerate response | Sampling params wrong OR model genuinely bad | Review plan-fit axis 3 score; consider re-forging with stronger prompt |

## Usage
```bash
bash slm-forge/skills/forge-smoketest/run.sh <run-id>
```
