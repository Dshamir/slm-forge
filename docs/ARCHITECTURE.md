# SLM-Forge — Architecture Reference

This is the visual reference for the SLM-Forge skill tree. Four ASCII
diagrams cover the surface a new contributor needs to onboard:

1. **Top-level flow** — what the operator types and what comes back
2. **Phase tree** — how the input shape drives the phase sequence
3. **Cost & resource lanes** — which phase spends what, and what the
   blast radius of a failure is
4. **Ingestion stack** — the 19 plugins, 10 DB adapters, and 10 source
   kinds, plus how credentials flow

Read top-to-bottom on first encounter. Use as a reference card after.

---

## 1 — Top-level flow

The forge has **one human gate** (PLAN_GATE) sandwiched between a free
pre-spend stage and an autonomous spend stage. Everything else is
either deterministic, automated, or driven by `plan.json`.

```
   ┌──────────────┐   ┌──────────────┐   ┌────────────────┐
   │  ./corpus/   │   │  data.jsonl  │   │ config.yaml    │
   │  ~138 exts   │   │ pretrain or  │   │ multi-source   │
   │  19 plugins  │   │ chat format  │   │ 10 source kinds│
   └──────┬───────┘   └──────┬───────┘   └───────┬────────┘
          │                  │                   │
          └──────────────────┴───────────────────┘
                             │
              /slm-forge <target> <budget> [--domain]
                             │
                             ▼
              ┌───────────────────────────────┐
              │   PRE-SPEND  (free, ~1 min)   │
              │  ───────────────────────────  │
              │   forge-preflight             │
              │   forge-analyze               │
              │   forge-plan                  │
              └────────────────┬──────────────┘
                               ▼
              ┌───────────────────────────────┐
              │   PLAN_GATE  (HUMAN, ~5 min)  │ ◄── only human gate
              │   approve-plan.sh <run-id>    │     reads plan.md
              │   teardown-run.sh <run-id>    │     budget gate folded in
              └────────────────┬──────────────┘
                               ▼
              ┌───────────────────────────────┐
              │   DISPATCH-V2  (autonomous,   │
              │     ~60-120 min, GPU billed)  │
              │   reads plan.json.phase_seq   │
              │   on_failure → teardown EC2   │
              └────────────────┬──────────────┘
                               ▼
              ┌───────────────────────────────┐
              │   DELIVERABLES                │
              │   after-action.md  (URLs+$$)  │
              │   qa-report.md  (gate verdict)│
              └───────────────────────────────┘
```

**Why one gate, not four:** v1 had four human gates (BUDGET_GATE,
QUALITY_GATE, D-018 review, public-flip). Operators got woken up at
2am to approve mechanical decisions. v2 rolled BUDGET into PLAN_GATE
(the plan.md surfaces the cost projection upfront) and replaced
QUALITY / D-018 / public-flip with automated gates that fire inside
dispatch-v2 (`plan_fit`, `card_validator`, `smoketest`) without
operator involvement.

**Why three input shapes, not one:** the corpus you have determines
the work. A folder of PDFs needs `prep`. A pre-cleaned JSONL skips
straight to training. A multi-source `config.yaml` needs N sources
fanned out and merged before audit. `forge-analyze` classifies the
input and `forge-plan` writes the appropriate `phase_sequence` —
`dispatch-v2.sh` doesn't know or care what format came in.

---

## 2 — Phase tree (format-driven branching)

The phase sequence isn't hardcoded — it's derived from
`detected_format`. Four entry branches converge at `shape`, then run
the same compute pipeline.

```
                     forge-analyze classifies detected_format
                                    │
       ┌────────────────────┬───────┴────────┬──────────────────────┐
       │                    │                │                      │
  raw-documents      pretrain-jsonl     chat-jsonl       multi-source-config
       │                    │                │                      │
       ▼                    │                │                      ▼
   ┌───────┐                │                │                  ┌────────┐
   │ prep  │                │                │                  │ ingest │ ◄ fan-out
   └───┬───┘                │                │                  └────┬───┘
       ▼                    ▼                │                       ▼
   ┌───────┐            ┌───────┐            │                   ┌───────┐
   │ audit │            │ audit │            │                   │ audit │
   └───┬───┘            └───┬───┘            │                   └───┬───┘
       ▼                    ▼                │                       ▼
   ┌───────┐            ┌───────┐            │                   ┌───────┐
   │ synth │            │ synth │            │                   │ synth │
   └───┬───┘            └───┬───┘            │                   └───┬───┘
       │                    │                │                       │
       └────────────────────┴────────────────┴───────────────────────┘
                                    │
                                    ▼  ════ ALL PATHS CONVERGE ════
                              ┌─────────┐
                              │  shape  │   90/5/5 split
                              └────┬────┘
                                   ▼
                              ┌─────────┐
                              │plan_fit │   7-axis pre-spend gate
                              └────┬────┘   refuses → teardown, NO GPU spend
                                   │
══════════════════════════════════ │ ═══════════════════════════════════
        below this line spends GPU $ + HF API calls
══════════════════════════════════ │ ═══════════════════════════════════
                                   ▼
                              ┌─────────┐
                              │provision│   EC2 + cost-gate + AZ retry
                              └────┬────┘
                                   ▼
                              ┌─────────┐
                              │bootstrap│   install stack + bg llama.cpp
                              └────┬────┘
                                   ▼
                              ┌─────────┐
                              │  train  │   detached PID + 30s log sync
                              └────┬────┘
                                   ▼
                              ┌─────────┐ ◄┐
                              │ monitor │  │  poll every 120s
                              └────┬────┘ ─┘  until completed/failed
                                   ▼
                              ┌─────────┐
                              │  eval   │   artifact-pattern hard-fail
                              └────┬────┘
                                   ▼
                              ┌─────────┐
                              │quantize │   Q4_K_M + Q8_0 GGUF
                              └────┬────┘
                                   ▼
                              ┌─────────┐
                              │register │   HF model + Space (private)
                              └────┬────┘
                                   ▼
                              ┌─────────┐
                              │  card_  │   D-018 brand-leak grep
                              │validator│   fails → stays private
                              └────┬────┘
                                   ▼
                              ┌─────────┐
                              │smoketest│   live Space API probe
                              └────┬────┘
                                   ▼
                              ┌─────────┐
                              │ publish │   flips both repos public
                              └────┬────┘
                                   ▼
                              ┌─────────┐
                              │teardown │   terminate + Cost Explorer
                              └────┬────┘
                                   ▼
                              ┌─────────┐
                              │ report  │   after-action.md + qa-report.md
                              └─────────┘
```

**The three automated quality gates** are the load-bearing safety
features:

- `plan_fit` (pre-spend) — 7-axis content/coverage/Q&A/diversity/
  hyperparam/format/budget grading. Refusal here means **no GPU has
  been touched yet** — the cost is bounded by Claude tokens. This
  replaces the v1 post-train QUALITY_GATE.
- `eval` (post-train) — artifact-pattern detection on samples
  (repetition loops, GGUF tokenizer breakage, degenerate outputs).
  Refusal here tears down the EC2 and skips PUBLISH.
- `card_validator + smoketest` (pre-publish) — D-018 brand-leak grep
  on the model card and a live API probe of the HF Space. Refusal
  keeps both repos **private** so nothing broken ships.

**Idempotency** is enforced per-phase. Re-running `dispatch-v2.sh
<run-id>` skips completed phases (each phase reads its own
"already-done" sentinel — usually a manifest field or a file in
`$RUN_DIR/`). Recovery is therefore "re-run dispatch" — no special
resume logic needed for crashes mid-pipeline.

**`monitor` is a poll loop, not a long-running phase.** dispatch-v2
re-invokes monitor every 120s (`FORGE_MONITOR_POLL_SECONDS`) until
training reports terminal. Each invocation is single-shot and
stateless — ideal for re-attaching after a Claude CLI session loss.

---

## 3 — Cost & resource lanes

Knowing where money flows tells you where the failure blast radius
matters. The line that splits "free / Claude tokens" from "GPU spend"
is the most important fact in the whole architecture — everything
above it can be re-tried freely; everything below has a meter running.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  PHASE          COST     RESOURCE                FAILURE BLAST       │
   │  ──────────    ──────    ──────────────────      ─────────────────   │
   │  preflight     free      local                   blocks plan         │
   │  analyze       free      local + Claude Haiku    blocks plan         │
   │  plan          free      local                   refuses if >budget  │
   │ ─── PLAN_GATE ────── HUMAN ────────────────────────────────────────  │
   │  ingest/prep   free      local (+ docker/whisper) skips file         │
   │  audit         free      local                   filters chunks      │
   │  synth         tokens    Claude Haiku            stops if budget hit │
   │  shape         free      local + S3              raises if 0 chunks  │
   │  plan_fit      tokens    Claude Sonnet grader    REFUSES → teardown  │
   │ ─── GPU SPEND BEGINS ──────────────────────────────────────────────  │
   │  provision     gpu/hr    AWS EC2 (ca-central-1)  cost-gate           │
   │  bootstrap     gpu/hr    EC2 SSM                 hooks recoverable   │
   │  train         gpu/hr    EC2 GPU + S3 sync       OOM → recoverable   │
   │  monitor       gpu/hr    EC2 SSM poll            silent-OOM detector │
   │  eval          gpu/hr    EC2 GPU                 artifact% > threshold│
   │  quantize      gpu/hr    EC2 CPU + llama.cpp     gibberish → fail    │
   │  register      free      HF API + local docker   D-018 leak → fail   │
   │  card_validator free     local grep              keeps private       │
   │  smoketest     free      HF Space probe          keeps private       │
   │  publish       free      HF API                  flips public        │
   │  teardown      free      EC2 terminate + CE      cost reconciled     │
   │  report        free      local                   prints URLs + $$    │
   └──────────────────────────────────────────────────────────────────────┘
```

**Two cost classes that aren't obvious from the phase names:**

- `synth` and `plan_fit` spend Claude tokens (Haiku for synth, Sonnet
  for the plan_fit grader). At the symposium-demo size class this is
  $1-3, but on a multi-million-passage corpus it can dominate.
- `register` is **free** — the HF bandwidth meter doesn't tick at our
  size class. The cost band shown on plan.md is Claude tokens + EC2
  hours; HF cost is zero on the chart.

**The two recoverable failure modes:**

- `train` OOM → reduce batch size in `plan.json.training_overrides`,
  re-run dispatch — bootstrap is idempotent so it skips, train sees
  the OOM-killed PID is gone, restarts with new config
- `monitor` silent-OOM → `forge-resume` re-attaches; if the instance
  was spot-killed it cost-gates re-provisioning against the original
  budget cap and restores from the last S3 checkpoint

Everything else fails fast. dispatch-v2's on_failure handler always
terminates the EC2 — operators wake up to a clean state, never to a
frozen pipeline + live billing.

---

## 4 — Ingestion stack

This is the surface that the v2.2 → v2.3 work expanded. Three families
all converge on `prepped.jsonl` in the canonical schema, which is what
`forge-audit` consumes.

```
╔════════════════════════════════════════════════════════════════════════════╗
║   FILE-SHAPED  →  forge-prep  →  scripts/prep_plugins/  (19 plugins)       ║
╠════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║   pdf · docx · pptx · text_simple ───────── document family                 ║
║   epub · notebook · tabular ─────────────── office / data                   ║
║   code (30+ langs) ──────────────────────── code                            ║
║   archive (zip/tar.gz/7z/rar, depth ≤ 3) ── recursive (zip-slip safe)       ║
║   ocr (png/jpg/tif/heic) ────────────────── FORGE_DISABLE_OCR=1             ║
║   audio · video (faster-whisper) ────────── FORGE_DISABLE_TRANSCRIBE=1      ║
║   mesh_metadata (stl/vtp/obj/ply) ───────── sparse / metadata-only          ║
║   binary_metadata ───────────────────────── sparse fallback                 ║
║   mysql_revive (frm/myi/myd/ibd) ────────── docker mysql:8 → mysqldump      ║
║   email_plugin (eml/mbox) ───────────────── stdlib                          ║
║   dicom (dcm) ───────────────────────────── PHI-scrubbed (KEEP_PHI=1)       ║
║   geo (geojson/shp) ─────────────────────── pyshp for shapefiles            ║
║   scientific (h5/hdf5/nc) ───────────────── schema-only                     ║
║                                                                              ║
║                Schema guard (validate_chunk) on every write.                ║
║                                                                              ║
╚════════════════════════════════════════════════════════════════════════════╝
                                  │
╔═════════════════════════════════│══════════════════════════════════════════╗
║   QUERY-SHAPED  →  forge-ingest-db  →  adapters/  (10 DB kinds)             ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║   ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐      ║
║   │  Native SQL  │ │   Cloud DW   │ │    NoSQL     │ │     OLAP     │      ║
║   │ ──────────── │ │ ──────────── │ │ ──────────── │ │ ──────────── │      ║
║   │ sqlite       │ │ snowflake    │ │ mongodb      │ │ clickhouse   │      ║
║   │ postgres     │ │ bigquery     │ │ cassandra    │ │ duckdb       │      ║
║   │ mysql        │ │              │ │              │ │  +ATTACH     │      ║
║   │ mssql        │ │              │ │              │ │   parquet    │      ║
║   └──────────────┘ └──────────────┘ └──────────────┘ │   csv/json   │      ║
║                                                      └──────────────┘      ║
║                                                                              ║
║   Credentials:   env:VAR  ·  file:/path  ·  vault:mount/path#key            ║
║   Resolver:      lib/secrets.py  ·  TTL-cached (300s)                       ║
║   Stack-safety:  Secret(value, ref) wrapper hides .reveal() in repr/str     ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
                                  │
╔═════════════════════════════════│══════════════════════════════════════════╗
║   MULTI-SOURCE  →  forge-ingest  →  fanout.py  (10 source kinds)            ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║   config.yaml dispatches to:                                                ║
║                                                                              ║
║     local_dir   archive    http (retry+mirrors)   jsonl   hf_dataset        ║
║     database    git        s3 (+MinIO)            gcs     azure             ║
║                                                                              ║
║   options:                                                                   ║
║     dedup_across_sources  → first-source-wins (order matters)               ║
║     within-source dedup    → ALWAYS on (catches symlink loops)              ║
║                                                                              ║
║   safety rails:                                                              ║
║     --dry-run              → preview sizes + handler dispatch, no I/O        ║
║     disk pre-check         → refuses (rc=4) if free < 1.5x est              ║
║     overwrite refusal      → rc=3 unless FORGE_INGEST_FORCE=1               ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
                                  │
                                  ▼
                ┌─────────────────────────────────┐
                │  $RUN_DIR/prepped.jsonl         │
                │  ─────────────────────────────  │
                │  CANONICAL SCHEMA               │
                │  {id, format, text|messages,    │
                │   metadata: {source_file,       │
                │     source_format, section,     │
                │     doc_title, chunk_type,      │
                │     chunk_idx, char_count}}     │
                └────────────────┬────────────────┘
                                 ▼
                            forge-audit
```

**The invariant we protect.** Every plugin and every adapter MUST emit
records that pass `scripts/prep_plugins/schema.validate_chunk()`. The
orchestrator and the fan-out merge both call it before writing — off-spec
records are dropped with a logged reason, not silently propagated. This
is what lets `forge-audit / synth / shape` downstream stay
source-agnostic — they read a well-typed JSONL and don't care whether
it came from a PDF, a parquet file in S3, or a `git clone`.

**Two-tier dedup.** Within-source dedup always runs (catches symlink
loops, duplicate files in one directory, accidental query-overlap).
Cross-source dedup is opt-in via `options.dedup_across_sources` (default
true) and is **order-dependent** — the source listed FIRST in
`sources:` wins on duplicate text. Order your canonical source first.

**Plugin coverage philosophy.** Every file extension dispatches to
*some* plugin — even `binary_metadata` produces a sparse provenance
chunk for raw binaries. The forge **never silently drops a file**.
Sparse chunks are flagged `chunk_type: "metadata_only"` so
`forge-audit` can filter them when training-density matters more than
provenance completeness.

**Credentials never hit disk.** `lib/secrets.py` resolves `*_ref`
fields at connection time, caches resolved values in memory for 300s,
and `redact_for_logging()` scrubs every config echo before it lands in
`state.json`, `dispatch.log`, or `ingest-stats.json`. The `Secret()`
wrapper protects against the subtler leak — Python's traceback machinery
captures local frame variables on exception, and a plain `str` password
in a frame would be visible in the post-mortem dump. `Secret.__repr__`
returns `<Secret ref=env:PG_PASSWORD>` and `__str__` returns
`<REDACTED>` — adapters call `.reveal()` to actually use the value, and
every leak point is therefore grep-able.

---

## How the four diagrams compose

- **Diagram 1** is the contract — what the operator sees from the outside
- **Diagram 2** is the control flow — what `dispatch-v2.sh` does inside
  the autonomous stage
- **Diagram 3** is the operational impact — what spends, what breaks,
  and how big the blast is
- **Diagram 4** is the extension surface — where new plugins, adapters,
  and source kinds plug in without changing dispatch-v2 or the
  downstream pipeline

Adding a new file format = one plugin in `scripts/prep_plugins/` +
one entry in `_PLUGIN_MODULES`. Adding a new database = one adapter
in `skills/forge-ingest-db/adapters/` + one entry in `_ADAPTER_MODULES`.
Adding a new source kind to multi-source config = one handler in
`fanout.py` + one entry in `_HANDLERS`. Three pluggable registries,
all auto-discovery driven, no other surface knows or cares.

---

## See also

- `README.md` — operator-facing entry + prerequisites + the 19-skill table
- `SKILL.md` — master orchestrator skill card
- `docs/TOMORROW.md` — cold-start playbook
- `docs/HARDENING.md` — failure-injection rehearsals
- `slm-forge-brief/` — original v1 design brief (architectural context)
