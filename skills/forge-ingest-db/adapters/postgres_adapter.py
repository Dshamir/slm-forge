"""
PostgreSQL adapter — psycopg2-binary.

conn config (after credential resolution):
  host:        db.example.com
  port:        5432
  database:    publications
  user:        forge_readonly
  password:    <resolved-from-ref>
  sslmode:     prefer | require | disable
  connect_timeout_sec: 30
"""
from __future__ import annotations

import sys
from typing import Iterator


def iter_rows(conn_cfg: dict, extraction: dict, batch_size: int = 1000) -> Iterator[dict]:
    try:
        import psycopg2
        import psycopg2.extras
    except ImportError:
        raise ImportError(
            "postgres adapter requires psycopg2-binary — run:\n"
            "  /tmp/forge-venv/bin/pip install psycopg2-binary"
        )

    required = ("host", "database", "user")
    for k in required:
        if k not in conn_cfg:
            raise ValueError(f"postgres: conn.{k} (or {k}_ref) is required")

    connect_kwargs = {
        "host": conn_cfg["host"],
        "port": int(conn_cfg.get("port", 5432)),
        "database": conn_cfg["database"],
        "user": conn_cfg["user"],
        "connect_timeout": int(conn_cfg.get("connect_timeout_sec", 30)),
    }
    if "password" in conn_cfg:
        connect_kwargs["password"] = conn_cfg["password"]
    if "sslmode" in conn_cfg:
        connect_kwargs["sslmode"] = conn_cfg["sslmode"]

    conn = psycopg2.connect(**connect_kwargs)
    conn.set_session(readonly=True, autocommit=True)
    try:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        query = extraction.get("query")
        if not query:
            raise ValueError(f"postgres: extraction {extraction.get('id')} missing query")
        cur.itersize = batch_size
        cur.execute(query)
        for row in cur:
            # RealDictCursor returns dict-like; coerce to plain dict
            yield dict(row)
    finally:
        conn.close()
