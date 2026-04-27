"""
Cassandra adapter — cassandra-driver (DataStax).

conn config:
  contact_points:  ["cass-1.example.com", "cass-2.example.com"]   # required
  port:            9042
  keyspace:        dental
  user:            forge_reader
  password:        <resolved-from-ref>
  ssl_ca_path:     /path/to/ca.pem        # optional, enables TLS
  consistency:     LOCAL_ONE              # default LOCAL_ONE
  connect_timeout_sec: 30
"""
from __future__ import annotations

from typing import Iterator


def iter_rows(conn_cfg: dict, extraction: dict, batch_size: int = 1000) -> Iterator[dict]:
    try:
        from cassandra.cluster import Cluster   # type: ignore
        from cassandra.auth import PlainTextAuthProvider  # type: ignore
        from cassandra import ConsistencyLevel  # type: ignore
    except ImportError:
        raise ImportError(
            "cassandra adapter requires cassandra-driver — run:\n"
            "  /tmp/forge-venv/bin/pip install cassandra-driver"
        )

    cps = conn_cfg.get("contact_points")
    if not cps:
        raise ValueError("cassandra: conn.contact_points required (list of hosts)")
    if isinstance(cps, str):
        cps = [cps]

    auth = None
    if "user" in conn_cfg and "password" in conn_cfg:
        auth = PlainTextAuthProvider(
            username=conn_cfg["user"], password=conn_cfg["password"]
        )

    ssl_options = None
    if "ssl_ca_path" in conn_cfg:
        import ssl
        ssl_options = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ssl_options.load_verify_locations(conn_cfg["ssl_ca_path"])

    cluster = Cluster(
        contact_points=cps,
        port=int(conn_cfg.get("port", 9042)),
        auth_provider=auth,
        ssl_context=ssl_options,
        connect_timeout=int(conn_cfg.get("connect_timeout_sec", 30)),
    )
    session = cluster.connect(conn_cfg.get("keyspace"))
    try:
        consistency = getattr(
            ConsistencyLevel, conn_cfg.get("consistency", "LOCAL_ONE"), None
        )
        query = extraction.get("query")
        if not query:
            raise ValueError(f"cassandra: extraction {extraction.get('id')} missing query")

        from cassandra.query import SimpleStatement  # type: ignore
        stmt = SimpleStatement(query, fetch_size=batch_size,
                               consistency_level=consistency)
        for row in session.execute(stmt):
            # Driver returns named-tuples; convert to dict
            yield {f: getattr(row, f) for f in row._fields}
    finally:
        cluster.shutdown()
