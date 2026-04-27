"""
Orchestration helpers — utilities shared by all plugins + the orchestrator.

Extracted from prep-publications.py so plugins can import them without
circular deps.
"""
from __future__ import annotations

import hashlib
import re


MIN_LEN = 200
MAX_LEN = 100_000


def norm_id(s: str) -> str:
    """Normalize a filename or string to a safe id component.

    Replaces non-alphanumeric-ish chars with dashes, trims, caps at 120.
    Mirrors prep-publications.py::norm_id byte-for-byte.
    """
    s = re.sub(r"[^a-zA-Z0-9._-]+", "-", s).strip("-")
    return s[:120] or "doc"


def clean_text(t: str) -> str:
    """Collapse PDF line-break artifacts + normalize whitespace.

    Mirrors prep-publications.py::clean_text byte-for-byte.
    """
    t = re.sub(r"-\n", "", t)              # hyphen-linebreak
    t = re.sub(r"\s+\n", "\n", t)
    t = re.sub(r"\n{3,}", "\n\n", t)
    t = re.sub(r"[ \t]+", " ", t)
    return t.strip()


def hash_text(t: str) -> str:
    """SHA-256 of the normalized (whitespace-collapsed, lowercase) text.

    Mirrors prep-publications.py::hash_text byte-for-byte.
    """
    normalized = re.sub(r"\s+", " ", t.lower()).strip()
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()
