#!/usr/bin/env python3
"""
forge-audit core script — domain-aware corpus contamination filter.

Driven by env vars (set by run.sh):
  FORGE_AUDIT_INPUT          path to input JSONL (concatenated curated shards)
  FORGE_AUDIT_OUT_CLEAN      path to write cleaned JSONL
  FORGE_AUDIT_OUT_REPORT     path to write audit-report.json
  FORGE_AUDIT_DOMAIN         domain key (e.g. "dental.ai.research", "medical", "legal")
  FORGE_AUDIT_MIN_TOKENS     kill-condition threshold (default 500_000)
  FORGE_AUDIT_MIN_DENSITY    domain-keyword density floor (default 0.008)
  FORGE_AUDIT_MIN_CATEGORIES number of distinct categories that must hit (default 2)
  FORGE_AUDIT_MIN_ABSOLUTE   absolute minimum hits per chunk (default 5)

Hard fails (exit 1) if cleaned token count < FORGE_AUDIT_MIN_TOKENS.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

from datasketch import MinHash, MinHashLSH


# ----- Domain keyword sets --------------------------------------------------
# Add more domains here. Each domain is { category: {kw, kw, ...}, ... }.

DOMAIN_KEYWORDS = {
    "dental": {
        "anatomy": {
            "tooth", "teeth", "molar", "premolar", "canine", "incisor",
            "enamel", "dentin", "dentine", "pulp", "gum", "gums", "gingiva",
            "gingival", "periodontal", "periodontium", "cusp", "cuspal",
            "mandible", "mandibular", "maxilla", "maxillary", "alveolar",
            "occlusal", "occlusion", "buccal", "lingual", "palatal", "mesial",
            "distal", "apical", "coronal", "cementum",
        },
        "procedure_material": {
            "dental", "dentist", "dentistry", "filling", "restoration",
            "restorative", "endodontic", "endodontics", "orthodontic",
            "orthodontics", "prosthodontic", "prosthodontics", "implant",
            "implants", "denture", "bridge", "veneer", "amalgam", "composite",
            "ceramic", "zirconia", "porcelain", "scaling", "rootcanal",
            "endo", "perio", "extraction", "crown", "crowns", "polishing",
            "fluoride", "sealant",
        },
        "condition": {
            "caries", "cavity", "cavities", "decay", "plaque", "tartar",
            "calculus", "abscess", "gingivitis", "periodontitis",
            "malocclusion", "halitosis", "bruxism", "tmj", "tmd",
        },
        "imaging_clinical": {
            "intraoral", "panoramic", "cbct", "stl", "ply", "impression",
            "margin", "preparation", "prep", "saliva", "mastication",
            "abutment", "radiograph", "radiographic", "scaler", "curette",
        },
    },
    # Future domains slot in here. The skill consults DOMAIN_KEYWORDS by
    # the FIRST dotted segment of FORGE_AUDIT_DOMAIN — e.g. "dental.ai.research"
    # → "dental"; "medical.cardiology" → "medical".
}


SPEAKER_RE = re.compile(r"(?m)^\s*(A|B|C|D|Q|Host|Guest|Speaker|Interviewer|Interviewee)\s*[:\-]\s+")
SLOP_PHRASES = [
    r"\brevolutioniz\w+\b", r"\bexciting journey\b", r"\bgame[- ]chang\w+\b",
    r"\bin conclusion\b", r"\bit is important to note\b",
    r"\bunlock the potential\b", r"\bleverage (the|our|your)\b",
    r"\bcutting[- ]edge\b", r"\bstate[- ]of[- ]the[- ]art\b",
    r"\bdelve into\b", r"\bharness the power\b", r"\bever[- ]evolving\b",
    r"\bseamlessly\b", r"\btestament to\b",
]
SLOP_RE = re.compile("|".join(SLOP_PHRASES), re.IGNORECASE)
TRIPLE_RE = re.compile(r"\b(\w{3,})\s+\1\s+\1\b", re.IGNORECASE)
SAFETY_RE = re.compile(
    r"(I am not (qualified|a doctor|a (medical|dental) professional)|"
    r"please (note|consult) (that|with|a)|"
    r"this (information|content|is for) (is for )?(general|educational|informational))",
    re.IGNORECASE,
)


def shingle(text: str, k: int = 5) -> set[str]:
    words = re.findall(r"\w+", text.lower())
    if len(words) < k:
        return {" ".join(words)} if words else set()
    return {" ".join(words[i:i + k]) for i in range(len(words) - k + 1)}


def minhash_of(text: str, num_perm: int = 128) -> MinHash:
    mh = MinHash(num_perm=num_perm)
    for s in shingle(text):
        mh.update(s.encode("utf-8"))
    return mh


def domain_density_check(text: str, domain_key: str, min_density: float, min_categories: int, min_absolute: int) -> tuple[bool, float]:
    cats = DOMAIN_KEYWORDS.get(domain_key)
    if not cats:
        # No domain set defined — accept everything (other checks still fire).
        return True, 1.0
    words = re.findall(r"\b\w+\b", text.lower())
    n_words = len(words)
    if n_words < 50:
        return False, 0.0
    cat_hits = {cat: 0 for cat in cats}
    for w in words:
        for cat, kws in cats.items():
            if w in kws:
                cat_hits[cat] += 1
                break
    total = sum(cat_hits.values())
    density = total / n_words
    cats_with_hits = sum(1 for n in cat_hits.values() if n >= 2)
    return (
        density >= min_density
        and cats_with_hits >= min_categories
        and total >= min_absolute,
        density,
    )


def main() -> int:
    in_path = Path(os.environ["FORGE_AUDIT_INPUT"])
    out_clean = Path(os.environ["FORGE_AUDIT_OUT_CLEAN"])
    out_report = Path(os.environ["FORGE_AUDIT_OUT_REPORT"])
    domain_full = os.environ.get("FORGE_AUDIT_DOMAIN", "general")
    domain_key = domain_full.split(".", 1)[0]
    min_tokens = int(os.environ.get("FORGE_AUDIT_MIN_TOKENS", "500000"))
    min_density = float(os.environ.get("FORGE_AUDIT_MIN_DENSITY", "0.008"))
    min_categories = int(os.environ.get("FORGE_AUDIT_MIN_CATEGORIES", "2"))
    min_absolute = int(os.environ.get("FORGE_AUDIT_MIN_ABSOLUTE", "5"))
    drop_chunk_types = set(
        s.strip() for s in os.environ.get("FORGE_AUDIT_DROP_CHUNK_TYPES", "").split(",")
        if s.strip()
    )
    min_words = int(os.environ.get("FORGE_AUDIT_MIN_WORDS", "0"))
    near_dup_threshold = float(os.environ.get("FORGE_AUDIT_NEAR_DUP_THRESHOLD", "0.85"))

    out_clean.parent.mkdir(parents=True, exist_ok=True)
    out_report.parent.mkdir(parents=True, exist_ok=True)

    docs = []
    with in_path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "text" in d:
                docs.append(d)

    n_input = len(docs)
    flagged = defaultdict(list)
    drops = set()
    keep = []
    seen_sha = set()
    total_chars_in = sum(len(d["text"]) for d in docs)
    lsh = MinHashLSH(threshold=near_dup_threshold, num_perm=128)

    for d in docs:
        text = d["text"]
        did = d["id"]

        # F1: drop unwanted chunk_types (xlsx rows, image OCR, etc.)
        if drop_chunk_types:
            ct = d.get("metadata", {}).get("chunk_type", "")
            # chunk_types may have suffixes like "row-split"; match the prefix
            if ct in drop_chunk_types or ct.split("-")[0] in drop_chunk_types:
                flagged["drop_chunk_type"].append(did); drops.add(did); continue

        # F2: drop chunks with too few words (table cells, slide bullets, OCR fragments)
        if min_words > 0:
            n_words = len(text.split())
            if n_words < min_words:
                flagged["below_min_words"].append(did); drops.add(did); continue

        if len(SPEAKER_RE.findall(text)) >= 2:
            flagged["speaker_labels"].append(did); drops.add(did)

        n_slop = len(SLOP_RE.findall(text))
        if n_slop >= 2:
            flagged["llm_slop"].append(did); drops.add(did)

        if TRIPLE_RE.search(text):
            text = TRIPLE_RE.sub(lambda m: m.group(1), text)
            d = dict(d, text=text)
            flagged["triple_word_healed"].append(did)

        if SAFETY_RE.search(text):
            flagged["safety_boilerplate"].append(did); drops.add(did)

        is_dom, dens = domain_density_check(text, domain_key, min_density, min_categories, min_absolute)
        if not is_dom:
            flagged["off_domain"].append(did); drops.add(did)

        sha = hashlib.sha256(re.sub(r"\s+", " ", text.lower()).strip().encode()).hexdigest()
        if sha in seen_sha:
            flagged["exact_dup"].append(did); drops.add(did)
            continue
        seen_sha.add(sha)

        if did in drops:
            continue

        mh = minhash_of(text)
        dups = lsh.query(mh)
        if dups:
            flagged["near_dup"].append(did); drops.add(did)
            continue
        unique_key = did
        suffix = 0
        while unique_key in lsh:
            suffix += 1
            unique_key = f"{did}__{suffix}"
        lsh.insert(unique_key, mh)

        d["text"] = text
        keep.append(d)

    total_chars_out = sum(len(d["text"]) for d in keep)
    approx_tokens_out = total_chars_out // 4
    kill_passes = approx_tokens_out >= min_tokens

    report = {
        "domain_key_used": domain_key,
        "thresholds": {
            "min_tokens": min_tokens,
            "min_density": min_density,
            "min_categories": min_categories,
            "min_absolute": min_absolute,
        },
        "input": {
            "doc_count": n_input,
            "total_chars": total_chars_in,
            "approx_tokens": total_chars_in // 4,
        },
        "output": {
            "doc_count": len(keep),
            "total_chars": total_chars_out,
            "approx_tokens": approx_tokens_out,
            "kept_pct": round(100 * len(keep) / max(1, n_input), 2),
        },
        "drops_by_reason": {r: len(v) for r, v in flagged.items() if r in (
            "speaker_labels", "llm_slop", "safety_boilerplate", "off_domain", "exact_dup", "near_dup",
            "drop_chunk_type", "below_min_words",
        )},
        "warnings": {"triple_word_healed": len(flagged.get("triple_word_healed", []))},
        "kill_condition": {
            "min_clean_tokens": min_tokens,
            "actual_clean_tokens": approx_tokens_out,
            "passes": kill_passes,
        },
    }
    out_report.write_text(json.dumps(report, indent=2))

    with out_clean.open("w") as f:
        for d in keep:
            f.write(json.dumps(d) + "\n")

    return 0 if kill_passes else 1


if __name__ == "__main__":
    sys.exit(main())
