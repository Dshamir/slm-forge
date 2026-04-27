---
name: forge-train
description: Generates a training config YAML from manifest.plan + plan.json training_overrides, uploads to the EC2 instance, launches train.py detached via setsid + nohup, captures PID, and starts a 30-second log-sync side process to S3. Returns immediately — never blocks. Strips the v2- prefix from FORGE_ID so v2-bridged runs find the right plan.json.
---

# forge-train

## When this fires

**Phase position: TRAIN** — after `forge-bootstrap`, before `forge-monitor`.
**Spends GPU time** — main training spend.

## What it does

1. Resolve plan.json (strip `v2-` prefix from FORGE_ID for v2-bridged runs)
2. Layer hyperparams: defaults → plan.json `training_overrides` → `FORGE_TRAIN_*` env vars
3. Generate the training config YAML (frameworks: unsloth or huggingface-trainer)
4. Upload config + dataset references to `/workspace/` on the instance via SSM
5. Launch `nohup setsid python train.py ...` detached → capture PID
6. Spawn a side process that `aws s3 sync` the log file every 30 s
7. 30 s health probe — if PID is dead by now, fail fast (early crash)
8. Write `manifest.training_runtime.*` and advance to `MONITOR`

## Inputs
- `$1` = forge-id (or `v2-<run-id>`)
- `manifest.plan.{base_model, regime, target_params, framework}`
- `manifest.artifacts.shaped_corpus_s3`
- `plan.json.training_overrides` (v2 bridge — max_steps, batch, lora_r, etc.)
- `FORGE_TRAIN_*` env vars (highest precedence overrides)

## Outputs
- `manifest.training_runtime.{pid, log_path_s3, config_yaml_s3, framework, started_at}`
- `/workspace/logs/train.log` (synced every 30 s)
- `manifest.state.current_phase = MONITOR`

## Idempotency
If `training_runtime.pid` is set AND alive on the instance, exits 0.

## Failure modes

| Exit | Reason | Recoverable? |
|---|---|---|
| 0  | training launched + PID alive | – |
| 1  | config validation failed (non-recoverable: bad plan) OR PID died within 30 s health probe (often OOM — recoverable via batch-size shrink) | mixed |
| 64 | no forge-id provided | no |

## External resources
- AWS EC2 (SSM RunCommand for setsid launch + log-sync rsync)
- AWS S3 (config + log uploads)
- HuggingFace model cache (instance pulls base model on first step)

## Cost class
**spends GPU time** — main training spend window opens here.

## Depends on
- `forge-bootstrap` (venv + deps installed)
- `forge-shape` (shaped corpus in S3)
