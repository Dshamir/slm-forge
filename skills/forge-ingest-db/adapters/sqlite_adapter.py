"""
SQLite adapter — stdlib sqlite3, no extra deps.

conn config:
  path: /absolute/or/relative/path.db     # required
  read_only: true                         # optional, defaults true (file:...?mode=ro)
  timeout_sec: 30                         # optional
"""
from __future__ import annotations

import sqlite3
import sys
from pathlib import Path
from typing import Iterator


def iter_rows(conn_cfg: dict, extraction: dict, batch_size: int = 1000) -> Iterator[dict]:
    path = conn_cfg.get("path")
    if not path:
        raise ValueError("sqlite: conn.path is required")
    p = Path(path)
    if not p.is_file():
        raise FileNotFoundError(f"sqlite: {path} not found")

    read_only = conn_cfg.get("read_only", True)
    timeout_sec = float(conn_cfg.get("timeout_sec", 30))

    if read_only:
        uri = f"file:{p.absolute()}?mode=ro"
        conn = sqlite3.connect(uri, uri=True, timeout=timeout_sec)
    else:
        conn = sqlite3.connect(str(p), timeout=timeout_sec)

    conn.row_factory = sqlite3.Row
    try:
        cur = conn.cursor()
        query = extraction.get("query")
        if not query:
            raise ValueError(f"sqlite: extraction {extraction.get('id')} missing query")
        cur.execute(query)
        while True:
            rows = cur.fetchmany(batch_size)
            if not rows:
                break
            for row in rows:
                yield dict(row)
    finally:
        conn.close()
