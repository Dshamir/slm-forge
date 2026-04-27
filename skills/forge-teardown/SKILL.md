---
name: forge-teardown
description: Terminates (default) or stops (--stop) the EC2 instance and reconciles actual cost via AWS Cost Explorer (with a fast-estimate fallback when CE lag exceeds 8h). Clears compute_target. Terminal phase — also fired on /abort to kill a runaway forge before completion.
---

# forge-teardown

## When this fires

**Phase position: TEARDOWN** — terminal phase, after `forge-register` (or
`forge-publish` in v2). Also fired by the dispatcher's on_failure handler
on any phase failure that left an instance live, AND by manual `/abort`.

## What it does

1. If `manifest.compute_target.instance_id` is unset, exit 0 (already torn down)
2. Call `aws ec2 terminate-instances` (or `stop-instances` when `--stop`)
3. Poll until state is `terminated` (or `stopped`) — 60s timeout
4. **Cost reconciliation** — try AWS Cost Explorer filtered by the forge's
   tag for the authoritative number; if CE is still lagging (8-24 h
   typical), fall back to `(now − ec2_launch_time) × cost_per_hour_usd`
5. Update `manifest.cost_tracking.{cost_to_date_usd, cost_by_phase_usd, last_reconciled_at, reconciliation_source}`
6. Clear `manifest.compute_target = null`
7. Set `manifest.state.current_phase = DONE`

## Inputs
- `$1` = forge-id
- `--terminate` (default) | `--stop` (preserves EBS for later resume)
- `manifest.compute_target.{instance_id, ec2_launch_time, cost_per_hour_usd}`

## Outputs
- `manifest.cost_tracking.{cost_to_date_usd, cost_by_phase_usd, last_reconciled_at, reconciliation_source}`
- `manifest.compute_target = null`
- `manifest.state.current_phase = DONE`

## Idempotency
If `manifest.compute_target.instance_id` is already null, exits 0 — safe
to invoke multiple times.

## Failure modes

| Exit | Reason |
|---|---|
| 0  | terminated + cost reconciled (or already torn down) |
| 1  | EC2 state confirmation timed out (best-effort; instance is still terminating in the background — non-fatal) |
| 64 | no forge-id provided |

A Cost Explorer lag is **non-fatal** — fast-estimate is recorded with
`reconciliation_source: "ec2-uptime-fast-estimate"` so the operator knows
to re-reconcile later. There's no automatic re-reconciliation skill yet;
operators can re-run teardown on a torn-down forge to refresh the CE pull.

## External resources
- AWS EC2 (TerminateInstances / StopInstances + DescribeInstances)
- AWS Cost Explorer (GetCostAndUsage filtered by tag)

## Cost class
**free** — teardown itself costs nothing; only stops the hourly meter.

## Depends on
Only relevant if a prior phase reached `PROVISION` (otherwise no instance
exists). Safe to invoke on a forge that never spent money — just no-ops.
