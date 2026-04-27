---
name: forge-provision
description: Launches an EC2 GPU instance matching manifest.estimate.instance_type. Cost-gates against spec.constraints.budget_cap_usd before calling RunInstances. Auto-retries across availability zones on InsufficientInstanceCapacity. ca-central-1 pinned; SLMForgeInstanceRole profile attached so the instance can pull from S3 + write checkpoints back.
---

# forge-provision

## When this fires

**Phase position: PROVISION** — after `forge-shape` (or `forge-plan-fit`
in v2), before `forge-bootstrap`. **Spends GPU time** — first phase
that actually charges AWS.

## What it does

1. Read `manifest.estimate.{instance_type, total_cost_usd}` and
   `manifest.spec.constraints.budget_cap_usd`
2. Cost-gate: refuse if `cost_to_date + projected > budget_cap` (D-017)
3. Look up Deep Learning AMI ID (pinned in `lib/compute_aws.sh`)
4. Call `RunInstances` with: gp3 EBS (default 200 GB), `SLMForgeInstanceRole`
   instance profile, capacity-tagged for cost tracking
5. On `InsufficientInstanceCapacity`, retry across the other AZs in ca-central-1
6. Poll until SSM agent reports `Online`
7. Write `manifest.compute_target.*` and advance to `BOOTSTRAP`

## Inputs
- `$1` = forge-id
- `manifest.estimate.instance_type`
- `manifest.spec.constraints.budget_cap_usd`
- `manifest.cost_tracking.cost_to_date_usd`

## Outputs
- `manifest.compute_target.{provider:"aws", region:"ca-central-1", instance_id, ami_id, ec2_launch_time, cost_per_hour_usd}`
- `manifest.state.current_phase = BOOTSTRAP`

## Idempotency
If `compute_target.instance_id` is set AND SSM reports `Online`, exits 0.

## Failure modes

| Exit | Reason |
|---|---|
| 0  | instance running + SSM online |
| 1  | projected cost > budget cap (hard gate per D-017); EC2 RunInstances API error in every AZ; SSM never came online within timeout |
| 64 | no forge-id provided |

## External resources
- AWS EC2 (RunInstances + DescribeInstances)
- AWS SSM (wait for Online)

## Cost class
**spends GPU time** — hourly billing starts the moment the instance enters `running`.

## Depends on
`forge-estimate` (must have `instance_type` + cost projection)
