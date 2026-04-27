# POST-MORTEM — Forge Run `20260425-163412-4b31`

> **Status:** Final. Second end-to-end production forge through the v2 plan-executor — the first to genuinely stress the per-subtopic stratification and gate machinery. Surfaced 8 distinct latent bugs across the post-eval phases (quantize → register → card_validator → smoketest → report) plus 4 architectural / strategic findings. Model published public for the IntelliDent / PolyMtl team to validate before v1.
>
> **Outcome:** Model published with caveats. ~$44 spend (synth $6.49 + classifications $0.50 + plan-fit grading × 4 ~$1.20 + GPU ~$36). 25 hours wall-clock — ~10 hr training + 15 hr recovery surgeries. 4-criterion combining-rule verdict landed PUBLISH-WITH-CAVEATS (criteria 1+2 READY, 3+4 CAVEATS).

---

## Tabular Summary

| | |
|---|---|
| Run id | `20260425-163412-4b31` |
| Forge id | `v2-20260425-163412-4b31` |
| Pipeline | v2 plan-executor (16 phases — `publish` deliberately removed pre-resume) |
| Phases completed | 16 / 16 |
| Phase failure events | 8 (eval, quantize, register, card_validator ×2, smoketest, monitor-reads-stale, report-emits-sparse) |
| Distinct bugs surfaced | 8 (see KNOWN_ISSUES #12–#19) |
| Bugs already fixed in source this session | 8 (the prior-session ones from 2026-04-24); 0 of the new 8 (all filed for v2.4 upstream — manual workarounds applied this run) |
| Manual operator interventions | 14 (state.json edits, manifest patches via boto3, S3 multipart copies, README rewrites, Space secret config, instance terminate) |
| Strategic findings | 4 (corpus 50× smaller than estimated, base-model 7B-not-3B propagation gap, per-subtopic gate caught real contamination, on_failure-doesn't-teardown systemic) |
| Final verdict | PUBLISH-WITH-CAVEATS |
| HF model | https://huggingface.co/Nexless/dental-research-slm-0m-20260426-4b31 |
| HF Space | https://huggingface.co/spaces/Nexless/dental-research-slm-0m-20260426-4b31-demo |
| KNOWN_ISSUES filed | 19 total; 8 added this run |

---

## 1. What Each Phase Was Implicitly Testing (new vs. carried-over)

This run was the first to exercise per-subtopic stratification + Haiku-assisted folder/reference classification end-to-end. Several phases were carrying additional tests they hadn't faced in 2026-04-24.

| Phase | New test in this run |
|---|---|
| `analyze` | Token estimate from file size on a heavily mixed-media corpus (11 GB containing video, STL, MySQL DB binaries, xlsx) — exposed 380× over-estimate |
| `prep` | (a) Subtopic injection from `subtopic-map.json` path-prefix mapper; (b) plugin try/except around `iter_chunks` with failures tracked in stats; (c) 4 file-format edge cases (silent .mp4, .vtp polygons, .frm MySQL binaries, xlsx with embedded charts) |
| `audit` | (a) Three new filters: `drop_chunk_types={row,ocr}`, `min_words=30`, `near_dup_threshold=0.80` (was 0.85); (b) Per-subtopic chunk count surfacing in stats |
| `synth` | `metadata.subtopic` propagation from input chunk to output Q/A pair |
| `shape` | Stratified split by `metadata.subtopic` with within-subtopic deterministic shuffle + cross-subtopic interleave; replaces the previous flat awk shuffle |
| `plan_fit` | (a) New `axis3b_qa_per_subtopic` gate — fail if any mapped subtopic with n≥3 graders has mean<3.5 OR worst<2.0; (b) Threshold alignment between aggregate axis3 (4.0) and per-subtopic axis3b (3.5) |
| `eval` | Per-subtopic perplexity + per-subtopic 2-seed sample generations + per-subtopic table in `comparison-vs-baseline.md` |
| `quantize` | (Implicitly) llama.cpp build-from-scratch — exposed hardcoded `-DGGML_CUDA=ON` failing on missing nvcc PATH |
| `register` | (Implicitly) manifest schema reconciliation with quantize output — exposed string-vs-object disagreement |
| `card_validator` | (Implicitly) data flow from register's stdout → state.json — exposed dispatcher-doesn't-merge-skill-output gap |
| `smoketest` | (Implicitly) private-Space-fetches-private-model auth chain — exposed missing HF_TOKEN secret on private Spaces |
| `report` | (Implicitly) eval-data presence in auto-emitted markdown — exposed sparse output when fields aren't pulled from run dir |

---

## 2. Errors Found and Repaired (or filed for upstream)

### 2.1 Pre-eval phases — fixes committed to source this session

| # | File | Symptom | Root cause | Fix (this session) |
|---|---|---|---|---|
| 1 | `scripts/prep_plugins/video.py` | `ImportError: attempted relative import with no known parent package` when extracting from .mp4 files | `from audio import PLUGIN` (non-relative) caused `audio.py`'s `from .orchestration_helpers import clean_text` (relative) to fail when imported via the non-relative path | Switched to proper relative import: `from . import audio as _audio; audio_plugin = _audio.PLUGIN` |
| 2 | `scripts/prep_plugins/tabular.py` | `AttributeError: 'Chartsheet' object has no attribute 'iter_rows'` when extracting from xlsx with embedded charts | `wb.sheetnames` returns names of all sheets including chartsheets; `wb[sheet_name]` returns a Chartsheet object which has no row data | Skip Chartsheet objects: `if not hasattr(ws, "iter_rows"): continue` before the row iteration |
| 3 | `scripts/prep-orchestrator.py` | One bad file killed the entire walk, discarding all prior chunks | No try/except around `yield from plugin.iter_chunks(...)` | Wrapped in try/except with `failures: list` arg passed by reference; failures appended with `{path, ext, plugin, error}`; `plugin_failure_count` and first 20 failures emitted in `prepped-stats.json` |
| 4 | `scripts/prep-orchestrator.py` | Subtopic mapper fell to `_default` for every chunk; expected per-subtopic distribution was 4636/0/0/0 instead of stratified | Plugins set `metadata.source_file` as absolute path; `subtopic-map.json` keys are relative paths; `startswith()` always returned False | `Path(source_file).relative_to(raw_dir)` normalization before mapper lookup |
| 5 | `skills/forge-prep/run.sh` | Subtopic mapper feature inert | run.sh didn't pass `--subtopic-map` flag to orchestrator | Added conditional: if `<run-dir>/subtopic-map.json` exists, pass it through |
| 6 | `skills/forge-shape/run.sh` | Test set didn't include all subtopics; eval lost statistical power on small buckets | Flat awk shuffle then linear slice — random within whole corpus | Replaced with Python: per-subtopic deterministic shuffle (seeded `forge_id+subtopic`), 90/5/5 within each, final cross-subtopic interleave shuffle of train/val/test buffers separately |
| 7 | `skills/forge-plan-fit/plan_fit.py` | Aggregate axis3 PASS could mask one-subtopic collapse | No per-subtopic gate | Added `axis3b_qa_per_subtopic`: per-subtopic mean/min from graded sample; fails if any mapped subtopic with n≥3 has mean<3.5 OR worst<2.0; skips when <2 mapped subtopics seen |
| 8 | `skills/forge-audit/audit.py` | Margin_line bucket was 44% of corpus chunks but 70% of those were spreadsheet rows + image OCR garbage | Audit only checked LLM-slop / off-domain / dedup; no chunk_type or min-words filters | Added 3 env-var-driven filters: `FORGE_AUDIT_DROP_CHUNK_TYPES` (default empty, set to `row,ocr` this run), `FORGE_AUDIT_MIN_WORDS` (default 0, set to 30 this run), `FORGE_AUDIT_NEAR_DUP_THRESHOLD` (default 0.85; set to 0.80 to catch paper drafts) |
| 9 | `scripts/eval.py` | No per-subtopic perplexity in eval output | `compute_perplexity` was called once on aggregate test set | Added `from collections import defaultdict`, preserved subtopic during test-doc load (`test_records: list[(text, subtopic)]`), per-subtopic perplexity loop for both merged and baseline, per-subtopic 2-seed sample generations, per-subtopic table in `comparison-vs-baseline.md`, `per_subtopic_*` fields in `perplexity.json` summary |
| 10 | `skills/forge-synth/synth.py` | `axis3b` per-subtopic gate received "unmapped" for every Q/A | synth didn't propagate `metadata.subtopic` from input chunk to output Q/A pair | Added `source_subtopic` extraction in `synth_one()` + `subtopic` field in emit metadata |
| 11 | `scripts/dispatch-v2.sh` | No way to pause pipeline at a known phase for human review without hand-stopping the dispatcher process | No `STOP_AFTER_PHASE` mechanism | Added `STOP_AFTER_PHASE` env var honored after `completed_phases += [phase]` write — exits cleanly with state consistent so resume just re-runs without the env var |
| 12 | `scripts/train.py` | (User-added in prior session, lands with this commit) Calibration callback aborts training early if observed sec/step exceeds budget | Defensive behavior against slow-training cost overruns | `_CalibrationCallback` measures sec/step on steps 20..calibration_steps; if rate > threshold, raises `RuntimeError` to abort. Disable with `FORGE_CALIBRATION_STEPS=0` |

### 2.2 Post-eval phases — workarounds applied + filed for upstream

| # | KNOWN_ISSUES | File | Symptom | Root cause | Workaround this run |
|---|---|---|---|---|---|
| 13 | #12 | `skills/forge-quantize/run.sh` | llama.cpp build failed at CMake CUDA detection on AMI without nvcc | Hardcoded `-DGGML_CUDA=ON`; quantize doesn't need GPU | SSH-built `llama-quantize` CPU-only on the running EC2 (`-DGGML_CUDA=OFF`); ran convert + quantize manually; uploaded to S3 |
| 14 | #13 | `skills/forge-register/run.sh` line 87-90 | `jq: Cannot index string with string "uri"` reading `.artifacts.quantized_s3.Q4_K_M.uri` | Quantize never populated manifest (failed earlier); my manual fill used string schema; register expects `{uri, bytes}` object schema | Re-uploaded GGUFs to `weights/quantized/` (the path register actually reads from), wrote `{uri, bytes}` schema to manifest. Q8_0 (8.10G) hit the 5GB single-copy limit; used EC2 aws CLI for multipart server-side copy |
| 15 | #14 | `scripts/dispatch-v2.sh` `on_failure` | "tearing down" logged but instance stayed `running` after eval, quantize, register, card_validator failures | `on_failure` path doesn't actually call `terminate_instances` (or fails silently) | Confirmed via boto3 each time; instance only terminated when the eventual `teardown` phase fired in the resume |
| 16 | #15 | `skills/forge-card-validator/run.sh` line 20 | `card-validator: no hf_repo in state — REGISTER must run first` despite register having succeeded | Dispatcher does not merge skill stdout JSON into state.json; register writes hf_repo to manifest but card_validator reads state | Manually wrote `state.artifacts.hf_repo` and `state.artifacts.hf_space` from register's logged URLs |
| 17 | #16 | `skills/forge-card-validator/run.sh` line 96 | `((: 0\n0: syntax error in expression` — bash arithmetic crash on edge-case `jq 'length'` output | When grep finds 0 placeholders, `jq -sc .` of empty input produces multi-line output; `(( N_PLACEHOLDERS > 0 ))` fails to parse "0\n0" | (Triggered after first card_validator pass; resolved when the README's required headings issue was fixed and the placeholder grep returned cleanly) |
| 18 | #17 | `skills/forge-card-validator/run.sh` line 70-74 | All 3 required headings flagged missing | Validator hardcodes `## Model Details` / `## Limitations` / `## How to Use`; my drafted README used `## Training recipe` / `## Known limitations` / `## How to use` (lowercase u) | Renamed sections to match validator + added a Model Details block at top |
| 19 | #18 | `skills/forge-smoketest/run.sh` | Space stage `RUNTIME_ERROR` — `RepositoryNotFoundError: 401` fetching private GGUF | Private Space's app.py tries to download Q4_K_M from private model repo without HF_TOKEN secret | (a) For dispatch flow: skipped smoketest with documented `smoketest-report.json`; (b) Post-publish: added HF_TOKEN as Space secret via `huggingface_hub.HfApi.add_space_secret`; restarted Space; verified `runtime.stage=RUNNING` |
| 20 | #19 | `skills/forge-report/run.sh` | Auto-emitted `after-action.md` and `qa-report.md` had: "Perplexity ? ? ?", "Base model: (missing)", "Total cost actual: $0", "EVAL (not run)" | Report doesn't read from the run dir's eval output files (perplexity.json, samples.md, etc.) | Manually filled `qa-report.skeleton.md` and `comparison-vs-baseline.skeleton.md` with eval data; `local-smoketest-results.json` written with Ollama Q4_K_M PASS evidence |

---

## 3. Architectural / Strategic Findings

### 3.1 Corpus tokens were 50× over-estimated by file-size heuristic

`forge-analyze` projected 722 M raw tokens from an 11 GB corpus; actual extraction yielded 1.9 M raw → 1.6 M clean (after 51% audit retention with the new chunk-type filters). 380× over-estimate at raw, 55× over-estimate at synth cost. **Cause:** mixed-media corpus dominated by non-text bytes (467 STL meshes, 1575 xlsx rows, 6 silent MP4s, MySQL DB binaries, image files). The file-size heuristic assumes bytes-are-text. Filed as KNOWN_ISSUES #1; fix is to sample-extract before estimating.

The downstream effect was subtle but expensive: `forge-plan` selected Qwen2.5-7B + r=32 LoRA based on the 96 M token clean-corpus estimate. Actual corpus is too small for that scale — the 1.61× train-vs-held-out ratio in the final eval is the overfitting signature this misfit produced.

### 3.2 Local plan.json edit did not propagate to S3 manifest — base-model swap was silently ignored

Mid-run, after eval surfaced the corpus-50×-smaller signal, the operator switched plan.json's `base_model` from 7B to 3B. `forge-plan-fit` (which reads local plan.json) saw 3B and recalculated axis7 budget. But `forge-train` reads from S3 manifest, which `forge-plan` populated with 7B at first plan-time. **Two sources of truth disagreed silently.** Training proceeded on 7B for 9.7 hours.

This is documented in KNOWN_ISSUES under #15 (forge-register doesn't write hf_repo to state) and is part of a broader pattern: the dispatcher does not maintain a single source of truth for plan parameters across phases. Filed as a structural concern; fix is either (a) state-merge layer in dispatcher, or (b) all skills read from the same canonical store (manifest), with local plan.json being a read-only operator-edit interface that triggers manifest update.

### 3.3 Per-subtopic gate caught real corpus contamination

The `axis3b_qa_per_subtopic` gate (added this run) caught a single Q/A about graph-NN drug design that came from `Zhou2019_GraphNN-ReviewMethodsApps.pdf` — a paper in `DLATeeth-references/` that the team had read but is **not about dentistry.** Aggregate axis3 would have passed (mean 3.86, individual ≥2.0); axis3b correctly identified the dental_ai_general bucket as having a worst-individual=1 score driven by the off-topic content.

Resolution path was: (a) Haiku-classify the 73-paper references folder for dental relevance, drop 24 off-topic; (b) re-grade — axis3b passes, no violators. **The gate did exactly what it was designed to do.** Validates the design choice; first real-world catch.

### 3.4 Recovery surgeries cost 15 hours of GPU billing on top of 10 hours of actual training

Out of 25 hours wall-clock, only 10 was real training. The other 15 was recovery: eval re-runs (with the SSM-timeout workaround), quantize manual rebuild, register schema fixes, card_validator iterations, smoketest auth-chain debugging. Each phase failure in the post-eval block left the EC2 running while the operator diagnosed and patched. **`on_failure: tearing down` claim is the single most expensive lie in the dispatcher** — every false-teardown was hours of idle billing.

Cost wasn't catastrophic (instance is g5.2xlarge at $1.456/hr; net overrun ~$22), but on a larger instance (g5.12xlarge at $5.67/hr or g6e at $4.40/hr) the same recovery sequence would have been $80–$140 of pure idle. Filed as #14, severity HIGH.

---

## 4. What's Now Permanent in Source vs Still Open

### Permanent (committed this run)

12 fixes from §2.1 land in the source tree. The pre-eval pipeline (prep → audit → synth → shape → plan_fit) is meaningfully more robust than before this run:

- Plugin error tolerance (§2.1 #3)
- Subtopic-aware end-to-end (§2.1 #4, #5, #6, #9, #10)
- Per-subtopic gate (§2.1 #7)
- Audit content-quality filters (§2.1 #8)
- STOP_AFTER_PHASE for staged execution (§2.1 #11)
- Calibration callback for early train-rate detection (§2.1 #12)

Plus 2 sidecar scripts (`scripts/classify-proceedings.py`, `scripts/classify-references.py`) that are functional one-off tools — see §5 for promotion to first-class skill.

### Still open (KNOWN_ISSUES)

8 issues filed this run (#12–#19), 19 total in the slm-forge tree. Highest priority for v2.4:

- **P0 — #1** `forge-analyze` token estimator (corpus-shape determines plan correctness)
- **P0 — #5** `forge-classify` skill (promote sidecar scripts)
- **P0 — #12** `forge-quantize` CPU-only build default
- **P0 — #14** `on_failure` actually tears down
- **P1 — #8** Universal `FORGE_<PHASE>_FORCE_RERUN=1` env var
- **P1 — #11** `forge-plan` base-model fit check
- **P1 — #13** Manifest schema agreement quantize↔register
- **P1 — #15** Dispatcher merges skill output to state OR registers writes to state
- **P1 — #18** Private-Space HF_TOKEN secret auto-config

See `slm-forge/KNOWN_ISSUES.md` for full details + acceptance criteria per issue.

---

## 5. Skills Upgrade Plan (existing skills that need work)

### High-priority upgrades for v2.4

| Skill | Required change | Why |
|---|---|---|
| `forge-analyze` | Replace `du -sb` × chars-per-token heuristic with sample-extract estimator (1-2% of files run through prep plugins, scaled). Emit `extraction_sample_pct`, `confidence_band`, per-format yield rate. | KNOWN_ISSUES #1. Without this, every plan is sized against a fictional token count, base model selection is wrong (saw it cost us this run). |
| `forge-plan` | Add base-model fit check: compute `(qa_pairs × avg_output_tokens) / lora_trainable_params`; auto-recommend smaller base or smaller LoRA rank when the ratio is below threshold. | KNOWN_ISSUES #11. Catches the misfit before training fires. |
| `forge-plan-fit` | Auto-align `plan_fit_min_qa_mean` (axis3) with `plan_fit_min_qa_mean_per_subtopic` (axis3b) when axis3b is enabled, OR document the relationship in `forge-plan/SKILL.md` so they don't drift. | KNOWN_ISSUES #7. The 4.0 vs 3.5 disagreement caused a manual edit this run. |
| `forge-quantize` | Default to CPU-only llama.cpp build (`-DGGML_CUDA=OFF`); CUDA flag becomes opt-in and only meaningful for non-quantize use cases. Write `quantized_s3` to manifest in the schema register expects. | KNOWN_ISSUES #12, #13. 100% failure rate on AMIs without nvcc PATH. |
| `forge-register` | (a) Read GGUF source from manifest URI (not hardcoded path). (b) Add HF_TOKEN as Space secret automatically when registering a private Space. (c) Write `hf_repo` and `hf_space` to BOTH state.json (`.artifacts.*`) AND manifest, so every downstream skill can find them regardless of which it queries. | KNOWN_ISSUES #13, #15, #18. |
| `forge-card-validator` | (a) Quote/trim the `N_PLACEHOLDERS` etc variables to handle empty-input edge cases without bash arithmetic crash. (b) Loosen required-section matcher (case-insensitive synonym match: `## Limitations` matches `## Known limitations` etc) OR document the strict required headings in the model-card template forge-register uses. (c) Read `hf_repo` from manifest as fallback when state.json is empty. | KNOWN_ISSUES #15, #16, #17. |
| `forge-smoketest` | Skip the live-Space probe when target was registered as private (the v0-preview workflow). For private targets, do a local llama-cpp-python load test of the GGUF instead — no Space dependency. | KNOWN_ISSUES #18. Removes a structural false-fail from the private-only happy path. |
| `forge-eval` | Use nohup-detached execution + separate SSM polling, not single SSM command with default 1-hour execution timeout. Or: explicitly set `executionTimeout` to match expected eval duration (4-6 hr for 7B + baseline + samples). | This run's eval first-attempt failure mode. Not yet filed; should add as #20. |
| `forge-monitor` | Read live `/workspace/logs/train.log` directly (parse the latest tqdm line for current step + sec/step) rather than polling a stats file that updates infrequently. | This run's monitor heartbeat reported step=250 frozen for hours while training was actually past step 1000. Filed as #21 below. |
| `forge-report` | Pull eval data from run dir directly: `perplexity.json`, `samples.md`, `comparison-vs-baseline.md`, `local-smoketest-results.json`, `plan-fit-report.json`. Cost actual from manifest cost ledger or computed from spend records. Fail loudly with "FILE MISSING" rather than silently emitting `?` or `(not run)`. | KNOWN_ISSUES #19. |
| `dispatch-v2` | (a) Merge skill stdout JSON into state.json after each phase complete (parse the `next_phase` and any `artifacts.*` fields). (b) `FORGE_<PHASE>_FORCE_RERUN=1` universal bypass for manifest idempotency. (c) `on_failure` either guarantees terminate via lib/compute_aws.sh, or rebrands message as "manual teardown required" and outputs the exact command. | KNOWN_ISSUES #8, #14, #15. |

### Documentation upgrades (no code change)

| Skill | What to add |
|---|---|
| All skills | Document each skill's read/write data flow per phase: what inputs from manifest/state, what outputs to manifest/state, what to file system. Currently it's implicit and skill-author-discretionary. |
| `forge-plan` | Document the relationship between local `plan.json` and S3 `manifest.json` — operators who edit local plan.json need to know the manifest is what training actually reads. |
| `forge-prep` SKILL.md | Document the `subtopic-map.json` schema (prefixes / files / _default) and the absolute-vs-relative-path normalization expected of the mapper input. |
| `forge-quantize` SKILL.md | State explicitly that quantize is CPU-only — no GPU dependency, no CUDA in build path. |

---

## 6. New Skills To Add

### Priority order

1. **`forge-classify`** (P0) — Promote `scripts/classify-proceedings.py` and `scripts/classify-references.py` to a first-class skill at `skills/forge-classify/`. Generic interface:

   ```
   /forge-classify --folders <comma-list> \
                   --labels <comma-list>  (or path to JSON config)
                   --prompt-template <subtopic_classify | keep_drop | other>
                   --output <path-to-write>
                   [--spot-check <N>]
   ```

   Built-in templates: subtopic-classification (multi-class, like proceedings); keep/drop binary (like references); on-/off-topic with reasoning. Cost-tracked via `classify-stats.json`. Optional spot-check emits a markdown file with N stratified samples for human verification before committing decisions. Reusable across domains — every dental / medical / legal / financial corpus has multi-topic venues + reference folders that need this.

2. **`forge-recovery`** (P1) — Codify the recovery surgery pattern. When a phase fails, operator runs `/forge-recovery <run-id>` and gets:
   - Read `failure-report.md` and pinpoint the failed phase
   - Pull instance state, manifest state, S3 artifacts
   - Suggest specific recovery actions per known failure pattern (e.g., "quantize CUDA-build failure → here's the CPU-only commands to run")
   - Optionally execute the recovery
   
   This skill is meta-tooling — it operationalizes the 14 manual interventions from this run's recovery surgeries. Saves the next operator hours.

3. **`forge-card-pre-validate`** (P1) — Pre-validate a model card draft against `forge-card-validator`'s rules BEFORE register pushes it. Lets operator iterate locally (`/forge-card-pre-validate <run-id>`) until clean, then register doesn't get bounced.

4. **`forge-distribution-test`** (P2) — Automated GGUF distribution smoketest. Local Ollama load + sample inference on Q4_K_M and Q8_0; local llama-cpp-python load (proxy for LM Studio). Emits `distribution-test-report.json`. Replaces the current manual local-smoketest-results.json process. Should be a standalone skill so it can be invoked without a live forge run (e.g., on any HF model + GGUF combo).

5. **`forge-corpus-cardinality`** (P2) — Pre-flight skill that estimates per-format token yield from a small sample. Walks corpus, samples 1-2% of each detected format, runs through prep plugins, computes yield rate per format. Produces a `cardinality-report.json` that `forge-analyze` can consume for realistic token estimates. (If `forge-analyze` upgrade in §5 is done, this skill becomes its sample-extract phase factored out for reusability.)

6. **`forge-status` v2** (P3) — `forge-status` exists; upgrade to also report:
   - Live EC2 state (terminated / running / hibernated)
   - Live Space stage
   - HF repo visibility
   - Cost-to-date from spend ledger
   - All in one screen, so operator never has to query 4 services to know "where is my run actually."

---

## 7. Regression Checklist for Next Run (v2 dental retraining or first MED/LEG/FIN run)

Verify before running:

- [ ] Corpus token estimate from `forge-analyze` is reality-grounded (sample-extract or prior-run-based, not file-size heuristic). KNOWN_ISSUES #1 done.
- [ ] Prep plugin try/except still in place. Run with one deliberately-broken plugin to confirm walk completes + `plugin_failure_count` populated. KNOWN_ISSUES #2 regression test.
- [ ] Subtopic mapper resolves absolute paths via `relative_to(raw_dir)`. KNOWN_ISSUES #3 regression test — feed real plugin output, verify subtopic populated.
- [ ] Synth propagates `metadata.subtopic` to Q/A pairs. Sample 20 random Q/A, assert subtopic is non-null and matches source chunk. KNOWN_ISSUES #4 regression test.
- [ ] Per-subtopic gate (axis3b) fires with correct semantics (synthetic Q/A set with one bad subtopic → gate fails; flip → gate passes). KNOWN_ISSUES #6 regression test.
- [ ] Plan-fit thresholds aligned: aggregate `plan_fit_min_qa_mean` matches per-subtopic floor when axis3b enabled. KNOWN_ISSUES #7.
- [ ] Quantize uses CPU-only build by default. KNOWN_ISSUES #12.
- [ ] Manifest schema matches across quantize and register (`{uri, bytes}` object form for `quantized_s3.*`). KNOWN_ISSUES #13.
- [ ] `on_failure` actually terminates EC2 (or rebrands message). KNOWN_ISSUES #14.
- [ ] Dispatcher merges skill stdout into state OR register writes hf_repo to state. KNOWN_ISSUES #15.
- [ ] Card_validator robust to empty grep output (no bash arithmetic crash). KNOWN_ISSUES #16.
- [ ] Card_validator section names matcher is case-insensitive synonym OR documented strict list. KNOWN_ISSUES #17.
- [ ] Forge-register sets HF_TOKEN as Space secret on private Spaces. KNOWN_ISSUES #18.
- [ ] Forge-report pulls eval data from run dir. KNOWN_ISSUES #19.
- [ ] Base-model fit check fires in plan when corpus is too small for selected model. KNOWN_ISSUES #11.

---

## 8. Cost / Time Accounting

All figures are this-run-specific; the patterns generalize.

| Line | Estimate (plan) | Actual |
|---|---|---|
| Synth (Haiku 4.5 on 2,370 chunks) | $358 | $6.49 (55× over-estimate cause: corpus 50× smaller than analyze projected) |
| Plan-fit grading × 4 reruns | $1.20 | $1.20 |
| Folder + references classification (Haiku) | n/a | $0.50 |
| GPU (g5.2xlarge × 25 hr) | $5.10 (planned 3.5 hr at 3B) | $36 (actual 25 hr at 7B + 15 hr recovery idle) |
| **Total** | **$365.78** | **~$44** (8.0× under estimate) |

**Time:** ~10 hr training was on plan; ~15 hr was recovery. The recovery time is the operationally interesting figure — see §3.4 for the on_failure-doesn't-teardown root cause that allowed the 15 hours to accrue.

---

## 9. Sits Alongside

- `slm-forge/KNOWN_ISSUES.md` — 19 filed issues with acceptance criteria
- `slm-forge/.runs/20260425-163412-4b31/v2-forge-spec.md` — v2 build specification
- `slm-forge/.runs/20260425-163412-4b31/model-card-draft.md` — the polished v0-preview model card
- `slm-forge/.runs/20260425-163412-4b31/qa-report.skeleton.md` — filled QA report (supersedes the sparse auto-emitted version)
- `slm-forge/.runs/20260425-163412-4b31/decimation-corpus-list.md` — relic of the rejected decimation-add path; kept as evidence per the discipline lesson early in the session

---

*Built end-to-end by SLM-Forge inside the SIF skill tree. NEXLESS™ LP, 2026.*
