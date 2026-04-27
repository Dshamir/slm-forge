"""
DuckDB adapter — modern columnar OLAP database used heavily in data
pipelines. Reads from .duckdb files, in-memory, or directly from
parquet / CSV / JSON via DuckDB's built-in scanners.

conn config:
  path:        /path/to/file.duckdb          # required (':memory:' for ephemeral)
  read_only:   true                          # default true; matches sqlite adapter
  threads:     4                             # optional; defaults to DuckDB default
  attach:                                    # optional list of files to ATTACH
    - {alias: "raw", path: "s3://bucket/raw.parquet"}
    - {alias: "csv", path: "/data/table.csv"}

extraction config (same shape as sqlite/postgres):
  id:           abstracts
  query:        "SELECT * FROM read_parquet('papers.parquet')"
  id_template:  "duck-{id}"
  text_template: "{title}\n\n{body}"
  batch_size:   1000

DuckDB supports first-class parquet / csv / json scanning, so a single
extraction can pull from S3 parquet, local CSVs, or an .duckdb file
without an explicit ETL step.
"""
from __future__ import annotations

from pathlib import Path
from typing import Iterator


def iter_rows(conn_cfg: dict, extraction: dict, batch_size: int = 1000) -> Iterator[dict]:
    try:
        import duckdb  # type: ignore
    except ImportError:
        raise ImportError(
            "duckdb adapter requires the `duckdb` package — run:\n"
            "  /tmp/forge-venv/bin/pip install duckdb"
        )

    path = conn_cfg.get("path", ":memory:")
    read_only = bool(conn_cfg.get("read_only", True))
    if path != ":memory:":
        p = Path(path)
        if not p.is_file() and read_only:
            raise FileNotFoundError(
                f"duckdb: {path} not found (read_only=True). "
                f"Set read_only:false to create, or fix the path."
            )

    config = {}
    threads = conn_cfg.get("threads")
    if threads:
        config["threads"] = int(threads)

    conn = duckdb.connect(database=path, read_only=read_only, config=config)
    try:
        # Optional ATTACH-style external sources for cross-format joins.
        # Useful when you want to query a parquet directory as a virtual
        # table in your extraction SQL.
        for att in conn_cfg.get("attach", []) or []:
            alias = att.get("alias")
            ap = att.get("path")
            if not alias or not ap:
                continue
            # Use ATTACH for .duckdb files; otherwise CREATE VIEW
            if ap.endswith(".duckdb"):
                conn.execute(f"ATTACH '{ap}' AS {alias}")
            elif ap.endswith(".parquet"):
                conn.execute(f"CREATE VIEW {alias} AS SELECT * FROM read_parquet('{ap}')")
            elif ap.endswith(".csv"):
                conn.execute(f"CREATE VIEW {alias} AS SELECT * FROM read_csv_auto('{ap}')")
            elif ap.endswith((".json", ".ndjson", ".jsonl")):
                conn.execute(f"CREATE VIEW {alias} AS SELECT * FROM read_json_auto('{ap}')")

        query = extraction.get("query")
        if not query:
            raise ValueError(f"duckdb: extraction {extraction.get('id')} missing query")

        cur = conn.execute(query)
        cols = [d[0] for d in cur.description] if cur.description else []
        while True:
            rows = cur.fetchmany(batch_size)
            if not rows:
                break
            for row in rows:
                yield dict(zip(cols, row))
    finally:
        conn.close()
