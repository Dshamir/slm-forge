# slm-forge — KNOWN ISSUES

Filed issues from forge runs that should be addressed in the slm-forge codebase before subsequent domain forges (MED, LEG, FIN, LIT, ...). Each issue: source run, classification, target version, acceptance criteria.

Convention: ✅ RESOLVED issues stay listed (with the run that fixed them) for regression-test reference. 🔧 OPEN issues are pending. 📋 PROPOSED issues are recommendations from runs that didn't ship a fix.

---

## ISSUE #1 — `forge-analyze-token-estimator`: file-size token estimate is wildly wrong on mixed-media corpora

**Source run:** `20260425-163412-4b31` (dental v0-preview)
**Status:** 🔧 OPEN
**Severity:** HIGH (affects budget projection + base-model fit + plan acceptance for every domain forge)
**Target:** `slm-forge` v2.4

**Symptom**
- Corpus: 11 GB / 1547 files
- analyze.json estimated `722,944,801` raw tokens (file-size based heuristic)
- Actual extracted: `1,904,443` raw tokens (~380× over-estimate)
- Synth cost projected $358; actual $6.49 (55× over-estimate after audit retention)
- Plan accepted Qwen2.5-7B + 5hr training because corpus appeared "large enough." With actual corpus, 7B was overfit territory.

**Root cause**
`scripts/forge-analyze/run.sh` derives `estimated_raw_tokens` from `du -sb` × characters-per-byte / chars-per-token. This heuristic assumes the bytes are text. For corpora that include video (.mp4), 3D meshes (.stl/.obj/.vtp), MySQL DB binaries (.frm/.MYI/.MYD), images (.png/.jpg), Excel binary headers (.xlsx), and other non-text content, the estimate is meaningless.

**Acceptance criteria for fix**
- [ ] `forge-analyze` extracts text from a 1-2% random sample of files using the same plugins prep would use
- [ ] Multiplies sampled token count by 1/sample_fraction to project total
- [ ] Reports `estimated_raw_tokens` AND `extraction_sample_pct` AND `confidence_band: low|medium|high` (where low = <50% of files in formats that yielded text in the sample)
- [ ] Stores per-file-type token-yield rates so forge-plan can pick a more-realistic clean-token estimate

---

## ISSUE #2 — orchestrator try/except around plugin calls

**Source run:** `20260425-163412-4b31` (dental v0-preview)
**Status:** ✅ RESOLVED in `20260425-163412-4b31` patch
**Severity:** HIGH (was — every plugin bug killed full walk)
**Resolution:** `prep-orchestrator.py walk()` now wraps `yield from plugin.iter_chunks(...)` in try/except, appends to `failures` list, continues to next file. Stats include `plugin_failure_count` and first 20 failures. File as confirmation regression test.

**Regression test required**
- [ ] Plant a deliberately-broken plugin (e.g., one that always raises) on one file extension, run prep, verify walk completes and `plugin_failure_count` reflects the broken plugin's hits.

---

## ISSUE #3 — subtopic mapper abs-vs-rel path bug

**Source run:** `20260425-163412-4b31` (dental v0-preview)
**Status:** ✅ RESOLVED in `20260425-163412-4b31` patch
**Severity:** HIGH (silently broke per-subtopic gate)
**Resolution:** `derive_subtopic` now receives `Path(source_file).relative_to(raw_dir)` instead of raw absolute path. Plus a 12-case test verifying the mapper.

**Lesson reinforcement**
The original smoke test for `derive_subtopic` used hand-crafted relative-path inputs and passed all 12 cases. The bug was that the FUNCTION CALLER passed absolute paths from plugin output. Unit tests at the function level are insufficient when integration is possible without obvious failure mode. **Future forge skills should include integration tests with real plugin output, not just function-level fixtures.**

**Regression test required**
- [ ] Integration test: feed real plugin output (with absolute `source_file`) through orchestrator with a non-empty `subtopic-map.json`, verify rows emerge with subtopic populated according to map.

---

## ISSUE #4 — synth metadata.subtopic propagation regression

**Source run:** `20260425-163412-4b31` (dental v0-preview)
**Status:** ✅ RESOLVED in `20260425-163412-4b31` patch
**Severity:** HIGH (broke axis3b per-subtopic gate downstream)
**Resolution:** `synth.py synth_one()` now extracts `source_subtopic` from doc metadata; emit block includes `subtopic` in `metadata`. 5,875 Q/A pairs in v0 backfilled from cleaned.jsonl join.

**Regression test required**
- [ ] After synth, sample 20 random Q/A pairs and assert `metadata.subtopic` is non-null and matches the source chunk's subtopic.

---

## ISSUE #5 — `forge-classify` skill (promote `classify-proceedings.py` + `classify-references.py` from sidecars to first-class skill)

**Source run:** `20260425-163412-4b31` (dental v0-preview) — used `scripts/classify-proceedings.py` (43 papers across 15 venues) and `scripts/classify-references.py` (73 papers, 24 dropped)
**Status:** 🔧 OPEN
**Severity:** MEDIUM (every domain has multi-topic venues + reference folders; current pattern is per-run sidecar)
**Target:** `slm-forge` v2.4

**Acceptance criteria**
- [ ] New skill `slm-forge/skills/forge-classify/` with `run.sh` + `classify.py` + `SKILL.md`
- [ ] Generic interface:
  - `--folders <comma-list>` of paths to classify
  - `--labels <comma-list>` of valid labels (or path to JSON config)
  - `--prompt-template <name>` to pick the rubric (subtopic_classify | keep_drop | other)
  - `--output` writes per-file decisions to `subtopic-map.json files{}` OR a separate JSON
- [ ] Provides built-in templates: subtopic-classification (multi-class, like proceedings); keep/drop binary (like references)
- [ ] Cost-tracked: emits `classify-stats.json` with input/output tokens + USD
- [ ] Optional `--spot-check N` flag emits a markdown file with N stratified samples for human verification before committing decisions

---

## ISSUE #6 — `axis3b_qa_per_subtopic` (per-subtopic plan-fit gate) confirmed

**Source run:** `20260425-163412-4b31` (dental v0-preview)
**Status:** ✅ RESOLVED in `20260425-163412-4b31` patch
**Severity:** MEDIUM (without it, aggregate-only gate misses subtopic collapses)
**Resolution:** `forge-plan-fit/plan_fit.py` now computes per-subtopic mean/min, gates with `min_qa_mean_per_subtopic` + `min_qa_individual_per_subtopic` + `min_n_for_gate`. Skips when <2 mapped subtopics.

**Regression test required**
- [ ] Construct a synthetic Q/A set where one subtopic mean is below threshold and others pass, verify axis3b fails the gate; flip and verify it passes.
- [ ] Construct a single-subtopic Q/A set, verify axis3b reports `skipped: true`.

---

## ISSUE #7 — `forge-plan-fit` threshold coherence

**Source run:** `20260425-163412-4b31` (dental v0-preview)
**Status:** 🔧 OPEN
**Severity:** LOW (workaround: lower aggregate threshold manually)
**Target:** `slm-forge` v2.4

**Symptom**
Aggregate threshold (`plan_fit_min_qa_mean = 4.0` in plan template) was set independently of per-subtopic floor (`FORGE_PLAN_FIT_MIN_QA_MEAN_PER_SUBTOPIC = 3.5`). When per-subtopic gate passed but aggregate stayed below 4.0 because the largest bucket was at 3.7, the run failed despite per-subtopic acceptance. Required manual edit to plan.json.

**Acceptance criteria**
- [ ] When `axis3b_qa_per_subtopic` is enabled, `forge-plan` template auto-sets `plan_fit_min_qa_mean` = `plan_fit_min_qa_mean_per_subtopic` (same value, gates align)
- [ ] OR: document the relationship in `forge-plan/SKILL.md` so plans don't drift apart

---

## ISSUE #8 — `forge-skill-force-rerun-flag` (universal manifest-bypass env var)

**Source run:** `20260425-163412-4b31` (dental v0-preview)
**Status:** 🔧 OPEN
**Severity:** MEDIUM (debugging requires S3 manifest surgery)
**Target:** `slm-forge` v2.4

**Symptom**
After modifying `qa-filtered.jsonl` (filtered off-topic references), I needed to re-run `forge-shape`. The skill's idempotency check on `manifest.artifacts.shaped_corpus_s3` short-circuited, returned `idempotent: true` in 1 sec, leaving stale train/val/test on S3. Required: download manifest via boto3, set `shaped_corpus_s3 = null`, upload, re-fire dispatch.

**Acceptance criteria**
- [ ] Every forge skill with manifest-artifact idempotency reads `FORGE_<PHASE>_FORCE_RERUN=1` env var; if set, bypasses the manifest check and runs unconditionally
- [ ] Skills affected (audit by SKILL.md grep): `forge-shape`, `forge-eval`, `forge-quantize`, `forge-register`, possibly `forge-bootstrap` and `forge-train`
- [ ] After successful rerun, the skill OVERWRITES the manifest artifact (not appends) so subsequent runs see fresh state

---

## ISSUE #9 — references-folder per-paper classification (covered by ISSUE #5)

**Source run:** `20260425-163412-4b31` (dental v0-preview)
**Status:** 🔧 OPEN (pattern; specific dental case captured)
**Resolution path:** ISSUE #5 (`forge-classify` skill) covers this generically.

DLATeeth-references contained 73 papers, of which 24 were off-topic ML methodology (drug design, NLP, generic GNN, DeepSDF, StyleGAN, cerebrovascular). The pattern is: any project's "references" or "cited literature" folder will contain papers broader than the project's actual research, because authors cite from broader fields than they publish in. Per-paper classification (#5) handles this.

---

## ISSUE #10 — `forge-model-card-out-of-scope-required`

**Source run:** `20260425-163412-4b31` (dental v0-preview)
**Status:** 📋 PROPOSED
**Severity:** LOW-MEDIUM (model card quality + downstream-safety)
**Target:** `slm-forge` v2.5+

**Acceptance criteria**
- [ ] `forge-register` model-card template requires an `out_of_scope` section
- [ ] The section is auto-populated from:
  - audit phase's `drops_by_reason` (e.g., "drop_chunk_type ⇒ model has no spreadsheet-reading capability")
  - classification drops (e.g., "drug_design, NLP, GNN-survey papers excluded")
  - operator-named exclusions in `manifest.spec.out_of_scope` (currently free-form; should become required field at intake)
- [ ] Manifest's `out_of_scope` becomes required at `forge-intake` time

---

## ISSUE #11 — `forge-plan-base-model-fit-check`

**Source run:** `20260425-163412-4b31` (dental v0-preview)
**Status:** 🔧 OPEN
**Severity:** MEDIUM (prevents over-spending on misfit base + LoRA configs)
**Target:** `slm-forge` v2.4

**Symptom**
Plan picked Qwen2.5-7B + r=32 LoRA based on corpus estimate of 96M clean tokens. Actual corpus 1.6M clean tokens / 5,875 Q/A pairs. At r=32 LoRA on 7B: ~67M trainable params for ~5,875 examples = overfit territory. Switched to 3B mid-pipeline; plan was misfit from the start.

**Acceptance criteria**
- [ ] `forge-plan` includes a fit check: `(qa_pairs × avg_output_tokens) / lora_trainable_params` should be ≥ `min_tokens_per_param` threshold (default 0.05; tune empirically)
- [ ] If projected ratio falls below threshold, plan auto-recommends smaller base or smaller LoRA rank
- [ ] Refusal mode if ratio is catastrophically low (e.g., <0.005 = 200× under-fit)

---

## Cross-cutting: integration testing against actual plugin output

**Source run:** `20260425-163412-4b31` (dental v0-preview)
**Status:** 📋 PROPOSED — NOT a single issue but a methodology gap
**Severity:** MEDIUM (multiple v0 bugs would have been caught earlier)

The v0 abs-vs-rel-path bug (#3) was missed because the pre-commit smoke test used hand-crafted relative-path inputs. The function passed; the integration didn't. Same shape with synth metadata propagation (#4) — function-level test would pass; integration test was needed.

**Acceptance criteria for fix**
- [ ] `slm-forge/tests/integration/` directory with end-to-end fixtures for each phase
- [ ] CI runs an integration test on every skill change: build a tiny corpus (5-10 files), run prep + audit + synth + shape on it, verify expected metadata fields propagate through every phase
- [ ] Function-level unit tests stay (cheap, fast) but no longer count as primary verification

---

## Triage / Roadmap

| Priority | Issue | Target version | Effort |
|---|---|---|---|
| P0 | #1 forge-analyze token estimator | v2.4 | M (sample-extract, ~half-day) |
| P0 | #5 forge-classify skill (covers #9) | v2.4 | M (promote sidecars to skill, ~half-day) |
| P1 | #8 force-rerun env var (universal) | v2.4 | S (per-skill 5-line addition) |
| P1 | #11 base-model fit check | v2.4 | S (math + threshold lookup) |
| P1 | Integration testing methodology | v2.4 | L (~1 day to set up CI fixture; ongoing) |
| P2 | #7 threshold coherence | v2.4 | S (template adjustment) |
| P2 | #2/#3/#4/#6 confirmation regression tests | v2.4 | M (unit + integration tests, ~half-day) |
| P3 | #10 model card out-of-scope required | v2.5 | M (template change + manifest field + register hook) |

Total estimated upstream work to land all P0/P1 fixes: **~3-4 person-days** before next domain forge.

---

*Last updated: 2026-04-25 — initial filing from dental v0-preview run.*

---

## Issues filed from forge run `20260425-163412-4b31` post-eval recovery (2026-04-26)

The following 7 issues were surfaced during the post-eval phase recovery (quantize → register → card_validator → smoketest → teardown → report). All are filed alongside the original 11 from the same run; none have been mitigated upstream yet.

## ISSUE #12 — `forge-quantize` hardcodes `-DGGML_CUDA=ON` for llama.cpp build

**Source run:** `20260425-163412-4b31`
**Status:** 🔧 OPEN
**Severity:** HIGH (blocks every quantize phase on AMIs without nvcc on PATH; current behavior 100% failure rate)
**Target:** `slm-forge` v2.4

**Symptom**
forge-quantize attempts `cmake -DGGML_CUDA=ON ..` to build llama.cpp on the EC2 instance. The forge AMI has CUDA libraries but not nvcc on PATH, so cmake fails with `CMAKE_CUDA_COMPILER-NOTFOUND`. Build aborts after ~2-3 min, before any compilation happens. Quantize phase fails. Operator must manually rebuild llama.cpp CPU-only (`-DGGML_CUDA=OFF`) and re-execute.

**Root cause**
Quantization (`llama-quantize` + `convert_hf_to_gguf.py`) is a CPU-only operation. There is no benefit to building llama.cpp with CUDA support for the quantize phase. The CUDA-on default is wrong for this purpose.

**Acceptance criteria**
- [ ] forge-quantize uses `-DGGML_CUDA=OFF -DCMAKE_BUILD_TYPE=Release` for the build
- [ ] If a CUDA-enabled binary is needed for some other purpose (it isn't), document it as a separate flag
- [ ] Document in SKILL.md that quantize is CPU-only

---

## ISSUE #13 — `forge-quantize` and `forge-register` disagree on manifest schema for `quantized_s3`

**Source run:** `20260425-163412-4b31`
**Status:** 🔧 OPEN
**Severity:** HIGH
**Target:** `slm-forge` v2.4

**Symptom**
`forge-register` (line 87-90 of run.sh) reads `manifest.artifacts.quantized_s3.{Q4_K_M,Q8_0}.uri` and `.bytes` (object schema). When operators or earlier phases write `quantized_s3.Q4_K_M = "s3://..."` (string schema, simpler), register fails with `jq: Cannot index string with string "uri"`. The schemas drift silently.

Plus: `forge-register` (line 160) hardcodes the S3 path `weights/quantized/model-*.gguf`, NOT reading from the URI in the manifest. So even with correct schema, the file must be at the hardcoded path.

**Acceptance criteria**
- [ ] Document the canonical schema for `manifest.artifacts.quantized_s3` (object form)
- [ ] forge-quantize writes that schema verbatim
- [ ] forge-register reads URI from manifest as the actual download source (don't hardcode the S3 path)
- [ ] OR: hardcode the path consistently across all phases and reduce manifest to a presence boolean

---

## ISSUE #14 — Dispatcher's `on_failure` "tearing down" message is a lie (instance keeps running)

**Source run:** `20260425-163412-4b31`
**Status:** 🔧 OPEN
**Severity:** HIGH (operator may walk away thinking instance is dead → indefinite billing)
**Target:** `slm-forge` v2.4

**Symptom**
On phase failure, dispatch-v2 emits `on_failure: phase=X rc=N — tearing down`, then writes `failure-report.md`, then exits. The "tearing down" claim is logged but **the EC2 instance is not actually terminated.** Verified across 3 separate failures in this run (eval, quantize, register, card_validator, smoketest) — instance state stayed `running` after each `on_failure` exit.

When the operator finally fired the proper teardown phase (via dispatch resume after all earlier failures), THAT teardown succeeded — instance went `shutting-down` correctly. So the teardown LIB works; the on_failure path fails silently or doesn't call it.

**Acceptance criteria**
- [ ] `on_failure` either guarantees terminate via lib/compute_aws.sh:terminate_instance, or doesn't claim "tearing down" in the log
- [ ] If terminate fails, log the failure explicitly and instruct operator to manually run `bash scripts/teardown-run.sh <run-id>`
- [ ] Add a `forge-status <run-id>` helper that reports both state-machine status AND live EC2 state, so operators don't trust state.json claims

---

## ISSUE #15 — `forge-card-validator` reads `state.artifacts.hf_repo` but `forge-register` writes nowhere

**Source run:** `20260425-163412-4b31`
**Status:** 🔧 OPEN
**Severity:** HIGH (every card_validator phase fails after register on first run unless operator manually patches state)
**Target:** `slm-forge` v2.4

**Symptom**
`forge-register` outputs `hf_repo` and `hf_space` URLs in its JSON stdout (which the dispatcher logs), but writes them nowhere persistent. `forge-card-validator` then reads `state.artifacts.hf_repo` and finds it empty.

Manual workaround: operator extracts URLs from register's stdout and writes them to `state.artifacts.hf_repo` / `.hf_space` before card_validator runs.

**Root cause: dispatcher does not merge skill output JSON into state.json.** Each skill's output is logged but not parsed/merged. Skills that need to communicate downstream must write to `manifest.json` themselves, or there must be a state-merge layer.

**Acceptance criteria**
- [ ] dispatch-v2 parses skill stdout JSON and merges expected fields into state.json (or manifest)
- [ ] OR: forge-register explicitly writes hf_repo/hf_space to state AND manifest before exit
- [ ] OR: forge-card-validator reads from manifest (which forge-register IS writing to — verified)
- [ ] Document the data-flow contract per phase in SKILL.md

---

## ISSUE #16 — `forge-card-validator` bash arithmetic crash on edge-case inputs

**Source run:** `20260425-163412-4b31`
**Status:** 🔧 OPEN
**Severity:** MEDIUM (validator hard-crashes instead of cleanly reporting)
**Target:** `slm-forge` v2.4

**Symptom**
forge-card-validator/run.sh:96 has `(( N_PLACEHOLDERS > 0 ))`. When the README's placeholder grep returns 0 matches, the pipeline `grep -oE ... | sort -u | jq -R . | jq -sc .` produces empty output, and `N_PLACEHOLDERS=$(echo "" | jq 'length')` evaluates to a multi-line "0\n0" string somehow. The bash arithmetic context can't parse it: `((: 0\n0: syntax error in expression`.

Validator hard-crashes rather than reporting "0 placeholders found, all clean." The actual validator logic would have PASSED.

**Acceptance criteria**
- [ ] Quote the variable and trim whitespace: `if [[ "${N_PLACEHOLDERS//[[:space:]]/}" -gt 0 ]]`
- [ ] OR: explicitly `tr -d '\n'` after jq to ensure single-line numeric output
- [ ] Add input-validation tests for the validator with empty README + placeholder-free README + leak-free README

---

## ISSUE #17 — `forge-card-validator` required sections list is rigid; my README's section names didn't match

**Source run:** `20260425-163412-4b31`
**Status:** 📋 PROPOSED
**Severity:** LOW (workaround: rename sections)
**Target:** `slm-forge` v2.5+

**Symptom**
Validator hardcodes required headings: `## Model Details`, `## Limitations`, `## How to Use`. Operator-drafted README used `## Training recipe`, `## Known limitations`, `## How to use` (lowercase u). Validator flagged all three as missing.

**Acceptance criteria**
- [ ] Document the required headings in `forge-register/SKILL.md` so operators draft cards that pass validation
- [ ] OR: relax the matcher (case-insensitive, accept synonyms — "Limitations" matches "Known limitations")
- [ ] OR: emit a non-fatal warning when sections are missing rather than failing the gate

---

## ISSUE #18 — `forge-smoketest` Space failure: private Space cannot fetch private model GGUFs without HF_TOKEN secret

**Source run:** `20260425-163412-4b31`
**Status:** 🔧 OPEN
**Severity:** HIGH (every private-only forge will fail smoketest until Space is configured with auth)
**Target:** `slm-forge` v2.4

**Symptom**
forge-register pushes a Gradio Space whose `app.py` does `hf_hub_download(...gguf/model-Q4_K_M.gguf...)` against the private model repo. The Space runs as anonymous user with no HF_TOKEN configured. Result: `RepositoryNotFoundError: 401 Client Error`. Space stays in `RUNTIME_ERROR` stage. forge-smoketest probes the Space, sees runtime error, fails the gate.

For private-only forges (v0-preview workflow), this is a configuration gap, not a code bug.

**Acceptance criteria**
- [ ] forge-register, when publishing a private Space, sets HF_TOKEN as a Space secret automatically (using `huggingface_hub.add_space_secret`)
- [ ] OR: forge-register's Space `app.py` template reads the GGUF from a public mirror, or embeds it directly
- [ ] OR: for `private: true` runs, forge-smoketest skips the live-Space probe and instead does a local llama-cpp-python load test (no Space dependency)

---

## ISSUE #19 — `forge-report` doesn't pull eval data into after-action.md / qa-report.md

**Source run:** `20260425-163412-4b31`
**Status:** 🔧 OPEN
**Severity:** MEDIUM
**Target:** `slm-forge` v2.4

**Symptom**
The auto-emitted `after-action.md` shows:
- Eval summary table: `Perplexity ? ? ?`
- Inputs: `Base model: (missing)`
- Plan vs reality: `Total cost actual: $0` (wrong; we know we spent ~$41)

Auto-emitted `qa-report.md` shows:
- "EVAL (not run)" — wrong, eval ran and produced full perplexity.json + samples.md
- "CARD_VALIDATOR ****" — empty status
- "Probe response: (none)" — wrong, smoketest had a real response (or skip rationale)

forge-report is reading from somewhere that doesn't have the data, and doesn't pull from the actual eval output files in the run dir.

**Acceptance criteria**
- [ ] forge-report reads `perplexity.json`, `samples.md`, `comparison-vs-baseline.md`, `local-smoketest-results.json`, `plan-fit-report.json`, etc. directly from the run dir
- [ ] If a file is missing, the report should say so explicitly (not "(not run)" — say "FILE MISSING" or "could not be located")
- [ ] Cost actual should be pulled from manifest.cost_ledger or computed from EC2 + Anthropic API spend ledger
- [ ] Add a regression test: small fixture run end-to-end, assert key metrics appear in after-action.md

---

