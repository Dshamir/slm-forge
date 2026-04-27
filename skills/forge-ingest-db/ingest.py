#!/usr/bin/env python3
"""
forge-ingest-db — database ingestion entry point.

Reads a YAML config with N sources, dispatches each to the matching adapter,
emits canonical JSONL chunks to slm-forge/.runs/<run-id>/ingested-db.jsonl.

Usage: python ingest.py <run-id> <config.yaml>
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Iterator

try:
    import yaml
except ImportError:
    sys.stderr.write("forge-ingest-db: pyyaml required. pip install pyyaml\n")
    sys.exit(2)

# Make the shared chunk helpers + adapters + lib/secrets importable.
# _THIS = .../slm-forge/skills/forge-ingest-db
# .parent.parent = .../slm-forge
_THIS = Path(__file__).resolve().parent
sys.path.insert(0, str(_THIS.parent.parent / "scripts"))  # prep_plugins
sys.path.insert(0, str(_THIS.parent.parent / "lib"))      # secrets
sys.path.insert(0, str(_THIS / "adapters"))

from prep_plugins.orchestration_helpers import MIN_LEN, MAX_LEN, clean_text, hash_text  # noqa: E402
from prep_plugins.schema import validate_chunk  # noqa: E402

# Use the unified secrets resolver (env / file / vault). Falls back to the
# minimal in-file resolver below if lib/secrets.py somehow isn't importable.
try:
    from secrets import resolve_ref as _resolve_ref_unified, redact_for_logging  # noqa: E402
    _USE_UNIFIED_SECRETS = True
except ImportError:
    _USE_UNIFIED_SECRETS = False


# ---- Credential resolver -------------------------------------------------
# v2.2: prefer the unified resolver from slm-forge/lib/secrets.py — it adds
# real Vault KV v2 support, in-memory TTL cache, and a redact_for_logging
# helper. The fallback below covers env: and file: only (no vault), in case
# someone runs ingest.py with a non-standard sys.path.

if _USE_UNIFIED_SECRETS:
    resolve_ref = _resolve_ref_unified  # type: ignore
else:
    def resolve_ref(ref: str) -> str:
        if not isinstance(ref, str):
            return str(ref)
        if ref.startswith("env:"):
            var = ref[len("env:"):]
            val = os.environ.get(var)
            if val is None:
                raise KeyError(f"env ref {ref}: {var} not set")
            return val
        if ref.startswith("file:"):
            p = Path(ref[len("file:"):])
            if not p.is_file():
                raise FileNotFoundError(f"file ref {ref}: not found")
            return p.read_text().strip()
        if ref.startswith("vault:"):
            raise NotImplementedError(
                f"vault ref {ref}: lib/secrets.py not on path; use env: refs."
            )
        return ref

    def redact_for_logging(obj):
        # Minimal fallback redactor
        return obj


def resolve_conn_refs(conn: dict) -> dict:
    """Walk a conn dict, resolving any *_ref key into its non-_ref counterpart.
    E.g. {"host_ref": "env:PG_HOST"} → {"host": "dental-db.internal"}
    """
    resolved: dict = {}
    for k, v in conn.items():
        if k.endswith("_ref") and isinstance(v, str):
            bare = k[:-len("_ref")]
            resolved[bare] = resolve_ref(v)
        else:
            resolved[k] = v
    return resolved


def _scrub_config_for_logging(cfg: dict) -> dict:
    """Return a deep-copied config with _ref values redacted for safe logging."""
    out = json.loads(json.dumps(cfg))  # deep copy
    def walk(node):
        if isinstance(node, dict):
            for k, v in list(node.items()):
                if k.endswith("_ref") and isinstance(v, str):
                    node[k] = "<redacted>"
                else:
                    walk(v)
        elif isinstance(node, list):
            for item in node:
                walk(item)
    walk(out)
    return out


# ---- Row templating ------------------------------------------------------
_PLACEHOLDER_RE = re.compile(r"\{([a-zA-Z_][a-zA-Z_0-9]*)\}")


def render_template(tmpl: str, row: dict) -> str:
    """Safe {field} substitution. Missing fields → empty string (warn)."""
    missing = []
    def repl(m):
        field = m.group(1)
        if field in row and row[field] is not None:
            return str(row[field])
        missing.append(field)
        return ""
    out = _PLACEHOLDER_RE.sub(repl, tmpl)
    if missing:
        sys.stderr.write(f"  [template missing fields: {sorted(set(missing))}]\n")
    return out


# ---- Adapter dispatch ----------------------------------------------------
def _load_adapter(kind: str):
    """Load the adapter module by kind."""
    _ADAPTER_MODULES = {
        "sqlite":     "sqlite_adapter",
        "postgres":   "postgres_adapter",
        "mysql":      "mysql_adapter",
        "mongodb":    "mongo_adapter",
        "duckdb":     "duckdb_adapter",
        "mssql":      "mssql_adapter",
        "clickhouse": "clickhouse_adapter",
        "snowflake":  "snowflake_adapter",
        "bigquery":   "bigquery_adapter",
        "cassandra":  "cassandra_adapter",
    }
    mod_name = _ADAPTER_MODULES.get(kind)
    if mod_name is None:
        raise ValueError(f"unknown source kind: {kind}")
    try:
        return __import__(mod_name)
    except ImportError as e:
        raise ImportError(f"adapter for kind={kind} not available: {e}") from e


# ---- Main ---------------------------------------------------------------
def process_source(source: dict, seen_hashes: set) -> Iterator[dict]:
    name = source["name"]
    kind = source["kind"]
    sys.stderr.write(f"[ingest-db] source={name} kind={kind}\n")
    adapter = _load_adapter(kind)

    conn_cfg = resolve_conn_refs(source["conn"])

    for extraction in source.get("extractions", []):
        ext_id = extraction["id"]
        sys.stderr.write(f"[ingest-db]   extraction={ext_id}\n")
        id_tmpl = extraction.get("id_template", f"{name}-{ext_id}-{{_row}}")
        text_tmpl = extraction["text_template"]
        meta_extra = extraction.get("metadata", {}) or {}
        limit = extraction.get("limit")
        batch_size = extraction.get("batch_size", 1000)

        row_idx = 0
        for row in adapter.iter_rows(conn_cfg, extraction, batch_size=batch_size):
            if limit is not None and row_idx >= limit:
                break
            # Provide _row as a fallback id field
            row_with_idx = dict(row, _row=row_idx)
            rid = render_template(id_tmpl, row_with_idx).strip() or f"{name}-{ext_id}-{row_idx}"
            text = clean_text(render_template(text_tmpl, row))

            if not text or len(text) < MIN_LEN:
                row_idx += 1
                continue
            if len(text) > MAX_LEN:
                # v1 splitter: halve at nearest paragraph
                mid = len(text) // 2
                split = text.rfind("\n\n", 0, mid)
                if split == -1:
                    split = mid
                for j, half in enumerate([text[:split], text[split:]]):
                    if MIN_LEN <= len(half) <= MAX_LEN:
                        h = hash_text(half)
                        if h in seen_hashes:
                            continue
                        seen_hashes.add(h)
                        yield _make_chunk(
                            rid + f"-part{j}", half, name, ext_id,
                            kind, row_idx, meta_extra,
                        )
                row_idx += 1
                continue

            h = hash_text(text)
            if h in seen_hashes:
                row_idx += 1
                continue
            seen_hashes.add(h)
            yield _make_chunk(rid, text, name, ext_id, kind, row_idx, meta_extra)
            row_idx += 1

        sys.stderr.write(f"[ingest-db]   {ext_id}: {row_idx} rows processed\n")


def _make_chunk(rid, text, source_name, extraction_id, kind, row_idx, meta_extra):
    meta = {
        "source_file": f"{source_name}:{extraction_id}",
        "source_format": kind,
        "section": meta_extra.get("section", source_name),
        "doc_title": extraction_id,
        "chunk_type": "db-row",
        "chunk_idx": row_idx,
        "char_count": len(text),
    }
    # Overlay any operator-supplied metadata (doesn't override required fields)
    for k, v in meta_extra.items():
        if k not in meta:
            meta[k] = v
    return {"id": rid, "text": text, "format": "pretrain", "metadata": meta}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_id", help="run-id (determines output path)")
    ap.add_argument("config", nargs="?",
                    help="path to db-sources.yaml; defaults to runs/<run-id>/db-sources.yaml")
    ap.add_argument("--print-config", action="store_true",
                    help="echo the parsed (scrubbed) config and exit")
    args = ap.parse_args()

    run_dir = Path(__file__).resolve().parent.parent.parent / ".runs" / args.run_id
    config_path = Path(args.config) if args.config else (run_dir / "db-sources.yaml")
    if not config_path.is_file():
        sys.stderr.write(f"forge-ingest-db: config not found: {config_path}\n")
        return 1

    with open(config_path) as f:
        cfg = yaml.safe_load(f)

    if cfg.get("version") != 1:
        sys.stderr.write(f"forge-ingest-db: unsupported config version {cfg.get('version')}\n")
        return 2

    if args.print_config:
        print(json.dumps(_scrub_config_for_logging(cfg), indent=2))
        return 0

    out_path = run_dir / "ingested-db.jsonl"
    stats_path = run_dir / "ingested-db-stats.json"
    run_dir.mkdir(parents=True, exist_ok=True)

    seen_hashes: set = set()
    by_source: dict = {}
    total = 0

    schema_failures = 0
    with open(out_path, "w") as out:
        for source in cfg.get("sources", []):
            n_for_source = 0
            try:
                for chunk in process_source(source, seen_hashes):
                    ok, reason = validate_chunk(chunk)
                    if not ok:
                        schema_failures += 1
                        if schema_failures <= 5:
                            sys.stderr.write(f"  [schema] {chunk.get('id','?')}: {reason}\n")
                        continue
                    out.write(json.dumps(chunk) + "\n")
                    total += 1
                    n_for_source += 1
            except Exception as e:
                sys.stderr.write(f"[ingest-db] source {source.get('name')} FAILED: {type(e).__name__}: {e}\n")
            by_source[source.get("name", "?")] = n_for_source

    stats = {
        "total_chunks": total,
        "by_source": by_source,
        "schema_failures": schema_failures,
        "output_path": str(out_path),
    }
    stats_path.write_text(json.dumps(stats, indent=2))
    print(json.dumps({
        "status": "completed",
        "path": str(out_path),
        "total_chunks": total,
        "by_source": by_source,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
