"""
Snowflake adapter — snowflake-connector-python.

conn config:
  account:      xy12345.us-east-1     # required (Snowflake account locator)
  user:         FORGE_READER
  password:     <resolved-from-ref>     # OR
  private_key_path: /path/to/rsa_key.p8 # key-pair auth (preferred)
  warehouse:    COMPUTE_WH
  database:     DENTAL_DB
  schema:       PUBLIC
  role:         FORGE_READ_ROLE        # optional
  ocsp_fail_open: true                 # optional
"""
from __future__ import annotations

from typing import Iterator


def iter_rows(conn_cfg: dict, extraction: dict, batch_size: int = 1000) -> Iterator[dict]:
    try:
        import snowflake.connector  # type: ignore
    except ImportError:
        raise ImportError(
            "snowflake adapter requires snowflake-connector-python — run:\n"
            "  /tmp/forge-venv/bin/pip install snowflake-connector-python"
        )

    for k in ("account", "user"):
        if k not in conn_cfg:
            raise ValueError(f"snowflake: conn.{k} (or {k}_ref) is required")

    kwargs = {
        "account": conn_cfg["account"],
        "user": conn_cfg["user"],
    }
    for k in ("password", "warehouse", "database", "schema", "role"):
        if k in conn_cfg:
            kwargs[k] = conn_cfg[k]
    if "ocsp_fail_open" in conn_cfg:
        kwargs["ocsp_fail_open"] = bool(conn_cfg["ocsp_fail_open"])

    # Key-pair auth (Snowflake's recommended path) — load PEM
    if "private_key_path" in conn_cfg and "password" not in kwargs:
        try:
            from cryptography.hazmat.primitives import serialization
            from cryptography.hazmat.backends import default_backend
        except ImportError:
            raise ImportError(
                "snowflake key-pair auth requires `cryptography` — run:\n"
                "  /tmp/forge-venv/bin/pip install cryptography"
            )
        with open(conn_cfg["private_key_path"], "rb") as kf:
            pkey = serialization.load_pem_private_key(
                kf.read(),
                password=conn_cfg.get("private_key_password", "").encode() or None,
                backend=default_backend(),
            )
        kwargs["private_key"] = pkey.private_bytes(
            encoding=serialization.Encoding.DER,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )

    conn = snowflake.connector.connect(**kwargs)
    try:
        cur = conn.cursor(snowflake.connector.DictCursor)
        query = extraction.get("query")
        if not query:
            raise ValueError(f"snowflake: extraction {extraction.get('id')} missing query")
        cur.execute(query)
        while True:
            rows = cur.fetchmany(batch_size)
            if not rows:
                break
            for row in rows:
                yield dict(row)
    finally:
        conn.close()
