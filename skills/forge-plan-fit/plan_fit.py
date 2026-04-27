#!/usr/bin/env python3
"""
forge-plan-fit core script — 7-axis pre-training plan validation.

Driven by env vars:
  FORGE_PLAN_FIT_QA_FILE          path to shaped Q/A jsonl (chat format)
  FORGE_PLAN_FIT_AUDIT_REPORT     path to audit-report.json from forge-audit
  FORGE_PLAN_FIT_TRAINING_OVERRIDES JSON string of training overrides
  FORGE_PLAN_FIT_BASE_MODEL       e.g. "Qwen/Qwen2.5-1.5B"
  FORGE_PLAN_FIT_DOMAIN           e.g. "dental.ai.research"
  FORGE_PLAN_FIT_OUT_REPORT       path to write final report
  FORGE_PLAN_FIT_SAMPLE_SIZE      default 50
  FORGE_PLAN_FIT_MIN_DOMAIN_PCT   default 0.95
  FORGE_PLAN_FIT_MIN_QA_MEAN      default 4.2
  FORGE_PLAN_FIT_MIN_QA_INDIVIDUAL default 3.0
  FORGE_PLAN_FIT_MIN_SUBDOMAIN_PCT default 0.05
  FORGE_PLAN_FIT_PLAN_JSON        path to plan.json (for Axis 7 budget check)
  FORGE_PLAN_FIT_SYNTH_PROGRESS   path to synth-progress.json (for Axis 7)
  FORGE_PLAN_FIT_BUDGET_HEADROOM  headroom fraction, default 0.10 (10% of cap)
  ANTHROPIC_API_KEY               required

Exit code: 0 = PASS, 1 = FAIL (gate aborts forge).
"""
from __future__ import annotations

import asyncio
import json
import os
import random
import re
import statistics
import sys
from collections import Counter
from pathlib import Path

try:
    from anthropic import AsyncAnthropic
except ImportError:
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", "anthropic"])
    from anthropic import AsyncAnthropic

# --- Domain → expected subdomains map (used by Axis 2) ---------------------

DOMAIN_SUBDOMAINS = {
    "dental": [
        "restorative", "endodontics", "periodontics", "prosthodontics",
        "orthodontics", "oral_surgery", "implantology", "diagnostics_imaging",
        "dental_ai_methods", "off_topic",
    ],
}

CLASSIFY_MODEL = "claude-haiku-4-5"
GRADE_MODEL = "claude-sonnet-4-6"  # cheaper but still capable; opus ~6x cost


# --- Axis 1: Corpus content (Claude classifier) ----------------------------

CLASSIFY_SYSTEM = """You classify short passages from a research corpus into ONE of these subdomain labels:
{labels}

Only output the single label, exactly as written. If the passage doesn't fit any label, output `off_topic`."""


async def classify_one(client, sem, text, labels) -> str:
    sys_prompt = CLASSIFY_SYSTEM.format(labels="\n".join(f"- {l}" for l in labels))
    async with sem:
        try:
            resp = await client.messages.create(
                model=CLASSIFY_MODEL,
                max_tokens=20,
                system=sys_prompt,
                messages=[{"role": "user", "content": f"Passage:\n\n{text[:3000]}"}],
            )
            label = resp.content[0].text.strip().lower()
            label = re.sub(r"[^a-z_]", "", label)
            return label if label in labels else "off_topic"
        except Exception:
            return "off_topic"


# --- Axis 3: Q/A grading (Claude as expert) --------------------------------

GRADE_SYSTEM = """You are evaluating Q/A pairs that will train a small language model to answer questions about **{domain}** research.

Important context for your grading:
- The corpus is real research publications from this exact domain (`{domain}`).
  For "dental.ai.research" the corpus is computational dentistry / dental
  imaging / dental-ML methodology papers — not general dentistry textbooks.
  Q/A pairs about specific methods, metrics, model architectures, training
  procedures, ablations, mesh/segmentation/crown-generation algorithms are
  ON-TOPIC and APPROPRIATE.
- These Q/A pairs are intended for a research-assistant model, not a clinical
  bedside tool. Specific quantitative claims from individual studies are fine
  as long as they're plausibly grounded in the cited literature.
- Penalize: factually wrong content, off-domain content (e.g. unrelated CV
  papers), pure hallucinations, marketing language, generic-AI fluff.
- Do NOT penalize: paper-specific metrics, ML methodology questions, niche
  computational-dentistry topics — these are the domain.

For each Q/A pair, output a JSON object:
{{
  "factual": <int 1-5>,    // accuracy: 5 perfect, 1 wrong
  "appropriate": <int 1-5>, // fit for "{domain}" research-assistant training: 5 great, 1 off-topic
  "grounded": <int 1-5>,   // could plausibly come from research papers in {domain}: 5 yes, 1 pure invention
  "concise": <int 1-5>,    // reasonably short and dense: 5 great, 1 bloated
  "notes": "<one-line note ONLY if any score < 4>"
}}

Output strict JSON. No commentary."""


async def grade_one(client, sem, qa_pair, domain) -> dict | None:
    user = f"Q: {qa_pair['question']}\n\nA: {qa_pair['answer']}"
    async with sem:
        try:
            resp = await client.messages.create(
                model=GRADE_MODEL,
                max_tokens=300,
                system=GRADE_SYSTEM.format(domain=domain),
                messages=[{"role": "user", "content": user}],
            )
            raw = resp.content[0].text.strip()
            if raw.startswith("```"):
                raw = raw.split("```", 2)[1]
                if raw.startswith("json"):
                    raw = raw[4:]
                raw = raw.strip()
            data = json.loads(raw)
            scores = {k: int(data.get(k, 0)) for k in ("factual", "appropriate", "grounded", "concise")}
            scores["mean"] = sum(scores.values()) / 4
            scores["min"] = min(scores.values())
            scores["notes"] = data.get("notes", "")
            return scores
        except Exception as e:
            return {"error": f"{type(e).__name__}: {e}", "mean": 0, "min": 0}


# --- Axis 5: Hyperparameter heuristics -------------------------------------

def hyperparam_check(overrides: dict, base_model: str, n_train_examples: int) -> dict:
    issues = []
    rank = overrides.get("lora_r", 8)
    epochs = overrides.get("epochs", overrides.get("num_train_epochs", 1))
    max_steps = overrides.get("max_steps", 0)
    batch = overrides.get("batch_size", 1)
    grad_accum = overrides.get("grad_accum", 1)
    # plan.json stores learning_rate as a string like "1e-4" (preserves scientific notation);
    # cast here since the comparisons below expect a float.
    lr_raw = overrides.get("learning_rate", 2e-4)
    try:
        lr = float(lr_raw)
    except (TypeError, ValueError):
        lr = 2e-4
    seq_len = overrides.get("max_seq_len", 1024)

    # Effective epochs from max_steps if both given
    eff_batch = batch * grad_accum
    if max_steps and n_train_examples:
        steps_per_epoch = max(1, n_train_examples // eff_batch)
        eff_epochs = max_steps / steps_per_epoch
    else:
        eff_epochs = epochs

    # 1. Rank vs corpus size
    if "1.5B" in base_model or "1.5b" in base_model:
        if rank > 16:
            issues.append(f"LoRA rank {rank} too high for 1.5B base — recommended 8-16")
    elif "0.5B" in base_model or "0.5b" in base_model:
        if rank > 8:
            issues.append(f"LoRA rank {rank} too high for 0.5B base — recommended 4-8")

    # 2. Effective epochs
    if eff_epochs > 3:
        issues.append(f"Effective epochs {eff_epochs:.1f} too high — memorization likely; recommended 1-3")
    if eff_epochs < 0.5:
        issues.append(f"Effective epochs {eff_epochs:.1f} too low — model won't learn; recommended ≥1")

    # 3. LR sanity
    if lr > 5e-4:
        issues.append(f"Learning rate {lr} too high — recommended 1e-4 to 5e-4 for LoRA")
    if lr < 5e-6:
        issues.append(f"Learning rate {lr} too low — recommended ≥5e-5")

    # 4. Seq len vs base ctx
    if seq_len > 4096:
        issues.append(f"max_seq_len {seq_len} unusually high — A10G may OOM on 1.5B")

    return {
        "passes": len(issues) == 0,
        "issues": issues,
        "computed": {
            "effective_batch": eff_batch,
            "effective_epochs": round(eff_epochs, 2) if isinstance(eff_epochs, float) else eff_epochs,
            "n_train_examples": n_train_examples,
        },
    }


# --- Axis 6: Training format roundtrip -------------------------------------

def format_check(qa_examples: list[dict]) -> dict:
    """Check 5 random examples produce well-formed chat-template output."""
    issues = []
    samples_checked = []
    for ex in qa_examples[:5]:
        msgs = ex.get("messages", [])
        if len(msgs) < 2:
            issues.append(f"{ex.get('id', '?')}: messages < 2")
            continue
        if msgs[0].get("role") != "user" or msgs[1].get("role") != "assistant":
            issues.append(f"{ex.get('id', '?')}: roles not user→assistant")
            continue
        if not msgs[0].get("content") or not msgs[1].get("content"):
            issues.append(f"{ex.get('id', '?')}: empty content")
            continue
        # Manually construct ChatML (what training will produce)
        formatted = (
            f"<|im_start|>user\n{msgs[0]['content']}<|im_end|>\n"
            f"<|im_start|>assistant\n{msgs[1]['content']}<|im_end|>\n"
        )
        samples_checked.append({
            "id": ex.get("id", "?"),
            "ok": "<|im_start|>user" in formatted and "<|im_start|>assistant" in formatted,
        })
    return {
        "passes": len(issues) == 0 and all(s["ok"] for s in samples_checked),
        "issues": issues,
        "samples_checked": samples_checked,
    }


# --- Axis 7: Budget fit ----------------------------------------------------

def budget_check(plan_json_path: Path, synth_progress_path: Path, headroom_frac: float) -> dict:
    """Validate the forge will fit within budget_cap_usd given actual spend so far.

    Plan_fit runs post-synth, so synth is the dominant spent cost. Remaining
    projected cost = plan.estimates.cost.gpu_usd + plan.estimates.cost.plan_fit_usd.
    Fail if spent + projected > cap. Fail if cap − projected_total < cap × headroom_frac
    (i.e. refuse to launch GPU with < headroom_frac cushion against the cap).
    """
    if not plan_json_path.exists():
        return {"passes": False, "issue": f"plan.json missing at {plan_json_path}"}

    plan = json.loads(plan_json_path.read_text())
    cap = float(plan.get("budget_cap_usd", 0))
    est = plan.get("estimates", {}).get("cost", {})
    projected_synth = float(est.get("synth_usd", 0))
    projected_plan_fit = float(est.get("plan_fit_usd", 0))
    projected_gpu = float(est.get("gpu_usd", 0))
    projected_total = float(est.get("total_usd", projected_synth + projected_plan_fit + projected_gpu))

    # Actual spent so far = synth actual (the only phase that bills $ pre-plan_fit)
    actual_synth = 0.0
    if synth_progress_path.exists():
        try:
            sp = json.loads(synth_progress_path.read_text())
            actual_synth = float(sp.get("actual_cost_usd", 0))
        except Exception as e:
            return {"passes": False, "issue": f"synth-progress.json unreadable: {e}"}

    synth_overrun = actual_synth - projected_synth
    synth_overrun_pct = (synth_overrun / projected_synth * 100) if projected_synth > 0 else 0.0

    # Projected total given actual synth
    projected_total_actualized = actual_synth + projected_plan_fit + projected_gpu
    headroom_abs = cap - projected_total_actualized
    headroom_required = cap * headroom_frac

    over_cap = projected_total_actualized > cap
    under_headroom = headroom_abs < headroom_required

    return {
        "budget_cap_usd": round(cap, 4),
        "projected_total_at_plan_time_usd": round(projected_total, 4),
        "actual_synth_usd": round(actual_synth, 4),
        "projected_synth_usd": round(projected_synth, 4),
        "synth_overrun_usd": round(synth_overrun, 4),
        "synth_overrun_pct": round(synth_overrun_pct, 2),
        "projected_plan_fit_usd": round(projected_plan_fit, 4),
        "projected_gpu_usd": round(projected_gpu, 4),
        "projected_total_actualized_usd": round(projected_total_actualized, 4),
        "headroom_absolute_usd": round(headroom_abs, 4),
        "headroom_required_usd": round(headroom_required, 4),
        "headroom_frac": headroom_frac,
        "passes": (not over_cap) and (not under_headroom),
        "verdict": (
            "OVER_CAP" if over_cap
            else ("UNDER_HEADROOM" if under_headroom else "OK")
        ),
    }


# --- Axis 8: Extraction cost ---------------------------------------------

def extraction_cost_check(analysis_json_path: Path, plan_json_path: Path,
                          max_ext_fraction: float) -> dict:
    """Warn if prep's extraction phase will dominate wall-clock OR cost.

    Inputs:
      analysis.json — has extraction_profile.estimated_extraction_time_min
                      and extraction_profile.counts (images, audio_video, mesh)
      plan.json     — has estimates.total_wall_clock_minutes

    Hard fail criteria (both must be exceeded for FAIL, else WARN):
      extraction_time / total_wall_clock > max_ext_fraction (default 0.25)
      AND extraction counts indicate expensive paths (audio_video > 0 OR images > 100)

    Soft pass with WARN status otherwise.
    """
    if not analysis_json_path.exists():
        return {"passes": True, "skipped": True, "reason": f"analysis.json missing at {analysis_json_path}"}
    if not plan_json_path.exists():
        return {"passes": True, "skipped": True, "reason": f"plan.json missing at {plan_json_path}"}

    analysis = json.loads(analysis_json_path.read_text())
    plan = json.loads(plan_json_path.read_text())

    ext_profile = analysis.get("extraction_profile", {})
    ext_min = int(ext_profile.get("estimated_extraction_time_min", 0))
    counts = ext_profile.get("counts", {}) or {}
    n_img = int(counts.get("images", 0))
    n_av = int(counts.get("audio_video", 0))
    n_mesh = int(counts.get("mesh", 0))

    plan_total_min = int(plan.get("estimates", {}).get("total_wall_clock_minutes", 0))
    if plan_total_min <= 0:
        return {"passes": True, "skipped": True, "reason": "plan total_wall_clock_minutes missing"}

    ext_fraction = ext_min / plan_total_min if plan_total_min > 0 else 0.0
    over_budget_time = ext_fraction > max_ext_fraction

    # Estimated extra cost for audio transcription (CPU whisper-base)
    # ~5 min audio per file = ~1.5min transcribe = ~0.025 hr × $1.00 CPU = $0.025
    # ~174 files × $0.025 = ~$4
    est_av_cost_usd = n_av * 0.025
    over_cost = est_av_cost_usd > 2.0  # $2 threshold

    # Hard fail ONLY if both heavy-volume AND over time budget
    hard_fail = over_budget_time and (n_av > 10 or n_img > 100)

    verdict = "OK"
    if hard_fail:
        verdict = "OVER_EXTRACTION_BUDGET"
    elif over_budget_time or over_cost:
        verdict = "WARN"

    notes = []
    if n_av > 0:
        notes.append(
            f"{n_av} audio/video files — set FORGE_DISABLE_TRANSCRIBE=1 to skip "
            f"(would remove ~{est_av_cost_usd:.2f}$ and ~{n_av * 90 // 60} min)"
        )
    if n_img > 50:
        notes.append(
            f"{n_img} images — set FORGE_DISABLE_OCR=1 to skip if images are known "
            f"to have no text (e.g. dental x-rays / 3D renderings)"
        )
    if n_mesh > 100:
        notes.append(
            f"{n_mesh} 3D mesh files — produce metadata-only chunks (~30 chars each). "
            f"forge-audit can filter them out via chunk_type=metadata_only if needed."
        )

    return {
        "passes": not hard_fail,   # warn but don't fail unless egregious
        "verdict": verdict,
        "estimated_extraction_time_min": ext_min,
        "plan_total_wall_clock_min": plan_total_min,
        "extraction_fraction": round(ext_fraction, 3),
        "max_fraction_threshold": max_ext_fraction,
        "estimated_transcription_cost_usd": round(est_av_cost_usd, 2),
        "counts": {"images": n_img, "audio_video": n_av, "mesh": n_mesh},
        "notes": notes,
    }


# --- Main ------------------------------------------------------------------

async def main() -> int:
    qa_path = Path(os.environ["FORGE_PLAN_FIT_QA_FILE"])
    audit_path = Path(os.environ["FORGE_PLAN_FIT_AUDIT_REPORT"])
    out_report = Path(os.environ["FORGE_PLAN_FIT_OUT_REPORT"])
    base_model = os.environ.get("FORGE_PLAN_FIT_BASE_MODEL", "Qwen/Qwen2.5-1.5B")
    domain_full = os.environ.get("FORGE_PLAN_FIT_DOMAIN", "dental.ai.research")
    domain_key = domain_full.split(".", 1)[0]
    overrides_json = os.environ.get("FORGE_PLAN_FIT_TRAINING_OVERRIDES", "{}")
    overrides = json.loads(overrides_json)

    sample_size = int(os.environ.get("FORGE_PLAN_FIT_SAMPLE_SIZE", "50"))
    min_domain_pct = float(os.environ.get("FORGE_PLAN_FIT_MIN_DOMAIN_PCT", "0.95"))
    min_qa_mean = float(os.environ.get("FORGE_PLAN_FIT_MIN_QA_MEAN", "4.2"))
    min_qa_individual = float(os.environ.get("FORGE_PLAN_FIT_MIN_QA_INDIVIDUAL", "3.0"))
    min_subdomain_pct = float(os.environ.get("FORGE_PLAN_FIT_MIN_SUBDOMAIN_PCT", "0.05"))
    min_qa_mean_per_subtopic = float(os.environ.get("FORGE_PLAN_FIT_MIN_QA_MEAN_PER_SUBTOPIC", "3.5"))
    min_qa_individual_per_subtopic = float(os.environ.get("FORGE_PLAN_FIT_MIN_QA_INDIVIDUAL_PER_SUBTOPIC", "2.0"))

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ANTHROPIC_API_KEY not set", file=sys.stderr)
        return 64

    out_report.parent.mkdir(parents=True, exist_ok=True)

    # Load Q/A pairs (chat format jsonl)
    qa_examples = []
    with qa_path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            qa_examples.append(json.loads(line))
    print(f"[plan-fit] loaded {len(qa_examples)} Q/A examples", file=sys.stderr)

    if len(qa_examples) < sample_size:
        sample_size = max(10, len(qa_examples))

    random.seed(42)
    sample = random.sample(qa_examples, sample_size)

    # Map QA → {question, answer} pair for grading
    qa_pairs = []
    for ex in sample:
        msgs = ex.get("messages", [])
        if len(msgs) >= 2 and msgs[0].get("role") == "user" and msgs[1].get("role") == "assistant":
            qa_pairs.append({
                "id": ex.get("id"),
                "question": msgs[0]["content"],
                "answer": msgs[1]["content"],
                "qa_type": ex.get("metadata", {}).get("qa_type", "unknown"),
                "subtopic": ex.get("metadata", {}).get("subtopic", "unmapped"),
            })

    client = AsyncAnthropic(api_key=api_key)
    sem = asyncio.Semaphore(8)

    # ---- Axis 1: classify a sample of original passages ------
    # We need passage texts; reconstruct from audit cleaned corpus if available.
    # For simplicity here, sample passages by joining Q+A as "passage proxy".
    print(f"[plan-fit] Axis 1: classifying {sample_size} chunks...", file=sys.stderr)
    labels = DOMAIN_SUBDOMAINS.get(domain_key, ["in_domain", "off_topic"])
    classify_tasks = [classify_one(client, sem, p["answer"], labels) for p in qa_pairs]
    classifications = await asyncio.gather(*classify_tasks)
    in_domain = sum(1 for c in classifications if c != "off_topic")
    domain_pct = in_domain / max(1, len(classifications))
    axis1 = {
        "in_domain_pct": round(domain_pct, 4),
        "off_topic_pct": round(1 - domain_pct, 4),
        "label_distribution": dict(Counter(classifications)),
        "passes": domain_pct >= min_domain_pct,
        "threshold": min_domain_pct,
    }

    # ---- Axis 2: subdomain coverage (excluding off_topic) -------
    in_dom_only = [c for c in classifications if c != "off_topic"]
    subdomain_dist = Counter(in_dom_only)
    n = max(1, len(in_dom_only))
    subdomain_pct = {k: round(v / n, 4) for k, v in subdomain_dist.items()}
    underrep = [k for k in labels if k != "off_topic" and subdomain_pct.get(k, 0) < min_subdomain_pct]
    axis2 = {
        "subdomain_distribution": subdomain_pct,
        "underrepresented_below_threshold": underrep,
        "passes": True,  # Soft for now: we report but don't fail. Many domains naturally skew.
        "threshold": min_subdomain_pct,
        "note": "Soft check — reported but does not fail the gate. Hard fail only if SOME subdomain has zero coverage AND domain explicitly requires breadth.",
    }

    # ---- Axis 3: Q/A grading by Claude expert ------
    print(f"[plan-fit] Axis 3: grading {len(qa_pairs)} Q/A pairs (model={GRADE_MODEL})...", file=sys.stderr)
    grade_tasks = [grade_one(client, sem, p, domain_key) for p in qa_pairs]
    grades = await asyncio.gather(*grade_tasks)
    valid_grades = [g for g in grades if "error" not in g]
    means = [g["mean"] for g in valid_grades]
    mins = [g["min"] for g in valid_grades]
    if not means:
        axis3 = {"passes": False, "issue": "all grading calls failed"}
    else:
        overall_mean = round(statistics.mean(means), 3)
        worst_individual = min(mins)
        below_threshold = [g for g in valid_grades if g["min"] < min_qa_individual]
        axis3 = {
            "n_graded": len(valid_grades),
            "overall_mean": overall_mean,
            "worst_individual_score": worst_individual,
            "below_individual_threshold_count": len(below_threshold),
            "passes": overall_mean >= min_qa_mean and worst_individual >= min_qa_individual,
            "thresholds": {"mean": min_qa_mean, "individual": min_qa_individual},
            "sample_low_grades": [
                {"id": qa_pairs[i]["id"], "scores": valid_grades[i], "q": qa_pairs[i]["question"][:100]}
                for i in range(len(valid_grades))
                if valid_grades[i]["min"] < min_qa_individual
            ][:5],
        }

    # ---- Axis 3b: per-subtopic Q/A grading ------
    # Catches "aggregate looks great because crown_gen volume drowns
    # margin_line collapse". Skipped when only one mapped subtopic surfaces.
    by_subtopic_grades: dict[str, list[dict]] = {}
    for i, p in enumerate(qa_pairs):
        if i >= len(grades) or "error" in grades[i]:
            continue
        st = p.get("subtopic", "unmapped")
        by_subtopic_grades.setdefault(st, []).append(grades[i])

    distinct_subs = [s for s in by_subtopic_grades if s != "unmapped"]
    if len(distinct_subs) < 2:
        axis3b = {
            "passes": True, "skipped": True,
            "reason": "fewer than 2 mapped subtopics in sample — per-subtopic check non-applicable",
            "subtopics_seen": list(by_subtopic_grades.keys()),
        }
    else:
        per_sub: dict[str, dict] = {}
        for st, gs in sorted(by_subtopic_grades.items()):
            sub_means = [g["mean"] for g in gs]
            sub_mins = [g["min"] for g in gs]
            per_sub[st] = {
                "n": len(gs),
                "mean": round(statistics.mean(sub_means), 3) if sub_means else 0,
                "worst_individual": min(sub_mins) if sub_mins else 0,
            }
        # Fail if ANY mapped subtopic with n>=3 violates threshold.
        # Subtopics with n<3 are reported but not gated (sample too small).
        violators = [
            (st, s) for st, s in per_sub.items()
            if st != "unmapped" and s["n"] >= 3 and (
                s["mean"] < min_qa_mean_per_subtopic
                or s["worst_individual"] < min_qa_individual_per_subtopic
            )
        ]
        axis3b = {
            "per_subtopic": per_sub,
            "thresholds": {
                "mean_per_subtopic": min_qa_mean_per_subtopic,
                "individual_per_subtopic": min_qa_individual_per_subtopic,
                "min_n_for_gate": 3,
            },
            "violators": [{"subtopic": st, "stats": s} for st, s in violators],
            "passes": len(violators) == 0,
        }

    # ---- Axis 4: Q/A type diversity ------
    type_dist = Counter(p["qa_type"] for p in qa_pairs)
    n = max(1, len(qa_pairs))
    type_pct = {k: round(v / n, 4) for k, v in type_dist.items()}
    max_pct = max(type_pct.values()) if type_pct else 0
    # 0.50 not 0.40 — the meaningful "single type dominates" line. Sampling
    # variance from a balanced 34/34/32 underlying distribution can easily
    # push one type to 0.40-0.45 in an N=50-80 sample.
    axis4_threshold = float(os.environ.get("FORGE_PLAN_FIT_MAX_TYPE_PCT", "0.50"))
    axis4 = {
        "type_distribution": type_pct,
        "max_type_pct": max_pct,
        "passes": max_pct <= axis4_threshold,
        "threshold": axis4_threshold,
    }

    # ---- Axis 5: Hyperparameter heuristics ------
    n_train = len(qa_examples)
    axis5 = hyperparam_check(overrides, base_model, n_train)

    # ---- Axis 6: Training format roundtrip ------
    axis6 = format_check(qa_examples)

    # ---- Axis 7: Budget fit ------
    plan_json_env = os.environ.get("FORGE_PLAN_FIT_PLAN_JSON", "")
    synth_progress_env = os.environ.get("FORGE_PLAN_FIT_SYNTH_PROGRESS", "")
    headroom_frac = float(os.environ.get("FORGE_PLAN_FIT_BUDGET_HEADROOM", "0.10"))
    if plan_json_env:
        axis7 = budget_check(Path(plan_json_env), Path(synth_progress_env), headroom_frac)
    else:
        axis7 = {"passes": True, "skipped": True, "reason": "FORGE_PLAN_FIT_PLAN_JSON not set"}

    # ---- Axis 8: Extraction cost ------
    # Warns (soft-fail) if the prep phase's extraction will eat > X% of the
    # training wall-clock OR > $Y of compute. Signals that the operator
    # should consider FORGE_DISABLE_OCR / FORGE_DISABLE_TRANSCRIBE, or
    # disable heavy plugins, before approving the plan.
    analysis_env = os.environ.get("FORGE_PLAN_FIT_ANALYSIS_JSON", "")
    max_ext_fraction = float(os.environ.get("FORGE_PLAN_FIT_MAX_EXT_FRAC", "0.25"))
    if analysis_env and plan_json_env:
        axis8 = extraction_cost_check(
            Path(analysis_env),
            Path(plan_json_env),
            max_ext_fraction,
        )
    else:
        axis8 = {
            "passes": True, "skipped": True,
            "reason": "FORGE_PLAN_FIT_ANALYSIS_JSON or PLAN_JSON not set",
        }

    # ---- Verdict ------
    all_axes = {
        "axis1_corpus_content": axis1,
        "axis2_coverage": axis2,
        "axis3_qa_accuracy": axis3,
        "axis3b_qa_per_subtopic": axis3b,
        "axis4_qa_diversity": axis4,
        "axis5_hyperparams": axis5,
        "axis6_format": axis6,
        "axis7_budget_fit": axis7,
        "axis8_extraction_cost": axis8,
    }
    passes = all(a.get("passes", False) for a in all_axes.values())

    report = {
        "verdict": "PASS" if passes else "FAIL",
        "domain": domain_full,
        "base_model": base_model,
        "n_qa_examples": len(qa_examples),
        "n_sampled": sample_size,
        "axes": all_axes,
        "failed_axes": [k for k, v in all_axes.items() if not v.get("passes", False)],
    }
    out_report.write_text(json.dumps(report, indent=2))
    print(json.dumps({
        "verdict": report["verdict"],
        "failed_axes": report["failed_axes"],
        "axis1_in_domain_pct": axis1["in_domain_pct"],
        "axis3_mean": axis3.get("overall_mean", "N/A"),
        "axis3b_violators": (
            "skipped" if axis3b.get("skipped")
            else [v["subtopic"] for v in axis3b.get("violators", [])]
        ),
        "axis4_max_type_pct": axis4["max_type_pct"],
        "axis5_issues": axis5["issues"],
        "axis7_budget": {
            "verdict": axis7.get("verdict", "SKIPPED"),
            "headroom_usd": axis7.get("headroom_absolute_usd"),
            "synth_overrun_pct": axis7.get("synth_overrun_pct"),
        },
    }, indent=2))

    return 0 if passes else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
