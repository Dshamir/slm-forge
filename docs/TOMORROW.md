# TOMORROW.md — Clean-start playbook for the real forge run

> **Scenario:** You open your laptop, fresh terminal, no state in your head.
> This doc takes you from zero to a published dental-AI SLM on HuggingFace.
>
> **Assumes:** you're on `poly_updates` branch, corpus already at
> `slm-forge/corpora/publications.jsonl`, HF token + AWS forge creds
> already seeded in `/admin/credentials` and `.env`. (All true as of
> commit `c05b152` / 2026-04-23.)
>
> **Before anything else:** run the preflight.

---

## Step 0 — Pre-flight (2 min)

```bash
cd <PROJECT_HOME>
git pull  # grab any overnight commits
bash slm-forge/scripts/preflight.sh
```

Three possible outcomes:

### GREEN — "PREFLIGHT PASS"
Everything ready. Quota is granted. **Go to Step 1.**

### YELLOW — "PREFLIGHT YELLOW — quota not yet granted"
Core infra OK, but AWS hasn't bumped the G+VT quota from 8 to 32 yet.
Two options:

**Option A: wait for AWS.** Re-run preflight later. Check quota specifically:
```bash
bash slm-forge/scripts/check-quota-status.sh
```
When `[2] Current effective quota value` shows **32** (or higher), proceed to Step 1.

**Option B: CPU training right now (slow but feasible).** Set overrides:
```bash
export FORGE_INSTANCE_TYPE_OVERRIDE=t3.xlarge
export FORGE_TRAIN_MAX_STEPS=500      # cap at ~1-hour CPU budget
export FORGE_TRAIN_BATCH_SIZE=1       # CPU-friendly
```
Then go to Step 1. Note: CPU training at 500 steps over 1.68M tokens is a
reduced run — the model will see only ~80k tokens total. Better than a
toy (100-doc synthetic smoke) but still not a real training run. Good
enough to demo the pipeline on real content.

### RED — any "[✗]" line
Fix the blocker listed. Common causes:
- HF token revoked / rotated → re-seed `HF_TOKEN` in `.env`
- MongoDB down → `cd <PROJECT_HOME> && docker compose up -d mongodb`
- Corpus file missing → re-run `prep-publications.py` against the RAR

---

## Step 1 — Kick off the forge (drive to BUDGET_GATE)

```bash
bash slm-forge/scripts/kickoff-real-forge.sh
```

**What it does** (~1-2 min on a good day):
- Runs preflight again as a sanity check
- Resolves FORGE_AWS_* + HF_TOKEN from vault/env
- Writes a pre-canned spec JSON (dental.ai.research domain, $20 budget, Qwen2.5-0.5B base, lora-sft)
- Runs `manifest_init` → generates a new forge_id
- Dispatches INTAKE → ARCHITECT → ESTIMATE (all local, no spend)
- Stops at BUDGET_GATE
- Prints the forge_id + next commands

**Default picks** you can override before running:
```bash
# Bigger base model (slower but more capacity)
export FORGE_ARCHITECT_BASE_OVERRIDE=Qwen/Qwen2.5-0.5B    # default
# Or: Qwen/Qwen2.5-1.5B (larger; 3x training time)
# Or: HuggingFaceTB/SmolLM2-135M (smaller; faster; less capacity)

# Regime
export FORGE_ARCHITECT_REGIME_OVERRIDE=lora-sft           # default
# Or: continued-pretrain (whole-corpus unsupervised; slower, better long-term)

# Training length
export FORGE_TRAIN_MAX_STEPS=2000                          # default; ~30 min on g5.xlarge
# Quick demo: 500 (~10 min)
# Thorough: 5000 (~1.5 hr)

# Budget cap (hard limit)
export FORGE_BUDGET_CAP_USD=20                             # default
```

---

## Step 2 — Review the estimate

Before approving spend, see what the forge picked + plans to do:

```bash
bash slm-forge/skills/forge-status/run.sh --no-liveness <FORGE_ID>
```

(The `<FORGE_ID>` from Step 1's output. Format: `forge-2026-04-24-publications-abc123`.)

Look at:
- **Spec** — goal, domain, budget_cap match your intent
- **Plan** — base_model, regime, target_params, framework
- **Estimate** — gpu_hours, instance_type, estimated_total_cost_usd, confidence

**Acceptance check (do it yourself):**
- total_est ≤ your real budget (the cap + your sanity threshold)
- instance_type is g5.xlarge (GPU) if quota is open, t3.xlarge if CPU
- confidence is **medium** or higher (low means the corpus size is out of heuristic range — either fine on a large corpus, or suspect on a tiny one)

---

## Step 3 — Approve BUDGET_GATE + run through to EVAL

```bash
# Resume the forge from BUDGET_GATE onward. --auto-approve-gates
# passes BOTH gates automatically. For a hands-on review, skip it and
# answer the interactive prompts.

FORGE_INSTANCE_TYPE_OVERRIDE="${FORGE_INSTANCE_TYPE_OVERRIDE:-g5.xlarge}" \
FORGE_TRAIN_MAX_STEPS="${FORGE_TRAIN_MAX_STEPS:-2000}" \
  bash slm-forge/scripts/dispatch.sh <FORGE_ID> --until EVAL
```

This runs: SOURCE → CURATE → SHAPE → PROVISION (launches EC2!) →
BOOTSTRAP (~5 min) → TRAIN (~30 min GPU or ~1 hr CPU-500-step) →
MONITOR (polls until done) → EVAL (~5 min).

**Wall-clock time:** 45-90 min depending on instance + max_steps.

**You can walk away** during TRAIN/MONITOR. The manifest + S3 state
survives. If your laptop closes or the session drops, resume with:
```bash
bash slm-forge/scripts/dispatch.sh <FORGE_ID>
```

**Watching progress:**
```bash
# In a second terminal:
watch -n 30 'bash slm-forge/skills/forge-status/run.sh <FORGE_ID> 2>&1 | head -60'
```

**If training crashes** (OOM, NaN loss, etc.):
```bash
# Diagnose:
bash slm-forge/skills/forge-status/run.sh <FORGE_ID>   # errors section

# Recovery (state-A / alive + SSM; restarts from last checkpoint):
bash slm-forge/skills/forge-resume/run.sh <FORGE_ID>
```

---

## Step 4 — Review QUALITY_GATE + decide

When dispatch stops at QUALITY_GATE, the forge has run eval on your
trained model vs. the baseline (`Qwen/Qwen2.5-0.5B` unfine-tuned) and
written reports to S3.

**Read the eval reports:**
```bash
# Pretty: forge-status shows perplexity + sample snippets
bash slm-forge/skills/forge-status/run.sh <FORGE_ID>

# Full samples.md:
FORGE_AWS_ACCESS_KEY_ID=$(bash slm-forge/scripts/preflight.sh 2>&1 | grep -q "resolved" && echo "resolved") \
  bash slm-forge/lib/s3.sh get <FORGE_ID> eval/reports/samples.md /tmp/samples.md
cat /tmp/samples.md
```

**Your call:**
- Is the perplexity delta favorable (forged < baseline on test set)?
- Do the 10 sample generations sound like dental AI research content?
- Are there obvious failure modes (pure repetition, gibberish, refusals)?

**If yes — approve:**
```bash
bash slm-forge/scripts/dispatch.sh <FORGE_ID> --auto-approve-gates
```
This resumes: QUANTIZE (GGUF Q4_K_M + Q8_0) → REGISTER (HF repo + Space,
**private** default) → TEARDOWN (kills EC2). ~15-20 min.

**If no — abort this forge + try again with different plan:**
```bash
bash slm-forge/skills/forge-teardown/run.sh <FORGE_ID> --terminate
# Then rerun Step 1 with overrides: bigger model, more steps, different regime.
```

---

## Step 5 — Manual D-018 review + HF public flip

The forge publishes everything **private** by default. Before demo,
**read the model card**, check samples, then flip public.

```bash
# What URLs?
bash slm-forge/skills/forge-status/run.sh <FORGE_ID> | grep -E "hf_repo|hf_space"
```

**Open each URL in a browser (signed in to your HF account):**

### Model repo
- Read `README.md` top-to-bottom
- Confirm: no internal branding leaked (no "NEXLESS", no "MGMO", no client names, no ticket IDs)
- Confirm: eval numbers look honest (not copy-pasted junk)
- Confirm: GGUF files are there under `gguf/`
- Click **Settings → Change visibility → Public**

### Space
- Wait for the build indicator to finish (~2-3 min after upload; check the top-right of the Space page)
- Once "Running", click **App** tab and send a test message like "What is a dental crown?"
- Confirm: response makes sense, no crash
- Optional: **Settings → Hardware → T4 small** ($0.60/hr) for the demo window — faster inference
- **Settings → Change visibility → Public**

### Ollama Modelfile (optional local verification)
```bash
MODEL_URL="https://huggingface.co/Nexless/<forge-model-name>/raw/main/Modelfile"
curl -sSL "$MODEL_URL" -o /tmp/Modelfile
# Requires ollama installed locally
ollama create dental-ai-slm -f /tmp/Modelfile
ollama run dental-ai-slm
# Type a prompt; type /bye to exit.
```

---

## Step 6 — Symposium-day checklist

See also `slm-forge/docs/SYMPOSIUM-HANDOFF.md` for the abbreviated day-of
reference. Key pre-talk steps:

- [ ] **T-24h**: confirm HF Space still "Running" (not asleep). Refresh it manually once.
- [ ] **T-1h**: warm up Space (send one message, confirm response < 5 sec)
- [ ] **T-30min**: optional T4 upgrade for Space if you want sub-second responses
- [ ] **Have these URLs + forge-id handy on a notecard**:
  - `https://huggingface.co/Nexless/<forge-model-name>` (model card)
  - `https://huggingface.co/spaces/Nexless/<forge-model-name>-demo` (live chat)
  - `forge_id: forge-2026-04-24-publications-<suffix>` (for forge-status during Q&A)

---

## Total timing (GPU path)

| Step | Wall-clock | Cost |
|---|---|---|
| 0. Preflight | 2 min | $0 |
| 1. Kickoff → BUDGET_GATE | 2 min | $0 |
| 2. Review estimate | 5 min | $0 |
| 3. Dispatch → EVAL (provision+bootstrap+train+monitor+eval) | 45-90 min | $1-5 |
| 4. Review QUALITY + approve | 15 min | $0 (EC2 idle billing during review) |
| 4b. QUANTIZE+REGISTER+TEARDOWN | 15-20 min | $0.30-0.80 |
| 5. Manual public flip | 15 min | $0 |
| **Total to "demo URL is live"** | **~2 hr** | **~$2-6** |

**CPU path (quota pending) is the same flow, ~2-4 hr instead of 2 hr,
same cost profile** (t3.xlarge $0.166/hr × 3 hr ≈ $0.50).

---

## Reference: what the forge_id looks like

`forge-2026-04-24-publications-abc123`

- Date = UTC start date
- Slug = `publications` (from `kickoff-real-forge.sh`)
- Suffix = random 6 chars

You'll paste this forge_id into every follow-up command. Write it down the
moment kickoff prints it.

---

## One-liner kickoff (the "I know what I'm doing" path)

If you've run through once and just want to repeat with same defaults:

```bash
cd <PROJECT_HOME> && \
  bash slm-forge/scripts/preflight.sh && \
  bash slm-forge/scripts/kickoff-real-forge.sh && \
  echo "Now review + resume manually per TOMORROW.md Step 3+"
```

(Note: this still stops at BUDGET_GATE on purpose. No full auto-drive —
human approval is a feature, not a bug.)
