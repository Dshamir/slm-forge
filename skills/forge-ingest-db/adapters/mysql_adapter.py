"""
MySQL adapter — pymysql driver.

conn config (after credential resolution):
  host:        db.example.com
  port:        3306
  database:    publications
  user:        forge_readonly
  password:    <resolved-from-ref>
  charset:     utf8mb4   (default)
  ssl_disabled: false    (default false; set true to disable SSL)
  connect_timeout_sec: 30
"""
from __future__ import annotations

import sys
from typing import Iterator


def iter_rows(conn_cfg: dict, extraction: dict, batch_size: int = 1000) -> Iterator[dict]:
    try:
        import pymysql
        import pymysql.cursors
    except ImportError:
        raise ImportError(
            "mysql adapter requires pymysql — run:\n"
            "  /tmp/forge-venv/bin/pip install pymysql"
        )

    required = ("host", "database", "user")
    for k in required:
        if k not in conn_cfg:
            raise ValueError(f"mysql: conn.{k} (or {k}_ref) is required")

    connect_kwargs = {
        "host": conn_cfg["host"],
        "port": int(conn_cfg.get("port", 3306)),
        "database": conn_cfg["database"],
        "user": conn_cfg["user"],
        "charset": conn_cfg.get("charset", "utf8mb4"),
        "connect_timeout": int(conn_cfg.get("connect_timeout_sec", 30)),
        "cursorclass": pymysql.cursors.SSDictCursor,  # streaming, dict rows
    }
    if "password" in conn_cfg:
        connect_kwargs["password"] = conn_cfg["password"]
    if conn_cfg.get("ssl_disabled"):
        connect_kwargs["ssl"] = None
    elif "ssl_ca" in conn_cfg:
        connect_kwargs["ssl"] = {"ca": conn_cfg["ssl_ca"]}

    conn = pymysql.connect(**connect_kwargs)
    try:
        with conn.cursor() as cur:
            query = extraction.get("query")
            if not query:
                raise ValueError(f"mysql: extraction {extraction.get('id')} missing query")
            cur.execute(query)
            while True:
                rows = cur.fetchmany(batch_size)
                if not rows:
                    break
                for row in rows:
                    yield dict(row)
    finally:
        conn.close()
