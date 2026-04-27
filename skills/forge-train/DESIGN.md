# forge-train — DESIGN.md

> **Status:** M4-prep design doc. Implementation lives in `run.sh`
> when M4 unblocks (waiting on G+VT vCPU quota grant; request id
> `df1f91af3fec4d249288178147f4a021ZBsgUvQ8`).

## Phase

`TRAIN → MONITOR`. Triggered by master dispatcher after BOOTSTRAP returns
`bootstrap_completed=true`.

## Inputs read from manifest

- `manifest.plan.{base_model, training_regime, target_params, training_framework, chat_template, tokenizer_strategy}`
- `manifest.spec.{constraints.max_wall_clock_hours}`
- `manifest.artifacts.shaped_corpus_s3`
- `manifest.compute_target.{instance_id, workdir}`

## Outputs written to manifest

```json
"training_runtime": {
  "pid": <int>,
  "log_path_remote": "/workspace/logs/train.log",
  "log_path_s3":     "s3://<YOUR_S3_BUCKET>/forge/<id>/logs/train.log",
  "started_at":      "<ISO-8601>",
  "config_yaml_s3":  "s3://<YOUR_S3_BUCKET>/forge/<id>/training/config.yaml",
  "framework":       "unsloth" | "huggingface-trainer",
  "last_checkpoint_step": null,
  "last_checkpoint_s3":   null,
  "last_loss":            null,
  "last_loss_step":       null,
  "last_heartbeat":       "<ISO-8601>",
  "eta_remaining_minutes": null
}
```

Phase advance: `TRAIN → MONITOR`. Returns immediately (does not block
until training completes — that's MONITOR's job).

## Procedure

1. **Generate training config YAML from `plan`.**
   - `slm-forge/scripts/build-train-config.py` (NEW, M4) takes the manifest
     as stdin, emits a YAML to stdout. Schema below.
   - Upload to `s3://forge/<id>/training/config.yaml` AND copy to
     `/workspace/training/config.yaml` on the instance.

2. **Pull shaped corpus to instance.** Trigger `aws s3 sync` via SSM:
   ```
   aws s3 sync s3://forge/<id>/data/shaped/ /workspace/data/shaped/
   ```

3. **Launch training detached.** Two side processes:
   - **train**: `nohup /workspace/.venv/bin/python /workspace/scripts/train.py --config /workspace/training/config.yaml > /workspace/logs/train.log 2>&1 & echo $! > /workspace/.forge-train.pid`
   - **log-sync**: `nohup bash -c 'while sleep 30; do aws s3 cp /workspace/logs/train.log s3://forge/<id>/logs/train.log --region ca-central-1; done' > /dev/null 2>&1 & echo $! > /workspace/.forge-log-sync.pid`
   - **NOTE re. M3 lesson**: AWS-RunShellScript on Ubuntu uses `dash` which doesn't have `disown`. Use `setsid` or wrap explicitly: `bash -c '<cmd> & disown'`. Validate at smoke time.

4. **Health probe (30 sec).**
   - `ssm exec "kill -0 $(cat /workspace/.forge-train.pid)"` — must succeed.
   - `tail -20 /workspace/logs/train.log` — must show framework banner (e.g., "Unsloth: Using …" or HF Trainer args), no immediate crash.
   - If both pass: write `training_runtime.*`, advance to MONITOR.
   - If either fails within 30 sec: write to `manifest.errors`, return `{"status":"failed","recoverable":true,"recovery_hint":"check log_path_s3 first 50 lines"}`.

5. **Return** `{"status":"completed","next_phase":"MONITOR","forge_id":"…","pid":<int>,"log_path_s3":"…"}`.

## Training config YAML schema (v1)

```yaml
# Generated from manifest.plan + spec by scripts/build-train-config.py
# DO NOT edit on the instance — re-run forge-architect to amend.

forge_id: forge-2026-04-23-...
schema_version: "1.0.0"

base_model:
  hf_repo: Qwen/Qwen2.5-0.5B
  revision: main           # or a pinned commit/sha
  trust_remote_code: false

regime:
  type: lora-sft           # one of: lora-sft / full-sft / continued-pretrain / from-scratch-pretrain / prune-to-300m / distill-to-300m
  lora:
    r: 16
    alpha: 32
    dropout: 0.05
    target_modules: [q_proj, k_proj, v_proj, o_proj]
  prune:                   # only when regime.type == prune-to-300m
    target_params: 200000000
    method: magnitude      # magnitude | structured | wanda

data:
  train_jsonl: /workspace/data/shaped/train.jsonl
  val_jsonl:   /workspace/data/shaped/val.jsonl
  test_jsonl:  /workspace/data/shaped/test.jsonl
  unified_schema: true     # docs follow {id, domain, format, messages, raw_text, metadata}
  max_seq_len: 2048
  pack_sequences: true
  chat_template: qwen2     # from plan.chat_template

training:
  output_dir: /workspace/checkpoints
  num_train_epochs: 3
  per_device_train_batch_size: 4
  gradient_accumulation_steps: 4
  learning_rate: 2.0e-4
  warmup_ratio: 0.03
  lr_scheduler_type: cosine
  weight_decay: 0.01
  fp16: false
  bf16: true               # A10G/A100 prefer bf16
  gradient_checkpointing: true
  save_strategy: steps
  save_steps: 200
  save_total_limit: 3      # keep last 3 + final per S3_LAYOUT.md
  logging_steps: 10
  evaluation_strategy: steps
  eval_steps: 200
  seed: 42
  report_to: []            # no W&B/MLflow — manifest is the source of truth

tokenizer:
  strategy: reuse-base     # plan.tokenizer_strategy
  add_special_tokens: false

resume:
  from_checkpoint: null    # set by forge-resume; null = train from scratch

framework: unsloth         # plan.training_framework

logging:
  remote_log_path: /workspace/logs/train.log
  s3_sync_interval_sec: 30
```

## Failure modes (return contract)

| Failure | recoverable | recovery_hint |
|---|---|---|
| Training crashes within 30s health probe | true | `read s3://.../logs/train.log first 50 lines; common: OOM (reduce batch size in config), wrong CUDA build, missing dataset path` |
| PID fails to persist (file empty) | true | `re-run forge-train; nohup/setsid race condition` |
| OOM on first batch | true | `forge-architect amend with smaller per_device_train_batch_size or larger gradient_accumulation_steps; re-run` |
| `shaped_corpus_s3` aws s3 sync fails | true | `check FORGE_AWS_* perms; instance role IAM` |
| Disk full at /workspace | true | `forge-provision with larger ebs_gb` |

## Key references

- `slm-forge-brief/skills/SKILL_SPECS.md § forge-train` (canonical spec)
- `slm-forge-brief/architecture/COMPUTE_TARGET.md § exec_nohup` (detached exec contract)
- `slm-forge-brief/DECISIONS.md § D-008` (Unsloth primary, HF Trainer fallback)
- `slm-forge-brief/DECISIONS.md § D-007` (unified internal schema)
- M3 lesson: nohup+disown doesn't survive AWS-RunShellScript's dash; use setsid or explicit bash -c wrapper.
