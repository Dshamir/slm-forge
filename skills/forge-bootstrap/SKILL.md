---
name: forge-bootstrap
description: Installs the training stack on a freshly-provisioned EC2 instance — Python venv, Torch with matching CUDA, transformers + peft + datasets + accelerate, and (in the background) llama.cpp so the build is ready by the time TRAIN finishes. Drops a sentinel file so re-runs skip cleanly. 30-minute SSM-command timeout by default.
---

# forge-bootstrap

## When this fires

**Phase position: BOOTSTRAP** — after `forge-provision`, before `forge-train`.
Runs entirely on the EC2 instance via SSM RunCommand.

## What it does

1. Verify `manifest.compute_target.instance_id` is `Online` in SSM
2. Upload `scripts/bootstrap.sh` to the instance and execute it
3. Inside the instance: mount the EBS, create the Python venv, install
   torch + transformers + peft + datasets + accelerate + bitsandbytes
4. **In the background**, start cloning + building `llama.cpp` so it's
   ready when QUANTIZE fires (overlaps with TRAIN to save wall-clock)
5. Drop `/workspace/.forge-bootstrap-complete` sentinel
6. Sync bootstrap logs to S3
7. Set `manifest.compute_target.bootstrap_completed = true` and advance to `TRAIN`

## Inputs
- `$1` = forge-id
- `manifest.compute_target.instance_id`
- `scripts/bootstrap.sh` (uploaded to the instance)
- `FORGE_BOOTSTRAP_TIMEOUT_SEC` (env, default 1800)

## Outputs
- `/workspace/.forge-bootstrap-complete` (sentinel on the instance)
- `s3://.../logs/bootstrap.log`
- `manifest.compute_target.bootstrap_completed = true`
- `manifest.state.current_phase = TRAIN`

## Idempotency
If `manifest.compute_target.bootstrap_completed == true`, exits 0.
The bootstrap script itself is also idempotent (re-running on a
half-installed instance picks up where it left off).

## Failure modes

| Exit | Reason |
|---|---|
| 0  | sentinel exists or already-set |
| 1  | SSM command timeout OR sentinel never created. Errors logged with `recoverable=true` so `forge-resume` can re-attempt. llama.cpp clone failure is **non-fatal** (background). |
| 64 | no forge-id provided |

## External resources
- AWS EC2 + SSM (RunCommand)
- AWS S3 (log sync)
- GitHub (llama.cpp clone — background, non-fatal)

## Cost class
**spends GPU time** — instance is already running and billing.

## Depends on
`forge-provision` (instance live + SSM Online)
