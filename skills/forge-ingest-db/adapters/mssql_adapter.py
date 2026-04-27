"""
MS SQL Server adapter — pymssql (FreeTDS-based, no system ODBC needed).

conn config:
  host:        sql.example.com
  port:        1433
  database:    publications
  user:        forge_readonly
  password:    <resolved-from-ref>
  charset:     UTF-8        # optional
  tds_version: 7.4          # optional; pymssql default usually fine
  connect_timeout_sec: 30
"""
from __future__ import annotations

from typing import Iterator


def iter_rows(conn_cfg: dict, extraction: dict, batch_size: int = 1000) -> Iterator[dict]:
    try:
        import pymssql
    except ImportError:
        raise ImportError(
            "mssql adapter requires pymssql — run:\n"
            "  /tmp/forge-venv/bin/pip install pymssql"
        )

    for k in ("host", "database", "user"):
        if k not in conn_cfg:
            raise ValueError(f"mssql: conn.{k} (or {k}_ref) is required")

    kwargs = {
        "server": conn_cfg["host"],
        "port": int(conn_cfg.get("port", 1433)),
        "database": conn_cfg["database"],
        "user": conn_cfg["user"],
        "login_timeout": int(conn_cfg.get("connect_timeout_sec", 30)),
    }
    if "password" in conn_cfg:
        kwargs["password"] = conn_cfg["password"]
    if "charset" in conn_cfg:
        kwargs["charset"] = conn_cfg["charset"]
    if "tds_version" in conn_cfg:
        kwargs["tds_version"] = conn_cfg["tds_version"]

    conn = pymssql.connect(**kwargs)
    try:
        cur = conn.cursor(as_dict=True)
        query = extraction.get("query")
        if not query:
            raise ValueError(f"mssql: extraction {extraction.get('id')} missing query")
        cur.execute(query)
        while True:
            rows = cur.fetchmany(batch_size)
            if not rows:
                break
            for row in rows:
                yield dict(row)
    finally:
        conn.close()
