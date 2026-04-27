# forge-resume — DESIGN.md

> **Status:** M4-prep design doc. Implementation lives in `run.sh`
> when M4 unblocks (gated on quota grant).

## When invoked

`forge-resume` runs:
- After Claude CLI session loss (user re-invokes `/slm-forge` or `/slm-forge resume <id>`)
- After EC2 spot interruption (forge-monitor returns `recoverable: true, instance_terminated`)
- After bootstrap or train crash (forge-monitor returns `recoverable: true`)

It is NOT a phase in the linear state machine — it's a recovery skill
invoked by the master dispatcher when needed.

## Inputs read from manifest

Full manifest. Keys it cares about:
- `manifest.compute_target.{instance_id, ami_id, instance_type, region}`
- `manifest.training_runtime.{pid, last_checkpoint_step, last_checkpoint_s3}`
- `manifest.artifacts.{shaped_corpus_s3, checkpoints_s3}`
- `manifest.plan.*` (for re-launching with same config)
- `manifest.spec.constraints.budget_cap_usd` (for cost-gate before re-provision)

## Outputs written to manifest

Updates `compute_target` if re-provisioned (new instance_id + ec2_launch_time).
Updates `training_runtime` with new pid + log paths.
Always sets phase to MONITOR (re-enters the polling loop).

## State-machine table

The recovery path depends on the state of the original compute target:

| State of original instance | Detection | Recovery action | Cost |
|---|---|---|---|
| **A. Alive + SSM Online** (most common: just session loss) | `compute_aws_reattach` returns 0 | Skip re-provision. Check if `forge-train.pid` is still alive: if yes, jump to MONITOR. If no, restart training from last checkpoint on the same instance. | $0 |
| **B. Stopped, EBS intact** (e.g., user did teardown --stop, then resumed days later) | `describe-instances` shows state=stopped | `start-instances`, wait for running+SSM online, re-attach. Training was killed by stop; restart from last checkpoint. | restart cost ~$0.05 |
| **C. Terminated, EBS deleted** (spot interruption with no snapshot) | `describe-instances` shows state=terminated OR not-found | Re-provision fresh (forge-provision logic), re-bootstrap, restore last checkpoint from S3, restart. | full re-provision + bootstrap (~$0.30) |
| **D. EBS snapshot present but instance gone** (we did snapshot before terminate) | check `manifest.compute_target.ebs_snapshot_id` | Re-provision fresh BUT use snapshot as the root volume — skips bootstrap install. Restore checkpoint, restart. | re-provision (~$0.10), no bootstrap |

## Procedure

1. **Identify state.**
   ```python
   if not compute_target.instance_id:
       state = "C"  # never provisioned or fully torn down
   else:
       inst = describe_instances(instance_id)
       if inst.state in ("running",) and ssm_ping == "Online":
           state = "A"
       elif inst.state == "stopped":
           state = "B"
       elif inst.state in ("terminated", "shutting-down") or inst is None:
           if compute_target.get("ebs_snapshot_id"):
               state = "D"
           else:
               state = "C"
       else:
           state = "wait"  # e.g. pending or stopping; sleep + re-check
   ```

2. **Per-state recovery.**

   **State A (alive):**
   - SSM exec `kill -0 $(cat /workspace/.forge-train.pid)`
   - If alive: write a NOTE to manifest.notes ("session resumed, training was already running"), return `{"status":"completed","next_phase":"MONITOR"}`.
   - If dead: proceed to "restart training" sub-procedure below.

   **State B (stopped):**
   - `aws ec2 start-instances --instance-ids <id>`
   - Wait for running + SSM Online (same poll as forge-provision)
   - Update `compute_target.ec2_launch_time = now()` (cost reset)
   - Proceed to "restart training" sub-procedure.

   **State C (terminated, no snapshot):**
   - Cost-gate: estimated re-provision + bootstrap cost ≤ remaining budget?
     - If no: return `{"status":"failed","recoverable":false,"reason":"would exceed budget; raise budget_cap_usd or abandon"}`.
   - Call compute_aws_provision with same spec → new instance_id
   - Update `compute_target` with new ids + launch_time
   - Run forge-bootstrap (idempotent; full install since /workspace is empty)
   - Restore checkpoint from S3 to `/workspace/checkpoints/latest/`:
     ```
     ssm exec "aws s3 sync s3://forge/<id>/checkpoints/step-<N>/ /workspace/checkpoints/latest/"
     ```
   - Proceed to "restart training" sub-procedure.

   **State D (snapshot available):**
   - Cost-gate as in C.
   - Provision new instance with `--block-device-mappings ... SnapshotId=<id>` — skips fresh bootstrap.
   - Verify /workspace exists + sentinel `/workspace/.forge-bootstrap-complete` present.
   - Restore checkpoint (same as C).
   - Restart training.

3. **"Restart training" sub-procedure (used by A-dead, B, C, D):**
   - Load existing training config from `s3://forge/<id>/training/config.yaml`.
   - Patch `resume.from_checkpoint = "/workspace/checkpoints/latest"` (or the highest step-N path).
   - Re-upload to instance.
   - Launch `train.py --config ...` detached (same launcher pattern as forge-train).
   - Capture new PID, update `training_runtime.{pid, log_path_*, started_at}`.
   - Health probe (30 sec) — same as forge-train.

4. **Return.** `{"status":"completed","next_phase":"MONITOR","forge_id":"…","resume_state":"A|B|C|D","new_pid":<int>}`.

## Failure modes

| Failure | recoverable | recovery_hint |
|---|---|---|
| No checkpoint in S3 (state C, training never reached save_steps) | false | `training lost, must restart from PROVISION; consider amending plan to checkpoint earlier` |
| Re-provision fails quota | true | `wait + retry, or amend plan to smaller instance` |
| Restored checkpoint corrupt | true | `try previous checkpoint (last_checkpoint_step - save_steps)` |
| SSM never recovers on state-B start | true | `force-stop + force-start; if still bad, treat as state C` |
| Cost-gate fails | false | `surface to user: raise budget_cap_usd or invoke /slm-forge abort` |

## Idempotency

Re-running forge-resume on a state-A forge (training healthy) is a no-op
that just writes a heartbeat note and returns. No duplicate launches.

## Key references

- `slm-forge-brief/skills/SKILL_SPECS.md § forge-resume`
- `slm-forge-brief/architecture/COMPUTE_TARGET.md § Failure modes` (3 explicit modes)
- `slm-forge-brief/architecture/PHASE_TABLE.md § Backward transitions`
