---
name: forge-monitor
description: Single-shot poll of the running training job — checks PID liveness via SSM, parses loss + step from the last 200 lines of train.log, syncs newly-completed checkpoints to S3, computes ETA. Returns in-progress / completed / failed; dispatch-v2 re-invokes on a 120s interval until terminal. 60s silent-OOM detector hard-fails on stuck launches.
---

# forge-monitor

## When this fires

**Phase position: MONITOR** — after `forge-train`. dispatch-v2 polls
this skill on a 120-second interval (configurable via
`FORGE_MONITOR_POLL_SECONDS`) until it returns terminal status.

## What it does

Each invocation is **stateless and single-shot**:

1. `ssm exec "ps -p $PID"` to check PID liveness on the instance
2. Read tail (200 lines) of `/workspace/logs/train.log` via SSM
3. Parse the last loss + step — also detect "no progress" (PID alive
   but loss/step unchanged for > 60 s → silent OOM / hang → **fail**)
4. Detect new checkpoints under `/workspace/checkpoints/` and trigger
   async `aws s3 sync` to `s3://.../checkpoints/`
5. Compute ETA = (max_steps − current_step) × seconds_per_step
6. Update `manifest.training_runtime` heartbeat fields
7. Decision matrix:
   - **alive + no final-weights yet** → return `in-progress` (dispatcher loops)
   - **dead + final weights synced** → return `completed`, advance to `EVAL`
   - **dead + no final weights** → return `failed` (recoverable via `forge-resume`)

## Inputs
- `$1` = forge-id
- `manifest.training_runtime.{pid, instance_id}`
- Remote `/workspace/logs/train.log`

## Outputs
- `manifest.training_runtime.{last_loss, last_step, eta_minutes, last_checkpoint_step, last_heartbeat}`
- On completion: `manifest.artifacts.{final_weights_s3, checkpoints_s3}`
- On completion: `manifest.state.current_phase = EVAL`

## Idempotency
Stateless — each call is a fresh poll. Safe to invoke any number of times.

## Failure modes

| Exit | Reason | Recoverable? |
|---|---|---|
| 0  | in-progress OR completed cleanly | – |
| 1  | PID alive 60+ s with no loss/step movement (silent OOM/hang) OR PID dead without final weights (training crashed) | yes — try `forge-resume` |
| 64 | no forge-id provided | no |

## External resources
- AWS EC2 (SSM RunCommand for `ps`, `tail`, `ls`)
- AWS S3 (sync checkpoints + final weights)

## Cost class
**spends GPU time** — instance is still running and billing.

## Depends on
`forge-train` (PID + log path required)
