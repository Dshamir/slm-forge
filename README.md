<p align="center">
  <img src="https://github.com/user-attachments/assets/c93f0dcd-456f-48a0-bc96-b589ead27c19" alt="SLM-Forge banner" width="100%">
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Dshamir/slm-forge?color=blue" alt="License: MIT"></a>
  <a href="https://huggingface.co/Nexless/dental-ai-research-slm-0m-20260425-3845"><img src="https://img.shields.io/badge/%F0%9F%A4%97%20HuggingFace-Live%20case%20study-yellow" alt="HuggingFace model"></a>
  <a href="https://docs.claude.com/en/docs/claude-code"><img src="https://img.shields.io/badge/Built%20with-Claude%20Code-D97757?logo=anthropic&logoColor=white" alt="Built with Claude Code"></a>
  <a href="docs/V2-FORGE-SPEC.md"><img src="https://img.shields.io/badge/Spec-V2--FORGE-informational" alt="V2-FORGE-SPEC"></a>
  <img src="https://img.shields.io/badge/status-PoC-orange" alt="Status: PoC">
  <a href="https://github.com/Dshamir/slm-forge/stargazers"><img src="https://img.shields.io/github/stars/Dshamir/slm-forge?style=social" alt="GitHub stars"></a>
  <a href="https://github.com/Dshamir/slm-forge/commits/main"><img src="https://img.shields.io/github/last-commit/Dshamir/slm-forge" alt="Last commit"></a>
</p>

---

# SLM-Forge

> A skill tree that takes you from **"here's a corpus and a goal"** to a **trained, evaluated, quantized, and published Small Specialty Language Model** — from the Claude Code CLI, on AWS, in a single session, with a **single human gate**, with **interactive live monitoring** (PID-recall to reattach to long-running training), **automatic error detection + correction** (calibration burst, plan-fit refusal, on-failure EC2 teardown), **self-diagnostic** failure reports, and a **corpus-adaptive prep pipeline** that auto-routes 18+ extensions through 19 file plugins + 10 DB adapters with no manifest authoring required.

---

**SLM-Forge is a Proof of Concept** of **semi-autonomous skills running inside the Claude Code TUI**, developed by [Nexless](https://huggingface.co/Nexless). It published its first end-to-end model on 2026-04-25:

🦷 **Live case study →** [`Nexless/dental-ai-research-slm-0m-20260425-3845`](https://huggingface.co/Nexless/dental-ai-research-slm-0m-20260425-3845) — a research-methodology assistant for dental-AI papers (Qwen2.5-7B + QLoRA r=32 on 320 papers, $11.62 AWS spend, 9 h wall-clock).

The dental model is published **for educational purposes only** as part of a broader experiment testing how narrow-domain corpora, plan-fit pre-spend gates, abstention contracts, and skill-tree-driven training pipelines compose into a publishable, scope-honest small model. **This repo is the toolkit.** The dental run is the worked example.

---

## What is this?

SLM-Forge is **17 cooperating Claude Code skills** that orchestrate the full SLM lifecycle. You give it:

- a directory of mixed-format documents (or a JSONL Q/A file, or a YAML multi-source manifest), and
- a budget in USD.

It runs **preflight → analyze → plan**, stops at **one** human-readable gate (`plan.md` — review the cost, the regime, the corpus stats), and then on `approve` runs autonomously through prep → audit → synth → shape → plan-fit → provision → bootstrap → train → monitor → eval → quantize → register → smoketest → publish → teardown → report. Tears down the EC2 on any failure. Emits two markdown deliverables when done: `after-action.md` (URLs + cost + samples) and `qa-report.md` (gate-by-gate PASS/FAIL).

The point is **scope-honest small models**, not LLM-grade general assistants:

- **Specialty.** Train on 100 K – 5 M tokens of one narrow domain.
- **Cheap.** Most full runs land between $5 and $50 in compute.
- **Quick.** End-to-end in 4 – 12 hours wall-clock.
- **Honest.** Abstention contracts + plan-fit gates surface scope failures *before* you ship.
- **Local.** Q4_K_M GGUF runs on a laptop.

---

## What you can expect from a run

These are the four properties to actually internalize before invoking the forge — they're what separates this toolkit from "wrap a script around `huggingface-cli`":

### 🔭 Interactive live monitoring (PID-recall)

When a run enters the autonomous spend stage, it spawns `dispatch-v2.sh` in the background on the operator host and posts a heartbeat to S3 (`s3://<YOUR_S3_BUCKET>/forge/<run-id>/manifest.json`) at every phase boundary. You can:

- Tail `dispatch.log` for stdout/stderr.
- Re-attach to a running training PID hours later from a different shell — the `forge-monitor` skill recalls the PID + EC2 instance ID + S3 manifest version from the canonical state object, polls the training process, and resumes streaming progress without losing context.
- Detach freely. The EC2 keeps training, the manifest keeps advancing, the operator host can sleep, lose its tunnel, or be replaced.
- See `lib/manifest.sh:manifest_load` and `skills/forge-monitor/SKILL.md` for the contract.

### 🛠️ Automatic error detection + correction

Failures are *expected* and *handled* at every phase:

- **Calibration burst.** Steps 20–100 of training measure sec/step. If the rate exceeds `FORGE_CALIBRATION_MAX_SEC_PER_STEP` (default 27), the trainer aborts via `control.should_training_stop = True` and returns rc=12 (replan-needed). No 6-hour 1%-progress training session.
- **Plan-fit pre-spend gate.** Sonnet 4.6 grades a sample of synthesized Q/A on 7 axes *before* GPU spend. Fails fast on bad in-domain %, low Q/A score, blown budget, hyperparameter insanity, or ChatML roundtrip break.
- **On-failure teardown.** Every phase declares its failure mode + recoverability. Recoverable failures retry once with adjusted params; unrecoverable failures terminate the EC2 immediately, save partial state to S3, emit `failure-report.md`, and exit non-zero. **No frozen pipelines, no stranded EC2.**
- **Idempotent skills.** Each skill checks the manifest for prior completion before doing work; re-running a phase is safe.

### 🩺 Self-diagnostic failure reports

When a phase fails, the forge writes `failure-report.md` with:

- The exact rc + skill that failed
- The last 50 lines of `dispatch.log`
- The S3 path of partial state
- A suggested next action (`replan` / `retry` / `tear down + start over`)
- Links to the matching post-mortem in `docs/POST-MORTEM-*.md` if the failure mode has been seen before

The post-mortems in [`docs/POST-MORTEM-2026-04-24.md`](docs/POST-MORTEM-2026-04-24.md) and [`docs/POST-MORTEM-2026-04-26.md`](docs/POST-MORTEM-2026-04-26.md) are real artifacts from the dental v0 run — recommended reading for understanding the failure-mode catalog.

### 🧬 Corpus-adaptive ingestion

You point the forge at a directory and it figures out the rest. No manifest authoring, no per-format conversion scripts:

- **19 file plugins**: PDF / DOCX / PPTX / TXT / XLSX / CSV / PNG / JPG / TIF / HEIC / MP4 / m4a / wav / STL / VTP / OBJ / PLY / MyISAM (`.frm`/`.myi`/`.myd`/`.ibd`) / EPUB / code (`.py`/`.js`/`.ts`/`.cpp`/...) / notebooks / email (`.eml`/`.mbox`) / DICOM / HDF5 / GeoTIFF / ZIP / TAR / RAR
- **10 DB adapters**: MySQL / Postgres / Mongo / SQLite / DuckDB / MSSQL / ClickHouse / Snowflake / BigQuery / Cassandra
- **Multi-source YAML**: `templates/multi-source.example.yaml` lets you mix dirs + DBs + JSONL + HuggingFace datasets in one run
- **Smart filters built in**: MP4 whitelist (skip silent ≤120 s clips), OCR opt-out (`FORGE_DISABLE_OCR=1` for figure-heavy corpora), recursive archive extraction, language filter, MinHash dedup
- **Adaptive analyzer**: `forge-analyze` auto-detects format mix, estimates clean tokens after audit drop-rate, picks the base model + regime from a budget heuristic ladder

If a plugin is missing for your format, adding one is a single Python file in `scripts/prep_plugins/` — see `scripts/prep_plugins/__init__.py` for the dispatcher contract.

---

## Requirements

| | Minimum | Notes |
|---|---|---|
| **Claude Code CLI** | Latest (v2.x) | The orchestrator. [Install](https://docs.claude.com/en/docs/claude-code) |
| **Anthropic API access** | Claude Haiku 4.5 + Sonnet 4.6 access | Synth runs on Haiku, plan-fit grading on Sonnet, smoketest validator on Haiku. Budget the run cap accordingly (typical $5 – $30 in Claude calls per run). |
| **AWS account** | EC2 (g5.x quota), S3, KMS, IAM | g5.2xlarge (24 GB A10G) for 7B-QLoRA; g5.xlarge for 3B; g4dn for sub-1B. KMS-encrypted CAS bucket. |
| **HuggingFace account** | Free tier OK | Model + Space publishing. Token with `write` scope. |
| **Docker** | Engine ≥ 20 | Used to host `aws-cli` and `huggingface_hub` operations without polluting host Python. |
| **Local OS** | Linux / macOS | Tested on Ubuntu 24.04. WSL2 should work; native Windows untested. |
| **Disk** | ~50 GB free | For corpus prep + GGUF quantize staging. The forge stages everything to S3, so local footprint stays small mid-run. |
| **GPU (optional)** | Any CUDA GPU (≥ 8 GB) | A local burst-worker variant can run training on your workstation; the canonical pipeline runs on AWS. |

---

## Required credentials

All secrets live in environment variables. **No secrets are committed to this repo.** Map the placeholders below to your own values before running:

| Env var | What | Example |
|---|---|---|
| `ANTHROPIC_API_KEY` | Anthropic API key | `sk-ant-...` |
| `HF_TOKEN` | HuggingFace write token | `hf_...` (Settings → Access Tokens, role `write`) |
| `AWS_ACCESS_KEY_ID` | AWS IAM user with EC2/S3/KMS perms | scoped per `docs/HARDENING.md` |
| `AWS_SECRET_ACCESS_KEY` | matching AWS secret | |
| `AWS_DEFAULT_REGION` | Region (today: `ca-central-1`; v2 target: `us-east-1`) | |
| `FORGE_BUCKET` | Your CAS S3 bucket name | replaces placeholder `<YOUR_S3_BUCKET>` |
| `FORGE_KMS_ALIAS` | KMS alias for the CAS bucket | e.g. `alias/your-cas-key` |
| `FORGE_AWS_ACCOUNT_ID` | Your AWS account ID | replaces placeholder `<YOUR_AWS_ACCOUNT_ID>` |
| `FORGE_AWS_PROFILE` | AWS CLI profile (optional) | replaces placeholder `<YOUR_IAM_USER>` |

Drop them into `~/.env` (or wherever your shell sources from). The forge reads them at run start; missing-credential preflight fails fast before any API spend.

**One-time AWS setup:** see `docs/HARDENING.md` for the IAM policy, S3 bucket, KMS key, and per-resource tagging recipes. There's a setup script at `scripts/setup-aws.sh` (read it before running). Also see [`CONFIGURATION.md`](CONFIGURATION.md) for the full placeholder → env-var map.

---

## Architecture

> Full diagrams + design rationale: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Brief overview here.

### One human gate

```
PREFLIGHT → ANALYZE → PLAN
                           ↓
                    [ HUMAN APPROVES plan.md ]
                           ↓
PREP → AUDIT → SYNTH → SHAPE → PLAN-FIT (Sonnet 7-axis pre-spend) →
PROVISION → BOOTSTRAP → TRAIN → MONITOR → EVAL →
QUANTIZE → REGISTER → CARD-VALIDATOR → SMOKETEST → PUBLISH → TEARDOWN → REPORT
```

v1 had **four** gates (operators got woken up at 2 a.m. to approve mechanical decisions). v2 collapsed BUDGET into PLAN_GATE and replaced the post-train gates (QUALITY, CARD, SMOKETEST, PUBLISH) with automated thresholded checks. The result: you approve the **cost + regime + corpus** once at the start. Everything after that runs unattended, and the EC2 tears down on any failure.

### The 17 skills

| # | Skill | Phase | What |
|---|---|---|---|
| 1 | `slm-forge` | dispatcher | Routes the user's command to the next phase |
| 2 | `forge-preflight` | preflight | Checks creds + Docker + S3 reachability |
| 3 | `forge-analyze` | analyze | Detects corpus format, estimates tokens, reads target_use |
| 4 | `forge-plan` | plan | Picks base model, regime, hyperparams from a budget heuristic ladder |
| 5 | `forge-ingest` / `forge-ingest-db` | prep | 19 file plugins (PDF/DOCX/PPTX/TXT/XLSX/CSV/PNG/JPG/TIF/HEIC/MP4/m4a/wav/STL/VTP/OBJ/PLY/MyISAM/EPUB/code/notebooks/email/DICOM/HDF5/ZIP/RAR) + 10 DB adapters (MySQL/Postgres/Mongo/SQLite/DuckDB/MSSQL/ClickHouse/Snowflake/BigQuery/Cassandra) |
| 6 | `forge-audit` | audit | MinHash dedup + length filter + language filter + LLM-slop scrub + domain-density check |
| 7 | `forge-synth` | synth | Q/A pair generation via Claude Haiku 4.5 (factual / mechanism / clinical / discrimination / abstention templates) |
| 8 | `forge-shape` | shape | Train/val/test split (default 90/5/5), deterministic shuffle |
| 9 | `forge-plan-fit` | plan_fit | **Pre-spend gate.** Sonnet 4.6 grades a sample of the synthesized Q/A on 7 axes (in-domain %, subdomain coverage, factual+grounded score, type diversity, hyperparameter sanity, ChatML roundtrip, budget headroom). Fails fast before GPU spend. |
| 10 | `forge-provision` | provision | EC2 RunInstances on AWS, auto-retry across AZs |
| 11 | `forge-bootstrap` | bootstrap | Installs training stack + llama.cpp on the instance |
| 12 | `forge-train` | train | QLoRA SFT (4-bit NF4 base + bf16 LoRA) via HF Trainer; 100-step calibration burst aborts if sec/step > threshold |
| 13 | `forge-monitor` | monitor | Polls training PID, syncs checkpoints to S3 |
| 14 | `forge-eval` | eval | Perplexity vs baseline + 10 sample generations + auto artifact-rate checks |
| 15 | `forge-quantize` | quantize | Merges adapter into base, exports GGUF Q4_K_M + Q8_0 via llama.cpp |
| 16 | `forge-register` | register | Pushes HF model repo + Space + Modelfile + model card |
| 17 | `forge-card-validator` / `forge-smoketest` / `forge-publish` / `forge-teardown` / `forge-report` | terminal | D-018 leak grep + live API probe + flip public + EC2 terminate + after-action.md |

### Single source of truth: the manifest

Every run carries one canonical state object — `forge.state.json` at `s3://<YOUR_S3_BUCKET>/forge/<run-id>/manifest.json`. Every skill reads it, mutates it, persists it back via S3 versioning (optimistic concurrency). The `lib/manifest.sh` library does the read/patch/write dance; skills call `manifest_load` and `manifest_patch` and don't touch S3 directly.

---

## Playbook (Quickstart)

### 1. Clone + install

```bash
git clone https://github.com/Dshamir/slm-forge.git
cd slm-forge
# No pip install — the forge runs Python via Docker images
```

### 2. Set credentials

```bash
cp .env.example .env             # if .env.example exists; otherwise create .env
$EDITOR .env                     # fill in ANTHROPIC_API_KEY, HF_TOKEN, AWS_*
set -a && source .env && set +a
```

### 3. Register the slash command in Claude Code

```bash
# Symlink the skill tree into Claude Code's skill discovery path
ln -s "$PWD/skills" ~/.claude/skills/slm-forge
```

Or copy the `.claude/` config block from this repo into your Claude Code project.

### 4. Smoke-test against a tiny corpus

```bash
mkdir -p test-corpus
echo "MeshSegNet is an end-to-end deep learning method for tooth labeling..." > test-corpus/sample.txt

# In Claude Code:
/slm-forge ./test-corpus/ 5 --domain dental.research
```

This runs PREFLIGHT → ANALYZE → PLAN and writes `.runs/<new-id>/plan.md`. **Do not approve** — $5 budget will refuse at PLAN since 5 < 0.5B-base minimum cost. That's the gate working.

### 5. Real run

The forge has **two invocation patterns** — pick the one that matches what you're doing:

#### A. New run from a raw corpus

```bash
/slm-forge <target-directory-or-file> <budget-usd> [--domain <label>] [--name <slug>]
```

- `<target-directory-or-file>` — point at raw files (any mix of the 19 supported formats). Can also be a JSONL Q/A file or a multi-source YAML manifest (see `templates/multi-source.example.yaml`).
- `<budget-usd>` — total cap including Claude API + AWS + HF. Plan-fit refuses if the projected spend exceeds 1.2× this.
- `--domain` (optional) — domain label that scopes synth + plan-fit grading. Default: auto-detected from corpus.

Examples:
```bash
/slm-forge ./Publications/ 75                              # mixed PDF/DOCX → auto-prep + audit + synth
/slm-forge ./qa-data.jsonl 25 --domain dental.research     # pre-prepared Q/A → straight to train
/slm-forge ./multi-source.yaml 100                         # dir + DB + jsonl + HF dataset fan-out
```

#### B. Re-train / continuation from an existing run

```bash
/slm-forge .runs/$FORGE_ID/ <budget-usd> [--flag ...] [--training-plan <path>]
```

Pointing the forge at an existing `.runs/<id>/` directory tells it: **resume from this state**. Useful for:

- **Continuation training** (v0 → v0.1) — add new synth buckets, continue-train at lower LR for one epoch.
- **Re-quantize / re-publish** after fixing a model card or sampling default.
- **Apply a different training plan** without re-prepping the corpus (the audit + synth + shape outputs are already in S3 and re-used).

Use flags or a `--training-plan plan.yaml` to override regime / hyperparameters / sampling without re-walking the gate.

#### Approving + monitoring

After invocation, the forge runs PREFLIGHT → ANALYZE → PLAN and writes `.runs/<run-id>/plan.md`. Review the cost, regime, and corpus stats. Approve:

```bash
bash scripts/approve-plan.sh <run-id>
```

Dispatcher fires in the background. Three ways to monitor:

```bash
# 1. Tail the dispatch log
tail -f .runs/<run-id>/dispatch.log

# 2. Re-attach later (PID recall — works from any shell, any host with credentials)
/slm-forge monitor <run-id>

# 3. Poll the manifest directly (canonical state)
bash lib/manifest.sh manifest_load <run-id> | jq '.phase, .training_runtime'
```

When done (or on first failure + teardown), read:

- `.runs/<run-id>/after-action.md` — final URLs, cost, samples
- `.runs/<run-id>/qa-report.md` — gate-by-gate PASS/FAIL + verdict
- `.runs/<run-id>/failure-report.md` (only on failure) — diagnosis + suggested next action

### 6. Use the published model

```bash
# Ollama (terminal)
curl -L -O https://huggingface.co/<your-namespace>/<your-model>/resolve/main/Modelfile
ollama create your-model -f Modelfile
ollama run your-model

# Or load the LoRA adapter directly via PEFT (see the published model card)
```

---

## Worked example: the dental research SLM

The first model published with this toolkit lives at:

🦷 **[`Nexless/dental-ai-research-slm-0m-20260425-3845`](https://huggingface.co/Nexless/dental-ai-research-slm-0m-20260425-3845)**

| | |
|---|---|
| Base | Qwen/Qwen2.5-7B-Instruct |
| Regime | QLoRA r=32 α=64 (4-bit NF4 base + bf16 LoRA) |
| Trainable params | 20,185,088 (0.46 % of 4.37 B post-quantization) |
| Corpus | 320 dental-AI research papers (PDF/DOCX/PPTX/TXT) |
| Q/A pairs | 2,455 (factual + mechanism + clinical, synth via Claude Haiku 4.5) |
| Train wall-clock | 5 h 53 min on g5.2xlarge (1× A10G) |
| Total run wall-clock | 9 h 03 min |
| AWS + Claude spend | $11.62 |
| Plan-fit verdict | PASS (in-domain 100 %, Q/A grader mean 4.135 / 5) |

A **complete sanitized run** is included in this repo at [`examples/runs/20260425-163412-4b31/`](examples/runs/20260425-163412-4b31/). That's the v0-preview run on the same corpus — read its `plan.md`, `analysis.json`, `audit-report.json`, `plan-fit-report.json`, `model-card-draft.md`, `after-action.md`, and `failure-report.md` to see exactly what every phase emits.

A **post-mortem** of every bug surfaced during that run lives at [`docs/POST-MORTEM-2026-04-24.md`](docs/POST-MORTEM-2026-04-24.md) and [`docs/POST-MORTEM-2026-04-26.md`](docs/POST-MORTEM-2026-04-26.md). Recommended reading for students.

---

## Roadmap

### v0 — shipped 2026-04-25

The dental research SLM at [`Nexless/dental-ai-research-slm-0m-20260425-3845`](https://huggingface.co/Nexless/dental-ai-research-slm-0m-20260425-3845). First end-to-end run of this toolkit.

### v0.1 — continuation training (planned, ~3–4 h on A10G, ~$5)

Add three synth buckets to the existing Q/A set and continue-train the LoRA at LR=5e-5 for one epoch:

| Bucket | Pairs | Purpose |
|---|---|---|
| **Abstention pairs** | ~250 | Out-of-scope questions paired with the verbatim abstention response (3-4 phrasing variants), covering generic dental hygiene, orthodontics, periodontics, drug design, mesh decimation, dental insurance, cosmetic dentistry, oral cancer, TMJ, implants. Adds learned abstention behavior on top of the Modelfile's system-prompt enforcement. |
| **Method discrimination pairs** | ~150 | "What's the difference between [method A] and [method B]?" with explicit contrastive answers naming the actual differentiator: MeshSegNet vs iMeshSegNet (GLM vs EdgeConv), vs PointNet (mesh vs raw point cloud), vs TSGCNet (single vs dual stream), vs DGCNN; MC-Net vs MeshSegNet (completion vs segmentation). |
| **Negative-fact pairs** | ~100 | Explicit corrections ("Does MeshSegNet use 2D CNNs? No — MeshSegNet operates directly in 3D space on mesh cells"). Negation training is the underused trick — LLMs hallucinate confidently because they've never seen explicit corrections. |

### v2 — full re-forge with expanded scope ([V2-FORGE-SPEC.md](docs/V2-FORGE-SPEC.md))

The next major artifact. The full design lives in [`docs/V2-FORGE-SPEC.md`](docs/V2-FORGE-SPEC.md) — a 438-line spec covering target deliverable, expanded synth template set, calibrated cost model, manifest schema, and distribution targets.

**Goals of v2:**

1. **Wider corpus.** Move from `corpora/publications-raw/Publications` (4 file types, 320 docs) to the full IntelliDent archive — 1,547 files spanning 18 extensions across all 19 prep plugins (XLSX/CSV spreadsheets, MP4 narrated videos via faster-whisper, MyISAM EndNote bibliographies, STL/VTP/OBJ/PLY meshes, etc.).
2. **More Q/A pairs, more templates.** v0 used 3 templates (factual/mechanism/clinical) for 5,875 pairs. v2 expands to ~10 templates (adding discrimination, negative-fact, abstention, comparison, application, etc.) for 15,000–25,000 pairs.
3. **Calibrated cost model.** v0's analyzer over-estimated synth cost by 5×. v2 uses actual-spend regression from v0 to project realistic budgets.
4. **Tighter sampling + system-prompt by default.** v2 will bake scope contracts and abstention into the training loop, not just the inference Modelfile.
5. **Region migration.** v0 ran in `ca-central-1` (NVIDIA Inception credits target is `us-east-1`, but us-east-1 G+VT vCPU quota was 0 at v0 launch time). v2 stages on a feature branch + files the AWS quota request in parallel.

See [`docs/V2-FORGE-SPEC.md`](docs/V2-FORGE-SPEC.md) for the canonical spec, including the synth template catalog, manifest schema, distribution surfaces, and acceptance criteria.

---

## Repo layout

```
slm-forge/
├── README.md              ← this file
├── SKILL.md               ← Claude Code skill manifest for `/slm-forge`
├── KNOWN_ISSUES.md        ← surfaced issues + known workarounds
├── LICENSE                ← MIT
├── COLLABORATORS.md       ← maintainers + contributors
├── CONFIGURATION.md       ← env-var → placeholder mapping
├── skills/                ← 17 Claude Code skills (one per phase)
│   ├── forge-preflight/
│   ├── forge-analyze/
│   ├── forge-plan/
│   ├── forge-ingest/      ← 19 file plugins live here
│   ├── forge-ingest-db/   ← 10 DB adapters
│   ├── forge-audit/
│   ├── forge-synth/
│   ├── forge-shape/
│   ├── forge-plan-fit/
│   ├── forge-provision/
│   ├── forge-bootstrap/
│   ├── forge-train/
│   ├── forge-monitor/
│   ├── forge-eval/
│   ├── forge-quantize/
│   ├── forge-register/
│   ├── forge-card-validator/
│   ├── forge-smoketest/
│   ├── forge-publish/
│   ├── forge-teardown/
│   └── forge-report/
├── scripts/               ← entry points + utility scripts
│   ├── forge.sh           ← top-level CLI
│   ├── dispatch-v2.sh     ← phase orchestrator
│   ├── approve-plan.sh    ← single human gate
│   ├── teardown-run.sh    ← reject + clean up
│   ├── prep_plugins/      ← 19 file plugins (Python)
│   ├── train.py           ← QLoRA training script (HF Trainer)
│   └── render-template.py ← template renderer for model card / Modelfile / Space app
├── lib/                   ← shared bash libraries (no domain logic)
│   ├── manifest.sh        ← S3 versioned read/patch/write
│   ├── compute_aws.sh     ← AWS provider impl
│   ├── s3.sh              ← S3 helpers (CAS pattern)
│   └── hf.sh              ← HuggingFace API wrappers
├── templates/             ← model card / Modelfile / Space app templates
├── config/                ← base model whitelist + pricing snapshot
├── eval-sets/             ← held-out eval prompts per domain
├── tests/                 ← bash + pytest smoke tests
├── docs/
│   ├── ARCHITECTURE.md    ← full design + diagrams
│   ├── HARDENING.md       ← IAM scoping, KMS, secrets management
│   ├── V2-FORGE-SPEC.md   ← v2 spec (next major artifact)
│   ├── POST-MORTEM-2026-04-24.md  ← real failure report from v0 run (educational)
│   ├── POST-MORTEM-2026-04-26.md  ← real failure report from v0 run (educational)
│   ├── SYMPOSIUM-HANDOFF.md       ← demo-day handoff doc
│   └── TOMORROW.md        ← rolling open-questions list
└── examples/
    └── runs/
        └── 20260425-163412-4b31/   ← sanitized v0-preview run artifacts
            ├── plan.md
            ├── plan.json
            ├── analysis.json
            ├── audit-report.json
            ├── plan-fit-report.json
            ├── model-card-draft.md
            ├── after-action.md
            ├── failure-report.md
            ├── decimation-corpus-list.md
            └── comparison-vs-baseline.skeleton.md
```

---

## Collaborators

| | |
|---|---|
| **Maintainer** | Daniel Shamir ([@Dshamir](https://github.com/Dshamir)) — Nexless |
| **Orchestration** | Claude Code (Anthropic) — Opus 4.6 / 4.7 + Haiku 4.5 + Sonnet 4.6 |
| **Case-study collaborators** | Polytechnique Montréal IntelliDent group (corpus contributors for the dental research SLM v0; corpus content remains private — only the trained adapter + GGUFs are public) |
| **Issues / PRs** | Welcome at [Dshamir/slm-forge issues](https://github.com/Dshamir/slm-forge/issues) |

See [`COLLABORATORS.md`](COLLABORATORS.md) for the full contributor list + how to join.

---

## License

MIT. See [`LICENSE`](LICENSE).

The forge code is yours to use, modify, redistribute. **Models you train are yours** — SLM-Forge does not assert any rights over your trained artifacts. The dental case-study model at `Nexless/dental-ai-research-slm-0m-20260425-3845` is published under Apache-2.0 (inherited from Qwen2.5-7B-Instruct).

---

## ⚠️ Disclaimer

SLM-Forge is a **proof of concept** of semi-autonomous skills running inside the Claude Code TUI. The dental case study is published **for educational purposes only** as a capability test of **(Small) Specialty Language Models**. Any model you train with this toolkit is **your responsibility**: scope, license, training data provenance, intended use, and failure-mode disclosure are yours to set and document. **Models trained on medical / clinical data should not be used clinically without appropriate human-expert oversight and regulatory review.** SLM-Forge bakes scope-honesty primitives (plan-fit gates, abstention contracts, model-card validators) into the pipeline — but they're tools, not guarantees. Read the post-mortems before assuming "it just works."

---

*Forged with [Claude Code](https://docs.claude.com/en/docs/claude-code) — semi-autonomous skill orchestration in the terminal.*
