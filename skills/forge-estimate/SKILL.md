---
name: forge-estimate
description: Computes GPU hours, instance type, hourly rate, total cost, and wall-clock projection for the planned training run. Reads manifest.plan + manifest.spec.constraints + config/pricing.json (the ca-central-1 GPU rate snapshot). Output gates the BUDGET_GATE (rolled into PLAN_GATE in v2).
---

# forge-estimate

## When this fires

**Phase position: ESTIMATE** — after `forge-architect`, before `forge-provision`.
The output funds the cost-cap check that `forge-provision` makes against
`spec.constraints.budget_cap_usd`.

## What it does

1. Look up the recommended instance type for `plan.target_params` + `plan.regime`
2. Estimate GPU-hours using regime-specific heuristics (lora-sft → fewer
   hours per token than full-sft; qlora-sft → larger model fits but
   throughput is lower)
3. Multiply by the cached hourly rate from `config/pricing.json`
4. Add storage + transfer assumptions (small for the M2 size class)
5. Write `manifest.estimate.*` with a `confidence` band + `assumptions[]`
6. Advance state to `BUDGET_GATE` (legacy) — the v2 gate is `PLAN_GATE`

## Inputs
- `$1` = forge-id
- `manifest.plan` (base_model, regime, target_params)
- `manifest.spec.constraints` (budget_cap_usd, max_wall_clock_hours)
- `config/pricing.json` (ca-central-1 GPU instance rate snapshot)

## Outputs
- `manifest.estimate.{gpu_hours, instance_type, cost_per_hour_usd, total_cost_usd, wall_clock_hours, confidence, assumptions}`
- `manifest.state.current_phase = BUDGET_GATE`

## Idempotency
If `manifest.estimate` is already populated, exits 0.

## Failure modes

| Exit | Reason |
|---|---|
| 0  | estimate written or already-set |
| 1  | `config/pricing.json` missing or unreadable |
| 64 | no forge-id provided |

## External resources
- Local disk only — `config/pricing.json` lookup

## Cost class
**free** — pure arithmetic.

## Depends on
- `forge-architect` (populated `manifest.plan`)
- `forge-shape` is *optional* but refines the token estimate when run
  before this; without it the estimate uses a coarse corpus-size proxy.
