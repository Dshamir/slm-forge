# SLM-Forge v2 Spec — Dental Research Acute (Production Run)

> **Status:** Draft authored 2026-04-25 during v0-preview eval phase, parallel artifact. Inputs: v0 corpus + filter decisions (this run id `20260425-163412-4b31`), plus calibrated cost model from v0 actuals.
>
> **Scope:** v2 kickoff document. Defines target deliverable, expanded synth template set, calibrated cost model, manifest schema, distribution targets. **Does not** include MoE wiring, SIF Broker integration, or SLM-PLM 2.8.2 internals — those are downstream session topics.
>
> **Owner:** Daniel Shamir (Admiral). v2 kickoff in fresh session, **not today.**

---

## 1. Target deliverable (v1, not v0-preview)

| Property | Value |
|---|---|
| Repository name | `nexless/dental-research-acute-v1` (or final naming TBD by Admiral) |
| Visibility at register | Private |
| Visibility at publish | **Public** (gated on v1 acceptance criteria — same 4-criterion combining rule from v0) |
| Base model | TBD — likely Qwen2.5-3B-Instruct again unless v0 eval surfaces a reason to swap |
| Regime | QLoRA r=32 alpha=64 (same as v0 unless v0 eval shows overfit at r=32 → drop to r=16) |
| Q/A volume | 15,000 – 25,000 pairs (vs v0's 5,875) |
| Templates | 9-10 (vs v0's 3) |
| Steps | 2,500 – 3,500 (vs v0's 1,500) — scale with Q/A volume to keep ~2-epoch coverage |
| Audit thresholds | Inherit v0's — `drop_chunk_types=row,ocr` + `min_words=30` + `near_dup=0.80` |
| References policy | Inherit v0's Haiku classification; re-run on any new reference material added |

---

## 2. Expanded synth template set

v0 used 3 templates: `factual`, `mechanism`, `clinical`. v2 expands to ~10 templates so the model learns more than one Q/A shape per passage.

### Existing templates (carry over from v0)

1. **`factual`** — discrete facts about the passage. Q/A short. ~70-120 tokens output.
2. **`mechanism`** — how-it-works explanations. Q/A medium. ~120-180 tokens output.
3. **`clinical`** — clinical applicability framing. Q/A medium. ~120-180 tokens output.

### New templates (v2 additions)

4. **`report_section`** — given a passage, generate a 200-400 word report section that synthesizes the content as if writing a methods or related-work section. Trains the model to compose, not just answer.
5. **`thesis_section`** — longer-form (400-700 word) thesis-chapter-style writing. Multiple paragraphs, transitions, citations referenced as `[Author Year]`. Higher-bar than `report_section`. May only be feasible from longer chunks (filter at template-binding time: only chunks ≥800 tokens get `thesis_section` Q/A).
6. **`algorithm_explanation`** — given a passage describing an algorithm or model architecture, generate a Q/A pair where the question asks "explain how X works" and the answer is a step-by-step technical explanation. Distinct from `mechanism` in that it specifically targets named algorithms (MeshSegNet, MC-Net, point cloud encoders) rather than general phenomena.
7. **`method_comparison`** — pair-format prompts asking "what's the difference between X and Y" where X and Y are alternative methods covered in the corpus (e.g., "point cloud vs voxel-based vs implicit representations for dental scans," "MeshSegNet vs iMeshSegNet for tooth labeling," "QEM-style decimation vs neural mesh simplification"). Requires multi-passage synth — needs corpus-level template, not single-chunk template. **Implementation note: this is the only template that needs synth-level cross-passage retrieval. May require a separate pre-step that clusters passages by topic before binding to template.**
8. **`known_unknown`** — Q/A about what the literature establishes vs what remains open. Pattern: question about a topic where the answer must include "X is established by [paper]; Y is open / future work." Trains epistemic humility about the corpus's coverage boundaries.
9. **`references_and_footnotes`** — Q/A where the answer must include proper bibliographic references in a consistent style (e.g., `[Lessard 2022]`, `[Hosseinimanesh 2025]`). Trains citation discipline. Improves downstream report-writing quality.
10. **`abstention`** — out-of-scope prompts where the gold answer is "this is outside the dental research literature" or similar. Examples: questions about drug design (the Zhou2019 contamination from v0), orthopedic mesh segmentation, language modeling, drug discovery, decimation algorithms (out-of-scope per v0 corpus). **Generated via a different flow:** sample from a curated list of out-of-scope topics, generate the question, write the abstention answer programmatically (not via Haiku — saves tokens and ensures consistency). ~500 abstention Q/A pairs is plenty.

### Per-template volume target

| Template | Q/A pairs per passage | Total volume target | Notes |
|---|---|---|---|
| factual | 1-2 | 2,500 – 4,000 | (carries over from v0) |
| mechanism | 1 | 1,500 – 2,500 | (v0) |
| clinical | 1 | 1,500 – 2,500 | (v0) |
| report_section | 1 per chunk≥600 tok | 1,200 – 1,800 | Long-form |
| thesis_section | 1 per chunk≥800 tok | 600 – 900 | Long-form, fewer eligible chunks |
| algorithm_explanation | 1 per algorithm-rich chunk | 800 – 1,500 | Filter to chunks mentioning named methods |
| method_comparison | varies (cluster-level) | 600 – 1,000 | Cross-passage; pre-cluster step required |
| known_unknown | 1 | 1,500 – 2,500 | All chunks eligible |
| references_and_footnotes | 1 | 1,500 – 2,500 | All chunks eligible |
| abstention | n/a (curated topics) | 400 – 600 | Programmatic, not Haiku |
| **Total** | | **12,100 – 19,800** | |

Volume target lands at the conservative end of the 15k-25k range. Buffer for filtering and rule-based junk-removal is ~20%, so emitted-then-filtered count is on the higher end.

### Per-subtopic distribution

Maintain v0's stratified-by-subtopic synth approach — generate Q/A per chunk regardless of subtopic, distribution flows from chunk distribution. Expected v2 distribution mirrors v0:

| Subtopic | Q/A volume target |
|---|---|
| dental_ai_general | ~7,500 – 12,000 |
| margin_line | ~3,200 – 5,000 |
| crown_generation | ~1,200 – 1,800 |
| segmentation | ~200 – 350 |

`segmentation` remains thin. **Open question:** if segmentation Q/A is still <300 in v2, document as "thin coverage, model unreliable on segmentation-specific questions" rather than over-weighting it during training. Don't artificially balance via re-sampling — that biases the model.

---

## 3. Cost calibration (using v0 actuals)

v0 spent **$6.49** synth on 5,875 Q/A from 1.64M clean tokens. Implied rate: ~$1.10 per million input tokens (Haiku 4.5 mix of input + output, blended).

For v2 with 9 templates of comparable input size + larger output (long-form templates increase output tokens 3-5×):

| Line item | v0 actual | v2 projection | Method |
|---|---|---|---|
| Input tokens | 2,672K | ~10,000K | 9 templates × same chunks (some chunks contribute to multiple templates) |
| Output tokens | 764K | ~6,000K | Long-form templates multiply output volume |
| Synth cost | $6.49 | **$40 – $80** | Calibrated rate × projected volume; long-form is more expensive |
| Plan-fit grading | $0.30 | $1 – $2 | More Q/A to grade × more passes |
| References classification | $0.50 | $0 – $1 | Already done in v0; carry over decisions |
| Pre-cluster step (method_comparison) | $0 | $1 – $3 | One-shot cluster Haiku call |
| **Synth + Claude total** | **$7.29** | **$45 – $90** | |
| GPU (3B QLoRA, ~3500 steps, ~5hr) | ~$5 | $7 – $9 | Longer training |
| **Total v2** | **~$12** | **$55 – $100** | |
| **Cap recommendation** | n/a | **$200** | 2× projection, leaves room for retry on synth failure |

**Key calibration:** v0 synth projected $358 → actual $6.49 = **55× over-estimation**. Cause: analyze-phase token estimate from file size (11 GB) was dominated by non-text content. v2 should rely on v0's actual chunk count + token rate, not re-estimate from file size.

---

## 4. Corpus expansion question

**Recommendation: NO corpus expansion for v2.**

Reasoning:
- 1.64M clean tokens already supports 12-20K Q/A pairs at 9 templates (each chunk contributes to ~2-3 templates on average)
- The corpus is already heavily concentrated on the IntelliDent/PolyMtl team's work — adding more dental literature would dilute that signature unless explicitly desired (which we don't want for v1, since v1 is "this team's research SLM")
- Adding general dental literature (orthodontics, periodontics, implantology) is a SEPARATE PROJECT — those subtopics need their own audit + classification + per-subtopic eval. Out of v2 scope.
- The thin segmentation bucket (99 chunks) won't be helped by general corpus expansion — it needs more SEGMENTATION literature specifically, which the team may or may not have.

**Flag for Admiral disagreement:** if v0 eval shows the model genuinely lacks vocabulary for any subtopic (perplexity barely improves on a bucket), that's a signal corpus needs more material *for that bucket only*. Inspect per-subtopic perplexity in v0 output before deciding.

---

## 5. SIF Expert Manifest Schema

A JSON manifest the SIF agent layer can read to know when and how to invoke this expert. Draft schema:

```json
{
  "manifest_version": "1.0",
  "expert_id": "dental-research-acute",
  "kb_id": "nexless/dental-research-acute-v1",
  "version": "0.1.0",
  "version_label": "v0-preview" | "v1" | "v1.1" | ...,
  "visibility": "private" | "public",
  "base_model": {
    "repo": "Qwen/Qwen2.5-3B-Instruct",
    "size_b": 3,
    "regime": "qlora-sft",
    "lora": {"rank": 32, "alpha": 64}
  },
  "domain": "dental.ai.research",
  "in_scope_subtopics": [
    {"id": "crown_generation", "weight": 0.10, "test_n": 31, "perplexity_delta_pct": null},
    {"id": "margin_line",      "weight": 0.26, "test_n": 78, "perplexity_delta_pct": null},
    {"id": "segmentation",     "weight": 0.02, "test_n":  6, "perplexity_delta_pct": null, "coverage_caveat": "thin"},
    {"id": "dental_ai_general","weight": 0.62, "test_n": 183,"perplexity_delta_pct": null}
  ],
  "out_of_scope": [
    {"topic": "decimation", "reason": "no corpus material; platform handles polygon reduction as upstream pipeline step"},
    {"topic": "drug_design", "reason": "filtered out at references-classification (v0)"},
    {"topic": "general_NLP_or_vision", "reason": "filtered out at references-classification (v0)"},
    {"topic": "orthodontics", "reason": "out of v1 corpus scope; future v1.x or v2 expansion"},
    {"topic": "periodontics", "reason": "out of v1 corpus scope"},
    {"topic": "implantology", "reason": "out of v1 corpus scope"},
    {"topic": "endodontics",  "reason": "out of v1 corpus scope"},
    {"topic": "clinical_diagnosis", "reason": "research-paper paraphrase voice; not clinically validated"}
  ],
  "invocation_keywords": [
    "tooth segmentation", "dental crown", "margin line", "MeshSegNet",
    "iMeshSegNet", "MC-Net", "intraoral scan", "dental mesh",
    "crown generation", "occlusal surface", "preparation design",
    "tooth labeling", "STL", "CAD/CAM dental", "cusp recovery"
  ],
  "invocation_keywords_exclude": [
    "drug design", "molecular fingerprint", "decimation algorithm",
    "polygon reduction", "QEM", "Garland Heckbert", "progressive mesh",
    "Hoppe", "general mesh simplification"
  ],
  "recommended_prompt_templates": [
    "factual_qa", "mechanism_qa", "clinical_qa",
    "report_section", "algorithm_explanation", "method_comparison"
  ],
  "abstention_required_for": ["out_of_scope topics — model trained to abstain on these"],
  "training_data": {
    "source_corpus_summary": "IntelliDent / Polytechnique Montréal research group's published work + filtered references",
    "qa_pair_count": 5875,
    "clean_token_count": 1644187,
    "synth_cost_usd": 6.49,
    "training_cost_usd": null,
    "audit_drops": {
      "drop_chunk_type": 1638,
      "below_min_words": 501,
      "near_dup": 76,
      "llm_slop": 31,
      "safety_boilerplate": 10,
      "references_off_topic": 275
    }
  },
  "evaluation": {
    "aggregate_perplexity_merged": null,
    "aggregate_perplexity_baseline": null,
    "aggregate_delta_pct": null,
    "per_subtopic_perplexity": null,
    "artifact_rate_pct": null,
    "verdict": null,
    "decision_criteria_met": null
  },
  "distribution": {
    "huggingface_repo": "nexless/dental-research-acute-v1",
    "gguf_quantizations": ["Q4_K_M", "Q8_0"],
    "ollama_modelfile": true,
    "lm_studio_compatible": true,
    "smoketest_results": {"ollama": null, "lm_studio": null}
  },
  "limitations": [
    "no_clinical_validation",
    "research_paper_paraphrase_voice",
    "single_research_group_selection_bias",
    "thin_segmentation_coverage",
    "english_only",
    "single_source_corpus_no_external_benchmark",
    "base_model_knowledge_not_unlearned"
  ],
  "build_provenance": {
    "forge_run_id": "v2-20260425-163412-4b31",
    "forge_version": "v2.3.7",
    "build_date": "2026-04-25",
    "gates_passed": ["preflight", "audit", "plan_fit", "eval", "card_validator", "smoketest"]
  }
}
```

### Schema decisions (resolved 2026-04-25 during eval wait)

These were originally flagged as "open for v2 kickoff," but architecture decisions made under fresh-context, no-time-pressure beat decisions made at v2-launch. Locking now.

#### 1. Ranked vs unranked `invocation_keywords` → **RANKED**

```json
"invocation_keywords": [
  {"term": "MeshSegNet", "weight": 1.0},
  {"term": "iMeshSegNet", "weight": 1.0},
  {"term": "MC-Net", "weight": 0.95},
  {"term": "tooth segmentation", "weight": 0.9},
  {"term": "dental crown", "weight": 0.85},
  {"term": "margin line", "weight": 0.85},
  {"term": "intraoral scan", "weight": 0.8},
  {"term": "occlusal surface", "weight": 0.7},
  {"term": "preparation design", "weight": 0.7},
  {"term": "CAD/CAM dental", "weight": 0.65},
  {"term": "STL", "weight": 0.5},
  {"term": "cusp recovery", "weight": 0.6}
]
```

*Reasoning:* SIF Broker needs invocation **confidence**, not match/no-match. A query containing "MeshSegNet" should route this expert at 1.0 confidence; a query containing only "STL" might match three experts (this one, a 3D-printing one, a general-graphics one) and the broker needs weights to choose. Schema is `[{term, weight}]`. Weights are normalized 0–1; the broker can sum/multiply across matched terms per its preferred aggregation.

#### 2. Semantic out-of-scope → **BOTH layers (explicit + embeddings)**

```json
"out_of_scope_explicit": [
  {"topic": "decimation", "reason": "no corpus material; platform handles polygon reduction upstream"},
  {"topic": "drug_design", "reason": "filtered out at references-classification (v0)"},
  {"topic": "general_NLP_or_vision", "reason": "filtered out at references-classification (v0)"},
  {"topic": "orthodontics", "reason": "out of v1 corpus scope"},
  {"topic": "periodontics", "reason": "out of v1 corpus scope"},
  {"topic": "implantology", "reason": "out of v1 corpus scope"},
  {"topic": "endodontics", "reason": "out of v1 corpus scope"},
  {"topic": "clinical_diagnosis", "reason": "research-paper paraphrase voice; not clinically validated"}
],
"out_of_scope_embeddings": {
  "ref": "s3://nexless-sif/manifests/dental-research-acute-v1/oos-embeddings.npy",
  "model": "sentence-transformers/all-mpnet-base-v2",
  "exemplars_count": 30,
  "match_threshold_cosine": 0.72
}
```

*Reasoning:* Explicit list catches **named exclusions** the operator deliberately scoped out. But abstainable topics include things we never wrote down (queries about MRI bone analysis, queries about facial reconstruction surgery). Semantic embedding of curated out-of-scope query exemplars catches **unnamed-but-similar** queries. Both layers complement: explicit overrides embeddings (a query that matches "decimation" verbatim should abstain even if cosine similarity is below threshold). The embeddings path lives in S3 (or wherever SIF stores expert manifests in v2); the manifest carries the reference. Threshold 0.72 is a starting cosine; tune at v2 kickoff with real query traffic.

#### 3. Broker interaction pattern → **synchronous v1, streaming v1.5, async deferred**

```json
"broker_interaction": {
  "supported_modes": ["synchronous"],
  "planned_modes": ["streaming"],
  "deferred_modes": ["async_queued"],
  "endpoint_template": {
    "synchronous": {
      "protocol": "https",
      "method": "POST",
      "path": "/v1/expert/dental-research-acute/invoke",
      "request_schema_ref": "TBD-pending-SLM-PLM-doc",
      "response_schema_ref": "TBD-pending-SLM-PLM-doc",
      "p95_latency_target_ms": 2500,
      "max_concurrent_requests": "TBD-pending-SLM-PLM-doc"
    }
  },
  "subject_to_revision": "Yes — final endpoint shape determined by SLM-PLM 2.8.2 spec. Once Daniel shares Google Doc, update fields marked TBD-pending-SLM-PLM-doc."
}
```

*Reasoning:* Synchronous HF inference endpoint (or vLLM-hosted) is the lowest-friction baseline — every consumer of LLMs handles request/response. v1 ships synchronous. Streaming via SSE comes when latency feedback matters more than first-byte simplicity (likely for thesis-section template). Async with queue requires SIF infrastructure that doesn't exist yet — defer. **What the manifest commits to** is the *capability contract*; the actual endpoint URL and request schema are platform-specific and locked when the SLM-PLM doc lands.

#### 4. Version chaining → **simple, mechanical, write it now**

```json
"version_chain": {
  "manifest_version_field": "0.1.0",
  "model_version": "v0-preview" | "v1" | "v1.1" | ...,
  "version_status": "current" | "superseded" | "deprecated" | "archived",
  "superseded_by": null | "<version-string>",
  "supersedes": null | "<version-string>",
  "kb_id_stable_across_versions": true,
  "model_path_per_version": {
    "v0-preview": "nexless/dental-research-acute-v0-preview",
    "v1": "nexless/dental-research-acute-v1"
  },
  "build_hashes": {
    "base_model_sha": null,
    "lora_adapter_sha": null,
    "gguf_q4km_sha": null,
    "gguf_q8_0_sha": null,
    "training_dataset_sha": null
  }
}
```

Version transitions:
- **v0-preview** at this run lands with `version_status: current` initially.
- When v1 lands: v0-preview manifest is updated to `version_status: superseded`, `superseded_by: "v1"`, and the v1 manifest carries `supersedes: "v0-preview"`, `version_status: current`.
- The `kb_id` (`dental-research-acute`) stays stable across versions — that's what SIF Broker uses for routing identity. The `model_path` and `model_version` change per release.
- `build_hashes` enables reproducibility audits — SHA256 of the actual model weights, GGUF bytes, and training dataset. Filled in at register time when artifacts have content-addressable hashes.

*Reasoning:* This is metadata pattern, not research. The two-line version_status / superseded_by / supersedes chain is enough for any downstream consumer to know which version of the dental-research expert is currently authoritative. The build_hashes give us forensics if a model ever produces unexpected output and we need to identify which exact build was deployed.

---

## 6. Quantization & distribution

### Quantization targets (already in v0 pipeline)

- **GGUF Q4_K_M** — 4-bit K-quant, medium. Best balance of size/quality for CPU and edge inference. ~2 GB for 3B model.
- **GGUF Q8_0** — 8-bit. Higher quality, more memory. ~3.2 GB for 3B model.

### Distribution surfaces

| Surface | Format | Status v0 | v2 expectation |
|---|---|---|---|
| HuggingFace Hub | LoRA adapter + merged + GGUFs | Private | Public after v1 ships |
| Ollama (`ollama create dental-research`) | Modelfile + GGUF Q4_K_M | Smoketest manually this run | Validated workflow |
| LM Studio | GGUF Q4_K_M / Q8_0 (no Modelfile needed) | Smoketest manually this run | Validated workflow |
| HuggingFace Spaces | Live demo Space (gradio) | Built by `forge-register`; smoketested by `forge-smoketest` | Public after v1 ships |
| SIF Expert | Per-manifest invocation | Out of v0 scope | v2 manifest registers expert |

### Manual smoketest checklist (v0, this session, post-register)

```
[ ] Download GGUF Q4_K_M from HF
[ ] ollama create dental-research-v0-preview -f Modelfile
[ ] ollama run dental-research-v0-preview "What is MeshSegNet?"
[ ] Verify response is coherent, dental-flavored, non-degenerate
[ ] Open LM Studio, load GGUF, send same prompt
[ ] Verify same coherence (LM Studio uses different inference path than Ollama)
[ ] Document any loading/inference issues
```

If either fails: flag the GGUF format issue. Don't block v0 publish-to-private (the model card already says v0 is preview only), but capture the issue for v2.

---

## 7. SLM-PLM 2.8.2 integration touchpoints

**Status: blocked on Daniel sharing the Google Doc spec.** This session does not have Drive access. Items needed for v2 kickoff:

1. **What's the platform's expected SLM interface?** OpenAI-compatible HTTP endpoint? Ollama? Custom REST? GraphQL? gRPC?
2. **Authentication / authorization model.** Per-tenant keys? OAuth pass-through? Anonymous local-only?
3. **Latency / throughput SLA.** Synchronous request/response? Streaming? Batch? What's acceptable p95?
4. **Memory / context handling.** Does the platform manage conversation state, or does each call carry full context?
5. **Tool-calling.** Does the platform expect the model to support function calling? If yes, base model and template need to support it (Qwen2.5-Instruct does; verify QLoRA fine-tune doesn't break it).
6. **Routing layer integration.** Where does the SIF Expert Manifest plug in? Is there an existing expert registry or do we need to build it?
7. **Deployment topology.** Single-node, multi-node, edge? GPU or CPU at serve time? Quantization choice for production?
8. **Versioning / rollback.** How does the platform handle expert version transitions? Is there a canary mechanism?
9. **Observability.** What telemetry does the platform expect? OpenTelemetry? Custom metrics? Logs?
10. **Compliance constraints.** PHI handling, audit logs, data residency?

**Recommendation for v2 kickoff:** open with these 10 questions before any v2 corpus or training decisions. The platform's interface dictates a lot of the SLM build choices (especially #5 tool-calling and #7 quantization).

---

## 8. Out-of-scope for v2 (push to downstream sessions)

Explicitly NOT in v2:

- **MoE / routed-expert wiring** — the SIF Expert Manifest is the dependency, but the routing layer itself is v3 territory.
- **SIF Broker integration** — v2 publishes to HF private/public; SIF Broker registration is a separate session.
- **Multi-expert composition** — chaining dental-research + dental-clinical + dental-imaging experts is v3+.
- **Continuous fine-tuning / online learning** — v2 is a one-shot forge.
- **Cross-lingual support** — French/multilingual is a future v2.x or v3.
- **Domain expansion to other dental specialties** — orthodontics/periodontics/implantology each need their own corpus + audit + classification + eval. Each is its own v2-shaped project.

---

## 9. Sequencing for v2 kickoff session

When Admiral starts the v2 kickoff session (fresh context, ideally not today):

1. **Read this spec + v0 after-action.md + v0 qa-report.md** for context.
2. **Read the SLM-PLM 2.8.2 Google Doc** (which the Admiral will share).
3. **Answer the 10 integration questions in §7** based on the doc.
4. **Adjust v2 spec** based on integration answers (especially template set, quantization choice, deployment topology).
5. **Decide v2 corpus strategy** — re-use v0 corpus, expand within IntelliDent group, or expand to other groups.
6. **Run v2 forge** following the same staged execution from this session (preflight → analyze → plan → audit → synth → shape → plan_fit → train → eval → publish).
7. **Use v2 to build the final SIF Expert Manifest**, populated from v2 actuals.
8. **Register expert** in whatever routing layer the platform uses.

---

## 10. Lessons captured from v0

Each lesson is classified: **forge-wide upstream fix** (will affect every domain run — MED, LEG, FIN, LIT, etc., not just dental v2) or **dental-v2 specific mitigation**. Upstream fixes are also filed in `slm-forge/KNOWN_ISSUES.md` as actionable issues with target versions; the v2 mitigation column captures dental-corpus-shape consequences only.

| # | Lesson | v2-specific mitigation (dental retraining) | slm-forge upstream fix (filed) |
|---|---|---|---|
| 1 | Analyze-phase token estimate from file size unreliable for mixed-media corpora (file size 11 GB → 722M raw tokens projected → 1.9M actual = 380× over-estimate at raw, 55× over-estimate at synth cost) | None needed (v2 inherits calibrated rate from v0 actuals) | **YES — `forge-analyze-token-estimator`**: replace file-size heuristic with sample-extract estimator (extract 1% of files, multiply). Affects every multi-media corpus forge. |
| 2 | Plugin errors in `prep-orchestrator.walk()` propagate as uncaught exceptions, killing the entire walk and discarding partial work (saw with `video.py` import bug then `tabular.py` Chartsheet) | None (already fixed in v0) | **YES — RESOLVED in v0**: per-file `try/except` around `plugin.iter_chunks` with `failures` list + `plugin_failure_count` in stats. File as confirmation issue. |
| 3 | `prep-orchestrator` subtopic mapper compared absolute paths against relative-path map keys — every chunk fell to `_default` | None (already fixed in v0) | **YES — RESOLVED in v0**: `Path.relative_to(raw_dir)` normalization before mapper lookup. File as confirmation issue + add unit test that uses ACTUAL plugin output, not a synthetic relative-path test (the original smoke test missed this gap). |
| 4 | `forge-synth/synth.py` did not propagate `metadata.subtopic` from input chunks to output Q/A pairs — broke axis3b per-subtopic gate | None (already fixed in v0) | **YES — RESOLVED in v0**: added `source_subtopic` extraction + propagation. File as confirmation issue. |
| 5 | Folder-level subtopic mapping is too coarse for multi-topic venues (ISBI/MICCAI/SPIE/JBHI/JMI for dental; will be PubMed/EMBASE for med, LexisNexis sections for legal, etc.) | Re-use v0's `classify-proceedings.py` decisions for any retained venue folders; re-classify any new venues | **YES — `forge-prep-per-paper-classification`**: promote `classify-proceedings.py` from a one-off run-dir script to a forge skill (`forge-classify`). Generic interface: "given a list of folders + a label set, Haiku-classify each file, populate `subtopic-map.json.files{}`." Reusable across domains. |
| 6 | Aggregate-only QA quality gate (axis3) misses subtopic-level failures — large bucket drowns small bucket's collapse | None (already fixed in v0; per-subtopic eval inherits) | **YES — RESOLVED in v0**: `axis3b_qa_per_subtopic` with `min_n_for_gate=3` + per-subtopic mean/individual thresholds. File as confirmation issue. Generalize: every domain forge should have per-subtopic acceptance, not just dental. |
| 7 | Aggregate threshold (4.0) inconsistent with per-subtopic floor (3.5) caused FAIL despite all subtopics passing the per-subtopic gate | None (v2 gate aligned at 3.5) | **YES — `forge-plan-fit-threshold-coherence`**: when axis3b is enabled, `min_qa_mean` (axis3) should auto-align to `min_qa_mean_per_subtopic` (axis3b), not be set independently. Or document the relationship in plan template so they don't drift. |
| 8 | `forge-shape` manifest idempotency on `shaped_corpus_s3` caused silent skip on resume after I'd modified `qa-filtered.jsonl` — needed boto3 to clear the artifact field | None (v2 won't hit this if manifest is fresh) | **YES — `forge-skill-force-rerun-flag`**: every forge skill that has manifest-artifact idempotency (forge-shape, forge-eval, forge-quantize, etc.) needs a `FORGE_<PHASE>_FORCE_RERUN=1` env var that bypasses the manifest check. Currently impossible to legitimately re-run a phase without S3 manifest surgery. |
| 9 | DLATeeth-references folder contained 24 off-topic ML methodology papers (drug design, NLP, GNN survey) that the team READ but were not ABOUT dentistry — dragged Q/A quality and produced the axis3b drug-design Q/A failure | Re-use v0's references-classification decisions (49 keep, 24 drop). Re-classify any new references added | **YES (pattern, not specific)**: any forge run that includes a "references" or "cited literature" folder needs per-paper classification because cited papers cover broader ML methodology than the project's own work. Same skill as #5 (`forge-classify`). |
| 10 | Model card needs explicit out-of-scope statements; without them the model can hallucinate confidently in adjacent domains | Dental-specific: decimation, drug design, orthopedic mesh segmentation, NLP, etc. (already in model card) | **YES — `forge-model-card-out-of-scope-required`**: forge-register's model-card template should require an `out_of_scope` block populated from (a) audit drops, (b) classification drops, (c) operator-named exclusions. Currently optional/free-form. |
| 11 | Original 7B base model selection was sized for 96M-token corpus estimate; actual corpus 50× smaller meant 7B was overfitting territory at r=32 LoRA | Dental-specific: v2 starts with 3B based on v0 outcome; revisit if v2 corpus is meaningfully larger | **YES — `forge-plan-base-model-fit-check`**: `forge-plan` should include a base-model-fit sanity check that compares `(actual chunks × estimated Q/A multiplier) / LoRA params` against a threshold. Auto-recommend smaller base when corpus is too small. |

### Upstream fix priority

Ranked by impact across future domain forges:

1. **`forge-analyze-token-estimator`** (#1) — every domain run hits this; current estimator is misleading by 50-380×.
2. **`forge-classify` skill** (#5/#9) — every domain has multi-topic venues and reference folders; classification should be a first-class skill, not a per-run sidecar.
3. **`forge-skill-force-rerun-flag`** (#8) — debugging any forge run currently requires S3 manifest surgery.
4. **`forge-plan-base-model-fit-check`** (#11) — prevents over-spending GPU + training time on misfit configurations.
5. **`forge-plan-fit-threshold-coherence`** (#7) — small fix, prevents the gate-conflict failure mode.
6. Confirmation issues (#2/#3/#4/#6) — already resolved in v0; file to make sure they don't regress.
7. **`forge-model-card-out-of-scope-required`** (#10) — model card quality + safety; lower priority than the structural ones.

All 11 items are filed in `slm-forge/KNOWN_ISSUES.md` with target versions and acceptance criteria.

---

*v2 forge spec v0.1, drafted 2026-04-25 during v0-preview eval. Update at v2 kickoff with SLM-PLM 2.8.2 doc inputs + v0 final eval numbers.*
