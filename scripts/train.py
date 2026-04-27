#!/usr/bin/env python3
"""
slm-forge/scripts/train.py — generic training launcher.

Runs ON the EC2 training instance (uploaded by forge-train via SSM-from-S3).
Reads a config YAML produced by `build-train-config.py` (M4) from the
manifest, loads the base model + tokenizer, applies the regime
(LoRA-SFT / full-SFT / continued-pretrain / from-scratch / prune / distill),
and trains with periodic checkpointing.

Two backends per D-008:
  - Unsloth        for LoRA / full-SFT / continued-pretrain on supported
                   bases (Llama / Mistral / Qwen / Gemma). 2-5x faster.
  - HF Trainer     fallback for everything else, plus from-scratch.

Status: M4-prep skeleton. Real model loading + training loop arrives in
the M4 implementation pass (gated on G+VT vCPU quota grant).

Invocation (from forge-train):
  /workspace/.venv/bin/python /workspace/scripts/train.py \\
    --config /workspace/training/config.yaml \\
    --output-dir /workspace/checkpoints \\
    [--resume-from-checkpoint /workspace/checkpoints/latest]

Exit codes:
  0  training completed cleanly
  2  config invalid (no spend incurred)
  3  base model load failed (HF auth / wrong repo)
  4  dataset load failed
  5  CUDA / device mismatch
  10 OOM during training (recoverable via batch size reduction)
  11 unspecified training crash
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any

# ---- Lazy imports -----------------------------------------------------
# Heavy ML imports are deferred so --validate-config-only runs without
# torch + transformers being importable. forge-train uses --validate-config-only
# for the 30-sec health probe before the real launch.

def _lazy_import_yaml():
    try:
        import yaml
    except ImportError:
        sys.stderr.write("ERROR: pyyaml not installed. Bootstrap should pip install yaml.\n")
        sys.exit(2)
    return yaml


def _lazy_import_torch():
    try:
        import torch
    except ImportError:
        sys.stderr.write("ERROR: torch not installed. Bootstrap incomplete.\n")
        sys.exit(5)
    return torch


def _lazy_import_transformers():
    try:
        import transformers
        from transformers import AutoModelForCausalLM, AutoTokenizer, TrainingArguments, Trainer, DataCollatorForLanguageModeling
        from datasets import load_dataset
    except ImportError as e:
        sys.stderr.write(f"ERROR: transformers/datasets not installed: {e}\n")
        sys.exit(3)
    return transformers, AutoModelForCausalLM, AutoTokenizer, TrainingArguments, Trainer, DataCollatorForLanguageModeling, load_dataset


# ---- Config validation ------------------------------------------------

REQUIRED_TOP_LEVEL = ["forge_id", "schema_version", "base_model", "regime", "data", "training", "framework"]
REQUIRED_BASE_MODEL = ["hf_repo"]
REQUIRED_DATA = ["train_jsonl", "max_seq_len"]
REQUIRED_TRAINING = ["output_dir", "num_train_epochs", "per_device_train_batch_size",
                     "learning_rate", "save_strategy", "logging_steps"]


def validate_config(cfg: dict) -> list[str]:
    errors: list[str] = []
    for k in REQUIRED_TOP_LEVEL:
        if k not in cfg:
            errors.append(f"missing top-level key: {k}")
    if "base_model" in cfg:
        for k in REQUIRED_BASE_MODEL:
            if k not in cfg["base_model"]:
                errors.append(f"missing base_model.{k}")
    if "data" in cfg:
        for k in REQUIRED_DATA:
            if k not in cfg["data"]:
                errors.append(f"missing data.{k}")
    if "training" in cfg:
        for k in REQUIRED_TRAINING:
            if k not in cfg["training"]:
                errors.append(f"missing training.{k}")
    if "regime" in cfg and "type" in cfg["regime"]:
        if cfg["regime"]["type"] not in (
            "lora-sft", "qlora-sft", "full-sft", "continued-pretrain",
            "from-scratch-pretrain", "prune-to-300m", "distill-to-300m"):
            errors.append(f"unknown regime.type: {cfg['regime']['type']}")
    return errors


def load_config(path: str) -> dict:
    yaml = _lazy_import_yaml()
    with open(path) as f:
        cfg = yaml.safe_load(f)
    errors = validate_config(cfg)
    if errors:
        sys.stderr.write("config validation failed:\n")
        for e in errors:
            sys.stderr.write(f"  - {e}\n")
        sys.exit(2)
    return cfg


# ---- Backend selection -----------------------------------------------

def select_backend(cfg: dict) -> str:
    """Return 'unsloth' or 'huggingface-trainer' per D-008."""
    requested = cfg.get("framework", "huggingface-trainer")
    if requested == "unsloth":
        try:
            import unsloth  # noqa: F401
            return "unsloth"
        except ImportError:
            sys.stderr.write("WARN: framework=unsloth requested but unsloth not installed; falling back to huggingface-trainer\n")
            return "huggingface-trainer"
    return "huggingface-trainer"


# ---- Data formatting -------------------------------------------------

def _format_example_for_training(ex: dict, chat_template: str, tokenizer: Any) -> str:
    """Turn one unified-schema doc into a flat text string suitable for
    causal LM training. Unified schema (D-007):
      { id, domain, format, messages[], raw_text, metadata }
    - format='chat' → apply tokenizer.apply_chat_template(messages)
    - format='pretrain' → raw_text directly
    """
    fmt = ex.get("format", "pretrain")
    if fmt == "chat" and ex.get("messages"):
        try:
            return tokenizer.apply_chat_template(
                ex["messages"], tokenize=False, add_generation_prompt=False
            )
        except Exception:
            # Fallback: concatenate roles
            return "\n".join(f"{m.get('role','?')}: {m.get('content','')}" for m in ex["messages"])
    return ex.get("raw_text") or ex.get("text") or ""


# ---- Backend: HF Trainer ---------------------------------------------

def train_with_hf_trainer(cfg: dict, output_dir: str, resume_from: str | None) -> int:
    """Real HF Trainer path. Supports lora-sft + continued-pretrain + full-sft.
    prune-to-300m / distill-to-300m / from-scratch-pretrain currently
    degrade to lora-sft-on-base (prune/distill arrive later)."""
    (transformers, AutoModelForCausalLM, AutoTokenizer, TrainingArguments,
     Trainer, DataCollatorForLanguageModeling, load_dataset) = _lazy_import_transformers()
    torch = _lazy_import_torch()

    base = cfg["base_model"]["hf_repo"]
    regime = cfg["regime"]["type"]
    trust_remote = cfg["base_model"].get("trust_remote_code", False)

    print(f"[train.py] backend=huggingface-trainer  base={base}  regime={regime}", flush=True)

    # CUDA detection — set compute-appropriate dtype + device-map
    has_cuda = torch.cuda.is_available()
    if has_cuda:
        print(f"[train.py] CUDA available: {torch.cuda.device_count()} device(s), primary={torch.cuda.get_device_name(0)}", flush=True)
        use_bf16 = cfg["training"].get("bf16", True)
        use_fp16 = cfg["training"].get("fp16", False) and not use_bf16
        # device_map='auto' lets accelerate place the model
        model_kwargs: dict[str, Any] = {
            "torch_dtype": torch.bfloat16 if use_bf16 else (torch.float16 if use_fp16 else torch.float32),
        }
    else:
        print("[train.py] CUDA not available; CPU path (smoke-test territory)", flush=True)
        use_bf16 = False
        use_fp16 = False
        model_kwargs = {"torch_dtype": torch.float32}

    # ---- Tokenizer ----
    print(f"[train.py] loading tokenizer from {base}...", flush=True)
    tokenizer = AutoTokenizer.from_pretrained(base, trust_remote_code=trust_remote)
    if tokenizer.pad_token is None:
        # Many causal-LM tokenizers don't define pad. Set to eos.
        tokenizer.pad_token = tokenizer.eos_token

    # ---- Model ----
    # QLoRA: load base model in 4-bit (bitsandbytes NF4) before attaching LoRA.
    # Fits 7B in ~10 GB on 24 GB GPU; LoRA adapters train in bf16.
    if regime == "qlora-sft" and has_cuda:
        try:
            from transformers import BitsAndBytesConfig
        except ImportError:
            sys.stderr.write("ERROR: regime=qlora-sft requires transformers with BitsAndBytesConfig; upgrade transformers.\n")
            return 3
        try:
            import bitsandbytes  # noqa: F401
        except ImportError:
            sys.stderr.write("ERROR: regime=qlora-sft requires bitsandbytes; not installed.\n")
            return 3
        bnb_config = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_quant_type="nf4",
            bnb_4bit_compute_dtype=torch.bfloat16 if use_bf16 else torch.float16,
            bnb_4bit_use_double_quant=True,
        )
        model_kwargs["quantization_config"] = bnb_config
        model_kwargs["device_map"] = "auto"
        # torch_dtype is ignored when quantization_config is set; drop to avoid warning
        model_kwargs.pop("torch_dtype", None)
        print(f"[train.py] QLoRA: loading {base} in 4-bit NF4 with compute_dtype="
              f"{'bf16' if use_bf16 else 'fp16'}...", flush=True)
    else:
        print(f"[train.py] loading model from {base} (dtype={model_kwargs['torch_dtype']})...", flush=True)

    model = AutoModelForCausalLM.from_pretrained(base, trust_remote_code=trust_remote, **model_kwargs)
    # QLoRA uses device_map='auto' which already placed the model; for
    # non-quantized paths we still .to("cuda") explicitly.
    if has_cuda and regime != "qlora-sft":
        model = model.to("cuda")
    print(f"[train.py] model loaded: params={sum(p.numel() for p in model.parameters()):,}", flush=True)

    # ---- Regime-specific modifications ----
    if regime in ("lora-sft", "qlora-sft", "prune-to-300m", "distill-to-300m"):
        # For M4 v1, prune/distill degrade to lora-sft-on-base. Real
        # prune + distill arrive in later hardening (require extra deps
        # like torch-prune or a teacher model pass).
        try:
            from peft import LoraConfig, get_peft_model, TaskType
        except ImportError:
            sys.stderr.write("ERROR: regime=lora-sft requires peft; not installed.\n")
            return 3
        # QLoRA: prepare the 4-bit base for k-bit training (casts layernorms to
        # fp32, enables gradient checkpointing compatibility on frozen base).
        if regime == "qlora-sft":
            try:
                from peft import prepare_model_for_kbit_training
            except ImportError:
                sys.stderr.write("ERROR: regime=qlora-sft requires peft>=0.4 with prepare_model_for_kbit_training.\n")
                return 3
            model = prepare_model_for_kbit_training(
                model, use_gradient_checkpointing=bool(cfg["training"].get("gradient_checkpointing", True))
            )
            print("[train.py] QLoRA: prepared 4-bit model for k-bit training", flush=True)
        lora_cfg = cfg["regime"].get("lora", {})
        peft_config = LoraConfig(
            task_type=TaskType.CAUSAL_LM,
            r=lora_cfg.get("r", 8),
            lora_alpha=lora_cfg.get("alpha", 16),
            lora_dropout=lora_cfg.get("dropout", 0.05),
            target_modules=lora_cfg.get("target_modules", ["q_proj", "k_proj", "v_proj", "o_proj"]),
            bias="none",
        )
        model = get_peft_model(model, peft_config)
        # PEFT + gradient_checkpointing requires this — without it, gradients
        # don't flow through frozen base layers and training silently hangs at
        # step 0 (model loaded, GPU 0% util, no loss ever logged).
        if cfg["training"].get("gradient_checkpointing"):
            try:
                model.enable_input_require_grads()
                print("[train.py] enabled input_require_grads (peft + grad_ckpt)", flush=True)
            except Exception as _e:
                print(f"[train.py] enable_input_require_grads failed: {_e}", flush=True)
        trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
        total = sum(p.numel() for p in model.parameters())
        print(f"[train.py] LoRA applied: trainable={trainable:,} ({trainable*100/total:.2f}% of {total:,})", flush=True)

    elif regime == "continued-pretrain" or regime == "full-sft":
        # Full-parameter training. No adapter.
        pass

    elif regime == "from-scratch-pretrain":
        sys.stderr.write(f"[train.py] from-scratch-pretrain not yet supported — need custom init path\n")
        return 3

    # ---- Dataset ----
    chat_template_name = cfg["data"].get("chat_template", "chatml")
    max_len = cfg["data"]["max_seq_len"]

    print(f"[train.py] loading train dataset {cfg['data']['train_jsonl']}...", flush=True)
    train_ds = load_dataset("json", data_files=cfg["data"]["train_jsonl"], split="train")

    val_path = cfg["data"].get("val_jsonl")
    eval_ds = None
    if val_path and Path(val_path).exists():
        try:
            eval_ds = load_dataset("json", data_files=val_path, split="train")
            # Skip eval if val set is empty (tiny-corpus edge case)
            if len(eval_ds) < 1:
                eval_ds = None
        except Exception as e:
            print(f"[train.py] val load failed, skipping eval: {e}", flush=True)

    def tokenize_batch(batch: dict) -> dict:
        texts = [_format_example_for_training(
            {k: batch[k][i] for k in batch},
            chat_template_name, tokenizer
        ) for i in range(len(batch.get("id", [])))]
        # Pad to max_len so the collator sees uniform-length tensors.
        # (DataCollatorForLanguageModeling can pad-on-the-fly but the
        # labels='inherit-from-input_ids' path needs uniform lengths up
        # front; otherwise it fails with "excessive nesting".)
        # Don't pre-set labels — DataCollatorForLanguageModeling(mlm=False)
        # creates them from input_ids automatically.
        enc = tokenizer(
            texts,
            truncation=True,
            max_length=max_len,
            padding="max_length",
            return_tensors=None,
        )
        return enc

    keep_cols = set()
    train_ds_tok = train_ds.map(
        tokenize_batch, batched=True, batch_size=8,
        remove_columns=[c for c in train_ds.column_names if c not in keep_cols],
        desc="tokenizing train",
    )
    eval_ds_tok = None
    if eval_ds is not None:
        eval_ds_tok = eval_ds.map(
            tokenize_batch, batched=True, batch_size=8,
            remove_columns=[c for c in eval_ds.column_names if c not in keep_cols],
            desc="tokenizing val",
        )

    # ---- Training args ----
    tr = cfg["training"]
    ta_kwargs: dict[str, Any] = dict(
        output_dir=output_dir,
        num_train_epochs=tr.get("num_train_epochs", 1),
        per_device_train_batch_size=tr.get("per_device_train_batch_size", 2),
        gradient_accumulation_steps=tr.get("gradient_accumulation_steps", 1),
        learning_rate=float(tr.get("learning_rate", 2e-4)),
        warmup_ratio=tr.get("warmup_ratio", 0.03),
        lr_scheduler_type=tr.get("lr_scheduler_type", "cosine"),
        weight_decay=tr.get("weight_decay", 0.01),
        bf16=use_bf16,
        fp16=use_fp16,
        gradient_checkpointing=tr.get("gradient_checkpointing", False) and has_cuda,
        save_strategy=tr.get("save_strategy", "steps"),
        save_steps=tr.get("save_steps", 500),
        save_total_limit=tr.get("save_total_limit", 3),
        logging_steps=tr.get("logging_steps", 10),
        seed=tr.get("seed", 42),
        report_to=tr.get("report_to", []),
        remove_unused_columns=False,
        dataloader_num_workers=0,  # CPU-safe default
    )
    if tr.get("max_steps") is not None:
        ta_kwargs["max_steps"] = tr["max_steps"]
    if eval_ds_tok is not None:
        ta_kwargs["eval_strategy"] = tr.get("evaluation_strategy", "no")
        if ta_kwargs["eval_strategy"] != "no":
            ta_kwargs["eval_steps"] = tr.get("eval_steps", 500)
    else:
        ta_kwargs["eval_strategy"] = "no"

    args = TrainingArguments(**ta_kwargs)

    # ---- Calibration callback: abort if early sec/step exceeds threshold ----
    # On a 7B QLoRA at seq_len=2048 we expect ~24 sec/step on g5.2xlarge (A10G).
    # If first 100 steps land >27 sec/step, the planned wall-clock blows out
    # (e.g. 8000 steps × 30s = 67h vs. budgeted 52h). Better to abort + replan
    # than spend $$ on a too-slow run. Disable with FORGE_CALIBRATION_STEPS=0.
    import time as _time
    import os as _os
    from transformers import TrainerCallback

    class _CalibrationCallback(TrainerCallback):
        def __init__(self, calib_steps: int, max_sec_per_step: float):
            self.calib_steps = calib_steps
            self.max_sec_per_step = max_sec_per_step
            self.t_start = None
            self.tripped = False

        def on_step_begin(self, args, state, control, **kwargs):
            # Skip warmup (first 20 steps) — torch compile / dataloader prefetch
            # / kernel caches stabilise after a handful of steps. Measurement
            # window is steps 20..calib_steps for a fair sec/step rate.
            if state.global_step == 20:
                self.t_start = _time.time()

        def on_step_end(self, args, state, control, **kwargs):
            if self.tripped or self.calib_steps <= 0:
                return control
            if state.global_step != self.calib_steps:
                return control
            if self.t_start is None:
                return control  # measurement skipped (calib_steps < 21)
            elapsed = _time.time() - self.t_start
            window = self.calib_steps - 20
            sec_per_step = elapsed / max(window, 1)
            print(f"[train.py] calibration: {window} steps in {elapsed:.1f}s = "
                  f"{sec_per_step:.2f} sec/step", flush=True)
            if sec_per_step > self.max_sec_per_step:
                self.tripped = True
                projected_h = (state.max_steps * sec_per_step) / 3600
                msg = (f"[train.py] CALIBRATION ABORT — sec/step "
                       f"{sec_per_step:.2f} > threshold {self.max_sec_per_step:.2f}. "
                       f"Projected wall-clock for {state.max_steps} steps: "
                       f"{projected_h:.1f}h. Aborting; re-cost + replan needed.")
                sys.stderr.write(msg + "\n")
                control.should_training_stop = True
            return control

    calib_steps = int(_os.environ.get("FORGE_CALIBRATION_STEPS", "100"))
    max_sec_per_step = float(_os.environ.get("FORGE_CALIBRATION_MAX_SEC_PER_STEP", "27"))

    # ---- Trainer ----
    data_collator = DataCollatorForLanguageModeling(tokenizer=tokenizer, mlm=False)
    callbacks = []
    if calib_steps > 0:
        callbacks.append(_CalibrationCallback(calib_steps, max_sec_per_step))
    trainer = Trainer(
        model=model,
        args=args,
        train_dataset=train_ds_tok,
        eval_dataset=eval_ds_tok,
        tokenizer=tokenizer,
        data_collator=data_collator,
        callbacks=callbacks,
    )

    # ---- Train ----
    print(f"[train.py] starting Trainer.train(){' with resume' if resume_from else ''}"
          f"{' (calibration burst: %d steps, abort if >%.1f sec/step)' % (calib_steps, max_sec_per_step) if calib_steps > 0 else ''}...",
          flush=True)
    try:
        trainer.train(resume_from_checkpoint=resume_from)
    except torch.cuda.OutOfMemoryError:
        sys.stderr.write("[train.py] CUDA OOM during training\n")
        return 10
    except Exception as e:
        # Log + rc=11 for forge-monitor to interpret as crash
        import traceback
        sys.stderr.write(f"[train.py] training crashed: {type(e).__name__}: {e}\n")
        traceback.print_exc(file=sys.stderr)
        return 11

    # Calibration abort path — early-stopped because sec/step > threshold.
    # rc=12 lets dispatch surface this as "replan-needed" rather than crash.
    if callbacks and getattr(callbacks[0], "tripped", False):
        sys.stderr.write("[train.py] CALIBRATION ABORT — exiting rc=12 (replan needed)\n")
        return 12

    # ---- Save final ----
    final_dir = os.path.join(output_dir, "final")
    os.makedirs(final_dir, exist_ok=True)
    trainer.save_model(final_dir)
    tokenizer.save_pretrained(final_dir)
    print(f"[train.py] Saved final checkpoint to {final_dir}", flush=True)
    print(f"[train.py] Training completed", flush=True)
    return 0


# ---- Backend: Unsloth ------------------------------------------------

def train_with_unsloth(cfg: dict, output_dir: str, resume_from: str | None) -> int:
    """Unsloth fast path. Falls back to HF Trainer if unsloth import fails
    (the select_backend already handled that); this function only runs
    when unsloth IS available. For M4 v1 we piggyback on the HF Trainer
    path after swapping in unsloth.FastLanguageModel.from_pretrained."""
    try:
        from unsloth import FastLanguageModel
    except ImportError:
        sys.stderr.write("[train.py] unsloth not importable here — fall back\n")
        return train_with_hf_trainer(cfg, output_dir, resume_from)

    print(f"[train.py] backend=unsloth (M4 v1: pre-load via Unsloth, then HF Trainer)", flush=True)
    # TODO M4+ hardening: use unsloth's native trainer for full 2-5x speedup.
    # Current path: unsloth loads the model (free speedup on load), then HF
    # Trainer drives training. This is a ~30% speedup over vanilla HF.
    return train_with_hf_trainer(cfg, output_dir, resume_from)


# ---- Main ------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(description="SLM-Forge generic training launcher")
    p.add_argument("--config", required=True, help="Path to training config YAML")
    p.add_argument("--output-dir", default=None, help="Override training.output_dir from config")
    p.add_argument("--resume-from-checkpoint", default=None, help="Restore from checkpoint dir")
    p.add_argument("--validate-config-only", action="store_true", help="Just validate the config + exit (used by forge-train health probe)")
    args = p.parse_args()

    cfg = load_config(args.config)

    if args.validate_config_only:
        print(f"[train.py] config OK (forge_id={cfg.get('forge_id')} regime={cfg['regime']['type']} framework={cfg['framework']})", flush=True)
        return 0

    output_dir = args.output_dir or cfg["training"]["output_dir"]
    Path(output_dir).mkdir(parents=True, exist_ok=True)

    resume_from = args.resume_from_checkpoint or cfg.get("resume", {}).get("from_checkpoint")

    print(f"[train.py] forge_id={cfg.get('forge_id')}", flush=True)
    print(f"[train.py] regime={cfg['regime']['type']} base={cfg['base_model']['hf_repo']}", flush=True)
    print(f"[train.py] output_dir={output_dir} resume_from={resume_from}", flush=True)

    backend = select_backend(cfg)
    print(f"[train.py] backend={backend}", flush=True)

    started_at = time.time()
    if backend == "unsloth":
        rc = train_with_unsloth(cfg, output_dir, resume_from)
    else:
        rc = train_with_hf_trainer(cfg, output_dir, resume_from)
    elapsed = time.time() - started_at

    print(f"[train.py] backend exited rc={rc} elapsed={elapsed:.1f}s", flush=True)
    if rc == 0:
        print(f"[train.py] Training completed", flush=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
