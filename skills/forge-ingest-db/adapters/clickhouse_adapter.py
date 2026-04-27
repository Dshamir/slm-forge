"""
ClickHouse adapter — clickhouse-connect (HTTP, recommended over driver).

conn config:
  host:        ch.example.com
  port:        8443                # 8443 (TLS) or 8123 (plain)
  database:    dental
  user:        default
  password:    <resolved-from-ref>
  secure:      true                # default true if port == 8443
  verify:      true                # TLS cert verification
  connect_timeout_sec: 30
"""
from __future__ import annotations

from typing import Iterator


def iter_rows(conn_cfg: dict, extraction: dict, batch_size: int = 1000) -> Iterator[dict]:
    try:
        import clickhouse_connect  # type: ignore
    except ImportError:
        raise ImportError(
            "clickhouse adapter requires clickhouse-connect — run:\n"
            "  /tmp/forge-venv/bin/pip install clickhouse-connect"
        )

    for k in ("host", "user"):
        if k not in conn_cfg:
            raise ValueError(f"clickhouse: conn.{k} (or {k}_ref) is required")

    port = int(conn_cfg.get("port", 8443))
    secure = bool(conn_cfg.get("secure", port == 8443))

    kwargs = {
        "host": conn_cfg["host"],
        "port": port,
        "username": conn_cfg["user"],
        "secure": secure,
        "verify": bool(conn_cfg.get("verify", True)),
        "connect_timeout": int(conn_cfg.get("connect_timeout_sec", 30)),
    }
    if "password" in conn_cfg:
        kwargs["password"] = conn_cfg["password"]
    if "database" in conn_cfg:
        kwargs["database"] = conn_cfg["database"]

    client = clickhouse_connect.get_client(**kwargs)
    try:
        query = extraction.get("query")
        if not query:
            raise ValueError(f"clickhouse: extraction {extraction.get('id')} missing query")
        # ClickHouse streams via query_row_block_stream (returns blocks)
        for block in client.query_row_block_stream(query):
            cols = block.column_names if hasattr(block, "column_names") else None
            for row in block:
                if cols:
                    yield dict(zip(cols, row))
                else:
                    # Older API path — fall back to query() materializing the result
                    yield dict(row) if isinstance(row, dict) else {"value": row}
    finally:
        client.close()
