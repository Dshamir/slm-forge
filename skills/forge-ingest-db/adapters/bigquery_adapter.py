"""
BigQuery adapter — google-cloud-bigquery.

conn config:
  project:                my-gcp-project          # required
  location:               US                      # optional
  credentials_json_path:  /path/to/sa.json        # service account key
  credentials_json_ref:   "vault:gcp/forge#sa_json"  # OR ref → JSON string
  use_query_cache:        true
"""
from __future__ import annotations

import json
import tempfile
from typing import Iterator


def iter_rows(conn_cfg: dict, extraction: dict, batch_size: int = 1000) -> Iterator[dict]:
    try:
        from google.cloud import bigquery  # type: ignore
        from google.oauth2 import service_account  # type: ignore
    except ImportError:
        raise ImportError(
            "bigquery adapter requires google-cloud-bigquery — run:\n"
            "  /tmp/forge-venv/bin/pip install google-cloud-bigquery"
        )

    if "project" not in conn_cfg:
        raise ValueError("bigquery: conn.project is required")

    creds = None
    if "credentials_json_path" in conn_cfg:
        creds = service_account.Credentials.from_service_account_file(
            conn_cfg["credentials_json_path"]
        )
    elif "credentials_json" in conn_cfg:
        # The secrets resolver already turned credentials_json_ref into the
        # JSON string. Parse it inline.
        info = json.loads(conn_cfg["credentials_json"])
        creds = service_account.Credentials.from_service_account_info(info)

    client_kwargs = {"project": conn_cfg["project"]}
    if creds is not None:
        client_kwargs["credentials"] = creds
    if "location" in conn_cfg:
        client_kwargs["location"] = conn_cfg["location"]

    client = bigquery.Client(**client_kwargs)
    try:
        query = extraction.get("query")
        if not query:
            raise ValueError(f"bigquery: extraction {extraction.get('id')} missing query")
        job_config = bigquery.QueryJobConfig(
            use_query_cache=bool(conn_cfg.get("use_query_cache", True)),
        )
        result = client.query(query, job_config=job_config).result(page_size=batch_size)
        for row in result:
            yield dict(row)
    finally:
        client.close()
