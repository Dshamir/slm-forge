"""
prep_plugins package — plugin registry for the multi-format text extractor.

The orchestrator (scripts/prep-orchestrator.py) imports `get_dispatcher()`
which returns a dict mapping each recognized file extension to the plugin
module that handles it.

Plugins are opt-in by extension match. Plugins with heavy dependencies
(OCR, whisper) check their `disable_env` env var and yield nothing if it's
set to "1" — the file is then skipped with a log line (not an error).

Extensions appearing in ALWAYS_IGNORE but NOT in any plugin's extension set
are completely bypassed with a counted log line. This lets forge-analyze
report "skipped 705 STL files" transparently without crashing.
"""
from __future__ import annotations

import importlib
import os
from typing import Dict

# -- Always-ignore extensions ----------------------------------------------
# Files matching these are never fed to any plugin. Their counts are still
# tracked by the orchestrator and reported in the output stats so nothing
# is silently dropped.
ALWAYS_IGNORE_EXTENSIONS: frozenset = frozenset({
    # Lock/temp/hidden
    ".lock", ".swp", ".tmp", ".temp", ".bak", ".old",
    # DS_Store / OS metadata
    ".ds_store",
    # Compiled artifacts (non-text)
    ".pyc", ".pyo",
})

# -- Plugin module names to try loading ------------------------------------
# Order doesn't matter — each plugin declares its own extensions.
_PLUGIN_MODULES = (
    "pdf",
    "docx_plugin",
    "pptx_plugin",
    "text_simple",
    # Additional plugins layered in by Commits B and C:
    "epub",
    "notebook",
    "code",
    "tabular",
    "archive",
    "mesh_metadata",
    "binary_metadata",
    "ocr",
    "audio",
    "video",
    # v2.2: must be listed AFTER binary_metadata so its mysql extensions
    # (.frm/.myi/.myd/.ibd/.ibdata) override the sparse-metadata fallback.
    "mysql_revive",
    # v2.3: gap-recon expansion plugins
    "email_plugin",   # .eml .mbox .mbx
    "dicom",          # .dcm .dicom (medical imaging metadata)
    "geo",            # .geojson .shp
    "scientific",     # .h5 .hdf5 .nc (HDF5 + NetCDF schema-only)
)


def _try_import(name: str):
    try:
        return importlib.import_module(f"prep_plugins.{name}")
    except ImportError:
        return None


def get_dispatcher() -> Dict[str, object]:
    """Return {extension: plugin_module} dict for all loaded + enabled plugins.

    A plugin is "enabled" if:
      - its module loaded successfully (required deps available)
      - AND its disable_env is NOT set to "1" (respects operator opt-outs)
    """
    dispatch: Dict[str, object] = {}
    for mod_name in _PLUGIN_MODULES:
        mod = _try_import(mod_name)
        if mod is None or not hasattr(mod, "PLUGIN"):
            continue
        plugin = mod.PLUGIN
        # Check disable env
        if plugin.disable_env and os.environ.get(plugin.disable_env) == "1":
            continue
        for ext in plugin.extensions:
            dispatch[ext.lower()] = plugin
    return dispatch


def list_available_plugins() -> list[dict]:
    """For forge-analyze: describe which plugins are loaded + any disabled."""
    result = []
    for mod_name in _PLUGIN_MODULES:
        mod = _try_import(mod_name)
        if mod is None or not hasattr(mod, "PLUGIN"):
            result.append({"name": mod_name, "loaded": False, "reason": "import-failed"})
            continue
        plugin = mod.PLUGIN
        disabled = bool(plugin.disable_env and os.environ.get(plugin.disable_env) == "1")
        result.append({
            "name": mod_name,
            "loaded": True,
            "extensions": list(plugin.extensions),
            "source_format": plugin.source_format,
            "requires": list(plugin.requires),
            "system_deps": list(plugin.system_deps),
            "default_on": plugin.default_on,
            "disable_env": plugin.disable_env,
            "disabled": disabled,
        })
    return result
