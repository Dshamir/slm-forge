# 🛑 FORGE FAILED — 20260425-163412-4b31

**Failed phase:** `smoketest`
**Exit code:** 1
**Time:** 2026-04-26T18:33:43Z

## Completed phases
- `prep`
- `audit`
- `synth`
- `shape`
- `plan_fit`
- `provision`
- `bootstrap`
- `train`
- `monitor`
- `eval`
- `quantize`
- `register`
- `card_validator`

## What to do
- Review the tail of `slm-forge/scripts/../../slm-forge/.runs/20260425-163412-4b31/dispatch.log` for error detail
- If the failure was transient (AWS capacity, network), re-run:
    `bash slm-forge/scripts/dispatch-v2.sh 20260425-163412-4b31`
  Dispatcher is idempotent — completed phases skip automatically.
- If structural (plan error, corpus problem), fix input + regenerate plan.

## State snapshot
```json
{
  "run_id": "20260425-163412-4b31",
  "started_at": "2026-04-25T17:52:57Z",
  "current_phase": "smoketest",
  "completed_phases": [
    "prep",
    "audit",
    "synth",
    "shape",
    "plan_fit",
    "provision",
    "bootstrap",
    "train",
    "monitor",
    "eval",
    "quantize",
    "register",
    "card_validator"
  ],
  "failed_phases": [
    {
      "phase": "smoketest",
      "rc": 1,
      "at": "2026-04-26T18:33:43Z"
    }
  ],
  "instance_id": null,
  "artifacts": {
    "hf_repo": "https://huggingface.co/Nexless/dental-research-slm-0m-20260426-4b31",
    "hf_space": "https://huggingface.co/spaces/Nexless/dental-research-slm-0m-20260426-4b31-demo"
  },
  "total_cost_usd": 0,
  "forge_id": "v2-20260425-163412-4b31",
  "hf_repo": "https://huggingface.co/Nexless/dental-research-slm-0m-20260426-4b31",
  "hf_space": "https://huggingface.co/spaces/Nexless/dental-research-slm-0m-20260426-4b31-demo"
}
```
