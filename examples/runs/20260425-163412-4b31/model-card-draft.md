---
license: apache-2.0
language: en
base_model: Qwen/Qwen2.5-7B-Instruct
tags:
  - dental
  - dental-ai
  - mesh-segmentation
  - crown-generation
  - margin-line-detection
  - tooth-segmentation
  - lora
  - qlora
  - research-slm
  - v0-preview
library_name: transformers
pipeline_tag: text-generation
---

# Dental Research SLM — v0 Preview (Qwen2.5-7B QLoRA)

A small language model fine-tuned on the IntelliDent / Polytechnique Montréal research group's published work, designed for question-answering and methodology-explanation over dental AI literature — crown generation, margin line detection, tooth segmentation, and the research context around them.

> ⚠️ **This is a v0 preview built for the IntelliDent / PolyMtl team to validate before v1.** The model passes its quantitative gates (50% perplexity reduction, all subtopics improved) but has known issues — see [Limitations](#limitations). It is not a production system and is not clinically validated. Treat outputs as research artifacts, never as medical advice.

---

## What this is, in plain terms

You give it a question about dental AI research — typically about methods the team has worked on (MeshSegNet, MC-Net, margin line detection, crown generation pipelines, intraoral scan processing) — and it answers with research-paper-flavored prose. It speaks the team's vocabulary because it was trained on the team's papers.

What it is **good at:**

- Explaining methods: "How does MeshSegNet handle missing teeth in partial arches?"
- Comparing approaches: "What's the difference between MeshSegNet and iMeshSegNet?"
- Recalling specific algorithms named in the team's papers
- Producing methodology summaries in the academic register
- Answering follow-up questions in a coherent multi-turn conversation

What it is **not good at:**

- Clinical advice (it's a research model, not a medical device)
- Topics outside the team's corpus (orthodontics, periodontics, implantology, mesh decimation algorithms, drug design — see [Coverage](#coverage))
- Generic dental hygiene questions (it was trained on research papers, not patient-education material; it can hallucinate confidently here)
- Knowing when to abstain (no abstention training in v0 — it will attempt almost any question)

---

## What it was trained to do — and why

The IntelliDent / PolyMtl group has produced ~10 years of dental-AI research output — multiple PhD theses, conference papers across MICCAI / SPIE / ISBI / JBHI / TMI / JMI / MEDIA, and a substantial body of methodological work on tooth segmentation and dental crown generation. That body of knowledge is largely in the papers' authors' heads and in PDFs scattered across drives. **This model is an attempt to make the group's collective methodological knowledge queryable.**

The training pipeline (see [SLM-Forge](https://huggingface.co/Nexless/dental-research-slm-0m-20260426-4b31/blob/main/README.md) provenance below) extracted ~1.6M clean tokens from the corpus, synthesized 5,875 question-answer pairs across three Q/A types (factual / mechanism / clinical), stratified them by subtopic, and QLoRA-fine-tuned Qwen2.5-7B-Instruct on the resulting dataset.

**The point of v0** is to validate that the corpus, the synthesis pipeline, and the per-subtopic quality gates work for this domain before scaling to v1's expanded prompt set (report sections, thesis-style writing, algorithm explanations, abstention prompts). Treat v0 as the proof-of-pipeline, not the final product.

---

## Quick start

### Ollama (recommended for headless / fastest setup)

```bash
curl https://huggingface.co/Nexless/dental-research-slm-0m-20260426-4b31/raw/main/Modelfile -o Modelfile
ollama create dental-research-v0 -f Modelfile
ollama run dental-research-v0
>>> What is MeshSegNet and how does it perform tooth segmentation?
```

The Modelfile bakes in the [recommended sampling settings](#recommended-sampling-settings) — without them the model can collapse into repetition.

### LM Studio

Download `gguf/model-Q4_K_M.gguf` (4.7 GB, balanced) or `gguf/model-Q8_0.gguf` (8.1 GB, near-lossless). Load in LM Studio. Open Advanced configuration on the right panel and set the [recommended sampling parameters](#recommended-sampling-settings). Add stop strings: `<|im_end|>`, `<|im_start|>`, `<|endoftext|>`, `ttiuser`, `ttiassistant`.

### Python (HuggingFace transformers + PEFT — for fine-tuning continuation)

```python
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import PeftModel

base_id = "Qwen/Qwen2.5-7B-Instruct"
adapter_id = "Nexless/dental-research-slm-0m-20260426-4b31"

tokenizer = AutoTokenizer.from_pretrained(adapter_id)
base = AutoModelForCausalLM.from_pretrained(
    base_id,
    torch_dtype=torch.bfloat16,
    device_map="auto",
)
model = PeftModel.from_pretrained(base, adapter_id)

prompt = "What is MeshSegNet and how does it perform tooth segmentation?"
messages = [{"role": "user", "content": prompt}]
inputs = tokenizer.apply_chat_template(
    messages, return_tensors="pt", add_generation_prompt=True
).to(model.device)

outputs = model.generate(
    inputs,
    max_new_tokens=320,
    temperature=0.5,
    top_p=0.9,
    top_k=40,
    repetition_penalty=1.18,
    do_sample=True,
)
print(tokenizer.decode(outputs[0][inputs.shape[-1]:], skip_special_tokens=True))
```

---

## Example outputs

### Example 1 — In-domain methodology explanation (good case)

> **Prompt:** Briefly describe how MeshSegNet performs tooth segmentation on intraoral 3D scans.
>
> **Response:** MeshSegNet uses an encoder-decoder architecture with multiple graph convolutional layers to segment teeth from the surface of complete dentition models generated by reconstruction algorithms like Poisson Surface Reconstruction or Harmonic Field Completion. The network processes both vertex features and adjacency information, allowing it to handle missing data in partial arches and identify individual teeth based on their geometric characteristics.

This is the model at its best — names real algorithms, accurate technical content, no degeneration.

### Example 2 — Crown-generation seed continuation (in-domain)

> **Seed:** What advantage does the differentiable point-to-mesh component provide in dental
>
> **Continuation:** *applications?* The differentiable point-to-mesh component allows for the optimization of dental models through gradient-based methods, enabling more precise and efficient model refinement compared to traditional non-differentiable approaches. This capability is particularly valuable in dental applications where detailed geometric accuracy is essential. The component's ability to process point clouds and generate smooth mesh surfaces makes it suitable for tasks such as crown generation, where precision is critical.

### Example 3 — Generic prompt (failure mode example)

> **Prompt:** What causes cavities?
>
> **Response:** *What are the symptoms of tooth decay and how can you prevent it?* Cavities, also known as tooth decay or dental caries, are caused by the interaction between bacteria, sugars, and acids in your mouth. Here's a breakdown of what causes cavities, their symptoms, and prevention strategies: ...

The model echoed an alternative question before answering — a v0 artifact from base-model instruction-tuning leaking through. Roughly 30% of generic-style prompts trigger this. **It is the kind of thing v1 will fix with abstention training.**

---

## Model details

| Field | Value |
|---|---|
| Base model | [`Qwen/Qwen2.5-7B-Instruct`](https://huggingface.co/Qwen/Qwen2.5-7B-Instruct) (7.62 B parameters) |
| Regime | QLoRA-SFT (4-bit NF4 base + bf16 LoRA adapter) |
| LoRA rank / alpha | 32 / 64 |
| LoRA target modules | `q_proj`, `k_proj`, `v_proj`, `o_proj` |
| Trainable parameters | ~67 M (the LoRA adapter) |
| Optimizer | AdamW (default HF Trainer) |
| Learning rate | 1e-4 (cosine schedule, 3% warmup) |
| Training steps | 1,500 (≈ 2 epochs over training set) |
| Effective batch size | 8 (per-device 2 × grad accumulation 4) |
| Max sequence length | 2,048 |
| Gradient checkpointing | true |
| Precision | bf16 |
| Hardware | 1× NVIDIA A10G (g5.2xlarge, 24 GB VRAM) |
| Wall clock | ~9.7 hr (steady 23.45 sec/step) |
| Final training loss (last 10 logged steps avg) | 1.25 (≈ training perplexity 3.49) |
| Chat template | Qwen2 ChatML |
| License | Apache 2.0 |

---

## Coverage

Training data is stratified across four subtopic buckets, each with held-out validation and test splits:

| Subtopic | Q/A pairs | Test pairs | Coverage |
|---|---|---|---|
| `crown_generation` | 597 | 31 | Strong — IMACS2023, MICCAI 2023/2024, SPIE 2022-2026, JBHI/JMI/MEDIA/TMI |
| `dental_ai_general` | 3,635 | 183 | Broad — theses, IVADO conferences, multimodal viz, evaluation methods, filtered DLATeeth-references |
| `margin_line` | 1,544 | 78 | Strong — MeshSegNet + iMeshSegNet + pointr drafts |
| `segmentation` | 99 | 6 | **Thin** — JDentistry_iMeshSegNet, Segmentation Paper, ISBI subset |

### Out of scope (model will hallucinate or echo base-model knowledge)

- **Mesh decimation / polygon reduction** — zero corpus coverage; the dental platform handles this as upstream pipeline plumbing, not as research content
- **Drug design, NLP, generic GNN methodology** — explicitly filtered (24 of 73 cited reference papers were dropped at corpus prep)
- **Other dental specialties** — orthodontics, periodontics, implantology, endodontics — outside the corpus's research focus
- **Clinical diagnosis** — research-paper paraphrase voice, not clinically validated, never use for medical decisions

---

## Evaluation

Evaluated on a stratified held-out test set (100 docs total, sampled from 298 available) against the unfine-tuned Qwen2.5-7B-Instruct as baseline.

### Aggregate

| | Merged | Baseline | Δ |
|---|---|---|---|
| Perplexity (lower is better) | **9.279** | 18.843 | **−50.7 %** |

### Per subtopic

| Subtopic | n_test | Merged | Baseline | Δ |
|---|---|---|---|---|
| crown_generation | 11 | 8.845 | 19.324 | **−54.2 %** |
| dental_ai_general | 64 | 10.088 | 19.852 | **−49.2 %** |
| margin_line | 23 | 7.801 | 16.405 | **−52.4 %** |
| segmentation | 2 | 5.959 | 15.213 | −60.8 % (n=2; statistical noise — directional only) |

### Verdict (mechanical, pre-committed before eval)

| Criterion | Threshold | Result | Verdict |
|---|---|---|---|
| 1. Aggregate ppl reduction | ≥ 20 % READY | −50.7 % | ✅ READY |
| 2. Per-subtopic floor (worst large bucket ≥ 40 % of aggregate) | crown 54 % / dental 49 % / margin 52 % all clear | All large buckets pass | ✅ READY |
| 3. Train vs held-out reduction ratio | ≤ 1.5× READY · 1.5–2.5× CAVEATS · > 2.5× FAIL | 1.61× | ⚠️ CAVEATS |
| 4. Sample artifact rate (10 generic prompts) | < 10 % READY · 10–30 % CAVEATS · > 30 % FAIL | 30 % | ⚠️ CAVEATS |
| **Combining rule (worst level wins)** | | | **PUBLISH-WITH-CAVEATS** |

The pre-committed thresholds are documented in the run's `comparison-vs-baseline.skeleton.md`. No re-litigation post-data.

---

## Limitations

- **Mild overfitting signature.** Training loss dropped further than held-out perplexity reduced (1.61× ratio). 7B + r=32 LoRA on 1.6M tokens is more capacity than data — v1 will reduce LoRA rank or use a smaller base.
- **Instruction-tuning leakage on ~30% of generic prompts.** Outputs occasionally lead with echoed questions or NLI-task formatting (`Available choices: [i] no; [ii] yes`) before answering. The dental content underneath is correct, but the lead-in pollution is real and is what v1's abstention prompt template is meant to fix.
- **Selection bias.** ~75% of the corpus is the IntelliDent / PolyMtl group's own work. The model will sound like that group, use their vocabulary, and reflect their methodological choices. It does not represent dental AI research broadly.
- **Thin segmentation coverage.** Only 99 segmentation Q/A pairs in training (vs 3,635 dental_ai_general). The segmentation-specific test perplexity is from n=2 — directional only, not statistically meaningful.
- **English-only.** Some source documents were French (DialogueUdeM, IVADO conferences); they were extracted as-is, but the model was not validated on French queries.
- **No external benchmark.** Held-out test is from the same corpus as training. Reported numbers tell you the model fit the training distribution, not whether it generalizes to other dental research.
- **Base-model knowledge not unlearned.** Qwen2.5-7B already has general ML / clinical / NLP knowledge from pretraining. The fine-tune layers on top — it does not erase. Expect base-model voice to surface on out-of-corpus topics.

---

## How to extend (fine-tune further, or retrain from scratch)

The whole point of releasing the LoRA adapter rather than just the merged GGUFs is that the team can keep building on it. Three paths, in increasing scope:

### Path A — Add more dental content via LoRA continuation

If you have additional dental-research material the team didn't have at v0 build time (new papers, supplementary material, additional reference set), continue the LoRA fine-tune from this checkpoint:

```python
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer, TrainingArguments
from peft import PeftModel
from trl import SFTTrainer
from datasets import load_dataset

base_id = "Qwen/Qwen2.5-7B-Instruct"
adapter_id = "Nexless/dental-research-slm-0m-20260426-4b31"

tokenizer = AutoTokenizer.from_pretrained(adapter_id)
base = AutoModelForCausalLM.from_pretrained(
    base_id,
    torch_dtype=torch.bfloat16,
    device_map="auto",
    load_in_4bit=True,
)
model = PeftModel.from_pretrained(base, adapter_id, is_trainable=True)

# Your additional dataset (chat format: messages: [{role, content}, ...])
dataset = load_dataset("json", data_files="your_extra_dental_qa.jsonl")["train"]

trainer = SFTTrainer(
    model=model,
    tokenizer=tokenizer,
    train_dataset=dataset,
    args=TrainingArguments(
        output_dir="./dental-research-v0.1",
        learning_rate=5e-5,           # ↓ from 1e-4: gentler continuation
        num_train_epochs=1,
        per_device_train_batch_size=2,
        gradient_accumulation_steps=4,
        bf16=True,
        gradient_checkpointing=True,
        save_steps=100,
        logging_steps=10,
    ),
    max_seq_length=2048,
)
trainer.train()
trainer.save_model("./dental-research-v0.1")
```

This produces a derived adapter — push to a new repo (e.g. `your-namespace/dental-research-v0.1`) and the v0 lineage is preserved in the chain.

### Path B — Train a new LoRA on top of the merged model

If you want to specialize for a sub-domain (e.g., crown generation only, or margin line analysis only), merge v0's LoRA into the base, then start a fresh LoRA on top:

```python
# 1. Merge v0 LoRA into base — produces a 7B model with v0's dental knowledge baked in
from peft import PeftModel
base = AutoModelForCausalLM.from_pretrained("Qwen/Qwen2.5-7B-Instruct", torch_dtype=torch.bfloat16)
model = PeftModel.from_pretrained(base, adapter_id)
merged = model.merge_and_unload()
merged.save_pretrained("./qwen2.5-7b-dental-merged")

# 2. Now train a fresh LoRA on the merged model with your specialized dataset
# Same SFTTrainer setup as Path A but with init_lora_weights=True and your sub-domain corpus
```

This stacks domain knowledge: base → general ML/instruction → dental research (v0) → your specialty.

### Path C — Retrain from scratch via SLM-Forge

If you want to redo the build with a different corpus, different prompt templates, different base model, or a different audit/synth pipeline, the entire forge process is reproducible. See `slm-forge/.runs/20260425-163412-4b31/v2-forge-spec.md` in the project repo for the v2 specification, and `KNOWN_ISSUES.md` for the upstream forge improvements that should be applied before re-running. The forge pipeline accepts a corpus directory and a budget, then handles preflight → analyze → plan → audit → synth → shape → plan_fit → train → eval → publish autonomously.

---

## Recommended sampling settings

7B models on narrow corpora can collapse into repetition without aggressive sampling controls. **Always use:**

| Parameter | Value | Reason |
|---|---|---|
| `temperature` | 0.5 | 0.7 is too hot for QLoRA on a small corpus |
| `top_p` | 0.9 | constrains tail |
| `top_k` | 40 | constrains tail |
| `repeat_penalty` | 1.18 | kills paragraph loops (the main failure mode) |
| `repeat_last_n` | 256 | window for the penalty |
| `max_tokens` | 320 | keep responses short |

Stop strings (LM Studio): `<|im_end|>`, `<|im_start|>`, `<|endoftext|>`, `ttiuser`, `ttiassistant`. The Modelfile in this repo bakes these defaults in for Ollama users.

---

## What's coming in v1 — stay tuned

v1 is being designed now. Highlights:

- **Nine prompt templates** instead of three: factual, mechanism, and clinical (carried over) plus report-section, thesis-section, algorithm-explanation, method-comparison ("point cloud vs voxel-based vs implicit"), known/unknown, references-and-footnotes, and abstention prompts. Expanded coverage from ~6,000 to ~18,000 Q/A pairs from the same corpus.
- **Smaller / better-fit base model.** v0 trained 7B because of a configuration bug; v1 will target 3B with r=16 LoRA — better params-per-example ratio, faster inference, less overfitting.
- **Abstention training.** v1 will explicitly train the model to say "this is outside the dental research literature" on out-of-scope prompts (drug design, decimation algorithms, generic dental hygiene). The 30% artifact rate goes away.
- **SIF Expert Manifest** — registered as a routable expert in the broader Sovereign Intelligence Framework, callable from the SLM-PLM 2.8.2 platform layer.

If you have feedback on v0 — what works, what's broken, what the model should know that it doesn't — open an HF discussion or email **dshamir@blucap.ca**. Concrete failure cases (a prompt + bad response) are gold for v1.

---

## Citation

If this model contributes to your work, please cite the underlying research:

```bibtex
@article{lessard2022mcnet,
  title={MC-Net: Mesh Completion for Dental Scans},
  author={Lessard, Olivier and Guibault, Fran{\c{c}}ois and Keren, Julia and Cheriet, Farida},
  journal={IEEE Transactions on Medical Imaging},
  year={2022}
}

@article{hosseinimanesh2025crown,
  title={Automatic Dental Crown Generation with Spatial Constraint Modeling},
  author={Hosseinimanesh, Golriz and others},
  journal={Journal of Medical Imaging},
  year={2025}
}

@inproceedings{chafi2025intellident,
  title={IntelliDent: an AI-based online automated framework for dental crown generation},
  author={Chafi, Imane and others},
  booktitle={SPIE Medical Imaging},
  year={2025}
}
```

The model was synthesized from these and ~150 other publications by the IntelliDent / PolyMtl research group; see `references-classification.json` in the SLM-Forge run directory for the full retained-references list.

---

## Acknowledgments

- **IntelliDent / Polytechnique Montréal research group** — the source corpus is their published work and selected references
- **Qwen team** — the base Qwen2.5-7B-Instruct model
- **Anthropic Claude Haiku 4.5** — Q/A synthesis from the research literature, plus per-paper classification of the 73-paper references folder
- **SLM-Forge** — the autonomous training pipeline that orchestrates preflight → analyze → plan → audit → synth → shape → plan_fit → train → eval → publish

---

## Provenance

| | |
|---|---|
| Forge run ID | `20260425-163412-4b31` |
| Forge version | v2.3.7 |
| Build date | 2026-04-26 |
| Verdict | PUBLISH-WITH-CAVEATS (mechanical 4-criterion combining rule) |
| EC2 build instance | `i-08e4dd02f25be81f1` (terminated post-build) |
| Training wall clock | ~9.7 hr (1500 steps × 23.45 sec/step on 1× A10G) |

Quality gates: preflight ✓ · audit ✓ (kept 51 % of chunks → 1.64 M clean tokens) · plan_fit ✓ (axis3 aggregate 3.835, axis3b per-subtopic all clear) · eval ✓ (4-criterion combining rule → PUBLISH-WITH-CAVEATS) · card_validator ✓ · smoketest skipped-with-caveat (private-Space-fetches-private-model auth chain — resolved post-publish via Space secret).

---

### About SLM-Forge and the SIF Skill Tree

This model was built end-to-end by **SLM-Forge**, a skill tree within NEXLESS™ LP's [**Sovereign Intelligence Framework (SIF)**](https://github.com/Dshamir/sif-knowledge-base) — a cognitive operating system for Claude Code that composes 300+ first-class skills across autonomous training pipelines, multi-agent orchestration (MGMO), Universal Admin Console plugins, RAG and knowledge-graph systems, and audit-gated production workflows.

SLM-Forge specifically owns the full lifecycle a domain SLM goes through: **preflight → analyze → plan → audit → synth → shape → plan_fit → train → eval → quantize → register → card_validator → smoketest → teardown → report.** Each phase is its own skill with structured inputs, outputs, and acceptance criteria. The pipeline is intended to be invoked by a single command (`/slm-forge <corpus> <budget>`) and to produce a complete, auditable, HuggingFace-published model with provenance — corpus → cleaned data → Q/A pairs → trained weights → quantizations → published artifact — all gated by mechanical pre-committed quality criteria. This v0 preview is the first end-to-end run of the pipeline against a real research corpus.

The SIF ecosystem and SLM-Forge skill tree are open-source at the repository above. The framework itself (skill registry, CONSTELLATION hubs, MGMO orchestration protocol, sovereignty layer, version-control system) is documented across the immutable-sovereignty / amendments tracks in the same repo.
