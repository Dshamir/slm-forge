#!/usr/bin/env python3
"""
slm-forge/scripts/prep-publications.py

v2.1 shim — delegates to prep-orchestrator.py. Kept at this path so legacy
callers (forge-prep/run.sh, kickoff scripts, docs that reference this name)
keep working unchanged.
"""
from __future__ import annotations

import runpy
import sys
from pathlib import Path

_ORCHESTRATOR = Path(__file__).resolve().parent / "prep-orchestrator.py"

if __name__ == "__main__":
    # runpy is more reliable than exec here: preserves __name__ == "__main__"
    # semantics and argv pass-through.
    runpy.run_path(str(_ORCHESTRATOR), run_name="__main__")
