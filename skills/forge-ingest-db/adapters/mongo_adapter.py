"""
MongoDB adapter — pymongo driver.

conn config (after credential resolution):
  uri:         mongodb://user:pass@host:27017/db?options    (or use uri_ref)
  database:    publications                                   (required if not in uri)
  connect_timeout_sec: 30

extraction config (uses MongoDB-specific fields, not query SQL):
  collection:  pubmed                       (required)
  filter:      { status: "published" }      (default: {})
  projection:  { _id: 1, title: 1, abstract: 1 }   (default: full document)
  sort:        [ ["created_at", -1] ]       (default: natural order)
  id_field:    _id                          (which field to use for id; default _id)

  # text_template etc. work as usual — you can {field} reference any
  # projected field. _id is always available as a string.
"""
from __future__ import annotations

import sys
from typing import Iterator


def iter_rows(conn_cfg: dict, extraction: dict, batch_size: int = 1000) -> Iterator[dict]:
    try:
        import pymongo
    except ImportError:
        raise ImportError(
            "mongo adapter requires pymongo — run:\n"
            "  /tmp/forge-venv/bin/pip install pymongo"
        )

    if "uri" not in conn_cfg:
        raise ValueError("mongodb: conn.uri (or uri_ref) is required")
    timeout_ms = int(conn_cfg.get("connect_timeout_sec", 30)) * 1000

    client = pymongo.MongoClient(
        conn_cfg["uri"],
        serverSelectionTimeoutMS=timeout_ms,
    )
    try:
        # Database name: either from extraction.database, conn.database, or uri default
        db_name = conn_cfg.get("database") or extraction.get("database")
        if not db_name:
            db_name = client.get_default_database().name if client.get_default_database() else None
        if not db_name:
            raise ValueError("mongodb: no database — set conn.database or include in uri")

        coll_name = extraction.get("collection")
        if not coll_name:
            raise ValueError(f"mongodb: extraction {extraction.get('id')} missing collection")

        coll = client[db_name][coll_name]
        filt = extraction.get("filter") or {}
        proj = extraction.get("projection")
        sort = extraction.get("sort")

        cursor = coll.find(filt, proj if proj else None)
        if sort:
            cursor = cursor.sort([(field, dir) for field, dir in sort])
        cursor = cursor.batch_size(batch_size)

        for doc in cursor:
            # Coerce ObjectId → str for templating
            if "_id" in doc:
                doc["_id"] = str(doc["_id"])
            yield doc
    finally:
        client.close()
