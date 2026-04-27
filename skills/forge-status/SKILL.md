---
name: forge-status
description: SLM-Forge status helper. Read-only inspection of a forge's manifest, phase history, artifacts, cost breakdown, and error log. Use when the user asks "what's the state of my forge?", "how much has this forge cost?", "what phase is forge <id> at?", or invokes /slm-forge status <id>. Never mutates state — safe to call at any time on any forge regardless of phase.
---

# forge-status

Non-phase helper skill. Renders a human-readable status report for a forge
without side effects.

## Trigger patterns

- `/slm-forge status [forge-id]` (forge-id optional; defaults to current-forge pointer)
- "what's the status of `<id>`?"
- "how much has this forge cost?"
- "show me the forge state"

## What it reports

```
=== Forge: forge-2026-04-23-dental-xyz123 =====================
  created:        2026-04-23T14:30:00Z  (by daniel@mercury)
  phase:          TRAIN (in-progress, 2h 15m)
  updated:        2026-04-23T16:45:12Z  (2 min ago)

Spec:
  goal:           train a dental patient-ed SLM on tiny corpus
  domain:         dental.patient-education
  target_params:  200M
  budget_cap:     $10.00
  max_wall:       24h

Plan:
  base_model:     Qwen/Qwen2.5-0.5B  (Apache-2.0)
  regime:         prune-to-300m
  framework:      unsloth
  chat_template:  qwen2

Estimate:
  instance:       g5.xlarge  @ $1.212/hr
  gpu_hours:      6.50  (confidence=medium)
  total_est:      $9.14

Phase history:
  INTAKE          ✓  2m
  ARCHITECT       ✓  30s
  ESTIMATE        ✓  10s
  BUDGET_GATE     ✓  (passed by user)
  SOURCE          ✓  9m
  CURATE          ✓  25m
  SHAPE           ✓  15m
  PROVISION       ✓  4m
  BOOTSTRAP       ✓  14m
  TRAIN           …  2h 15m  (in-progress)

Artifacts:
  raw_corpus:      s3://.../data/raw/
  curated_corpus:  s3://.../data/curated/
  shaped_corpus:   s3://.../data/shaped/
  checkpoints:     s3://.../checkpoints/  (last: step-1200, loss 1.842)
  final_weights:   (not yet)
  eval_reports:    (not yet)
  quantized:       (not yet)
  hf_repo:         (not yet)
  hf_space:        (not yet)

Compute:
  instance:        i-0abc123def456  (running, SSM online)
  launched:        2026-04-23T15:25:00Z  (1h 20m ago)
  ebs_volume:      vol-0xyz789  (200 GB gp3)

Training:
  pid:             14532  (alive)
  last_loss:       1.842 @ step 1250
  last_heartbeat:  1m ago
  eta:             ~45 min

Cost:
  to_date:         $4.23
  by_phase:        PROVISION $0.07, BOOTSTRAP $0.38, TRAIN $3.78
  cap:             $10.00
  headroom:        $5.77

Gates:
  budget_gate:     ✓ passed  (2026-04-23T14:36:30Z, by user)
  quality_gate:    (pending)

Errors:        (none)
Notes:         (none)
```

## Procedure

`skills/forge-status/run.sh <forge-id>` (or no arg → uses current-forge
pointer from `$FORGE_WORK/current-forge.txt`).

1. Load manifest via `manifest_load`.
2. Parse + format the sections above.
3. For cost reconciliation, call `compute_aws_cost_to_date` (fast estimate,
   no Cost Explorer hit — status should be cheap).
4. For training liveness, probe the PID via SSM IF `compute_target.instance_id`
   is live AND `training_runtime.pid` is set (one lightweight SSM exec).
5. Print and exit 0.

## What it doesn't do

- Does NOT mutate the manifest
- Does NOT advance any phase
- Does NOT trigger any sub-skill
- Does NOT spend real AWS money beyond a single `describe-instance` or
  `describe-instance-information` call (for liveness)

## Return contract

Non-phase skill: prints to stdout, exits 0 on success. Does not emit
the `{"status":"completed","next_phase":"..."}` JSON that phase skills do.
