# forge-monitor — DESIGN.md

> **Status:** M4-prep design doc. Implementation lives in `run.sh`
> when M4 unblocks (gated on quota grant).

## Phase

`MONITOR → MONITOR | EVAL`. Loop phase. The master dispatcher re-invokes
this skill until it returns either `next_phase: EVAL` (training done) or
`status: failed`.

## Inputs read from manifest

- `manifest.training_runtime.{pid, log_path_remote, log_path_s3, started_at, last_loss, last_loss_step, last_checkpoint_step}`
- `manifest.compute_target.{instance_id}`
- `manifest.spec.constraints.{max_wall_clock_hours}`
- `manifest.plan.{target_train_steps}` (computed by build-train-config from epochs × batches)

## Outputs written to manifest

Per-poll heartbeat updates:
- `training_runtime.last_loss`
- `training_runtime.last_loss_step`
- `training_runtime.last_heartbeat`
- `training_runtime.eta_remaining_minutes`
- `training_runtime.last_checkpoint_step` (when a new checkpoint appears)
- `training_runtime.last_checkpoint_s3` (when a new checkpoint syncs)
- `metadata/training-curves.json` (S3, parsed loss series)

On completion:
- `artifacts.final_weights_s3`
- `artifacts.checkpoints_s3`
- Phase advance: `MONITOR → EVAL`

## Procedure

1. **Liveness probe.**
   ```
   ssm exec "kill -0 $(cat /workspace/.forge-train.pid) && echo alive || echo dead"
   ```
   Capture `alive | dead`.

2. **Pull log tail.**
   - Try S3 first (cheap): `aws s3 cp s3://forge/<id>/logs/train.log -` then `tail -200`.
   - If S3 lag > 60 sec, fall back to SSM exec `tail -200 /workspace/logs/train.log`.

3. **Parse loss + step from tail.** Both Unsloth and HF Trainer print one line per `logging_steps` interval. Common shapes:
   - HF Trainer: `{'loss': 1.234, 'grad_norm': 0.5, 'learning_rate': 0.0002, 'epoch': 0.12}`
   - Unsloth:   `{'step': 250, 'loss': 1.234, 'lr': 0.0002}`
   - Regex:     `'(?:^|[^a-z])(?:loss|train_loss)['"]?\s*[:=]\s*([0-9]+\.[0-9]+)'` AND `'(?:step|global_step)['"]?\s*[:=]\s*([0-9]+)'`
   - Take the LAST matching pair from the tail.

4. **Append to training-curves.json.**
   - Pull current curves from S3 (may be empty).
   - Append `{step, loss, ts}` if step > last_seen_step.
   - Push back.

5. **Checkpoint sync.**
   - List `/workspace/checkpoints/` via SSM.
   - For any `step-<N>/` dir not in `last_checkpoint_step`, trigger `aws s3 sync /workspace/checkpoints/step-<N>/ s3://forge/<id>/checkpoints/step-<N>/`.
   - Update `last_checkpoint_step` + `last_checkpoint_s3` to the highest synced step.
   - Apply retention: keep only `last 3 + final` per S3_LAYOUT.md.

6. **ETA computation.**
   - If `target_train_steps` known and 2+ recent loss-step samples in curves:
     - Linear: `eta_min = (target - current_step) / (current_step / elapsed_min)`
     - Sub-linear adjustment: typical training has ~10% slowdown in second half (warmup tax + LR decay) — multiply by 1.10 for honesty.
   - Else: `eta_remaining_minutes = null`.

7. **Decision matrix.**
   - **PID alive AND step < target**: heartbeat update, return `{"status":"in-progress","next_phase":"MONITOR"}`. Master re-invokes after sleep.
   - **PID alive AND step == target**: training in shutdown phase. Wait one more poll.
   - **PID dead AND log shows clean exit (e.g., 'Training completed' / 'Saved final checkpoint')**: success path:
     - `aws s3 sync /workspace/checkpoints/final/ s3://forge/<id>/weights/final/`
     - Set `artifacts.final_weights_s3`
     - Phase advance: MONITOR → EVAL
     - Return `{"status":"completed","next_phase":"EVAL"}`
   - **PID dead AND log shows crash (Traceback / OOM / CUDA error)**: failure:
     - Return `{"status":"failed","recoverable":true,"recovery_hint":"forge-resume; common cause from log: <extracted line>"}`
   - **PID dead AND no clear signal in log**: ambiguous — return failed/recoverable with hint to inspect log manually.

8. **Wall-clock budget check.** If elapsed > spec.constraints.max_wall_clock_hours, log warning to manifest.notes (do NOT auto-kill — that's user's call).

## Idempotency

Each invocation writes the heartbeat fields with current values. Re-running
with identical state produces identical result (no side effects beyond
S3 syncs which are themselves idempotent).

## Failure modes (return contract)

| Failure | recoverable | recovery_hint |
|---|---|---|
| PID dead, log shows OOM | true | `forge-architect amend smaller batch; forge-resume` |
| PID dead, log shows CUDA error | true | `re-bootstrap (CUDA driver mismatch); forge-resume` |
| PID dead, no clean exit + no crash | true | `inspect log s3://...logs/train.log manually; if salvageable, forge-resume` |
| SSM unresponsive (instance hang) | true | `wait 5 min; if still down, forge-resume re-provisions` |
| S3 sync lag > 5 min behind log | true | (informational; tail via SSM as fallback) |

## Master dispatcher coupling

Per PHASE_TABLE.md, when MONITOR returns `in-progress, next_phase=MONITOR`:
- Master prints heartbeat summary (loss, step, ETA)
- Asks user: wait & re-poll, or exit (resume later via /slm-forge resume <id>)
- If wait: sleep MONITOR_INTERVAL (default 60 sec), re-invoke
- If exit: return; user will re-invoke when ready

## Key references

- `slm-forge-brief/skills/SKILL_SPECS.md § forge-monitor`
- `slm-forge-brief/architecture/PHASE_TABLE.md § Loop phase: MONITOR`
- `slm-forge-brief/architecture/MANIFEST_SCHEMA.md § training_runtime`
