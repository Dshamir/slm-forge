---
name: forge-resume
description: Recovery helper (NOT a phase). Re-enters a forge after a spot interrupt, EC2 stop, or training crash. Inspects the instance state (alive / stopped / terminated), takes the appropriate recovery path, restores the last checkpoint from S3, and hands control back to MONITOR. Cost-gates re-provisioning against the original budget cap.
---

# forge-resume

## When this fires

**Helper, not a phase.** Invoked manually by the operator (`/slm-forge-resume <forge-id>`)
OR by the dispatcher's on_failure when a recoverable phase dies.
Returns control to `MONITOR` after recovery.

## What it does — three-state recovery matrix

| State | Trigger | Recovery path |
|---|---|---|
| **A: alive** | `DescribeInstances` returns `running` AND SSM Online AND PID alive | No-op — return to `MONITOR` |
| **B: stopped (EBS intact)** | Instance state `stopped` (EBS not lost) | `StartInstances` → wait for SSM → restart `train.py` with `--resume_from_checkpoint <last>` |
| **C: terminated** | Instance state missing or `terminated` | Cost-gate vs `cost_to_date + estimate.remaining`; re-provision + re-bootstrap + restore `last_checkpoint_s3` to `/workspace/checkpoints/latest/` + relaunch with `--resume_from_checkpoint` |

After any recovery path, advances `current_phase = MONITOR`.

## Inputs
- `$1` = forge-id
- `manifest.compute_target.instance_id`
- `manifest.training_runtime.{pid, last_checkpoint_s3}`
- `manifest.spec.constraints.budget_cap_usd`

## Outputs
- Updated `manifest.compute_target.*` (new instance_id if state C)
- Updated `manifest.training_runtime.{pid, restarted_at, resume_count}`
- `manifest.state.current_phase = MONITOR`

## Idempotency
Re-running on a state-A run is a no-op. State B / C re-runs are safe
because the checkpoint restore path uses `aws s3 sync` (resumable).

## Failure modes

| Exit | Reason | Recoverable? |
|---|---|---|
| 0  | recovered to MONITOR | – |
| 1  | state C with no checkpoint synced (training lost — must restart from scratch) OR cost gate exceeded on re-provision | mixed |
| 64 | no forge-id provided | no |

## External resources
- AWS EC2 (DescribeInstances, StartInstances, RunInstances)
- AWS SSM (RunCommand)
- AWS S3 (restore checkpoint)

## Cost class
**spends GPU time** — re-provisioning starts a fresh hourly meter.
Cost-gated against the original budget so a runaway recovery loop can't
silently overshoot.

## Depends on
The forge must have at least reached `BOOTSTRAP` (so `compute_target`
exists). Without `last_checkpoint_s3`, state C recovery cannot rebuild
the training state and the operator must restart from scratch.
