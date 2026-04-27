---
name: forge-ingest-db
description: Database ingestion — extracts rows from SQL/NoSQL databases into the canonical JSONL chunk format for forge-audit/synth/shape. Supports 10 adapters (sqlite/postgres v2.1, mysql/mongodb v2.2, duckdb/mssql/clickhouse/snowflake/bigquery/cassandra v2.3). Configuration is a YAML file describing connections, queries, and row-to-chunk templates. Credentials resolve from env vars / file paths / HashiCorp Vault refs (TTL-cached), never hit disk or logs; lib/secrets.py provides Secret wrappers that hide values from stack traces.
---

# forge-ingest-db

## When this fires

Called directly by the operator OR from `forge-ingest` (v2.2 multi-source
fan-out). Takes a YAML config pointing at one or more database sources and
emits a single JSONL in the canonical chunk schema.

## Config format

```yaml
version: 1
sources:
  - name: pubmed-dental
    kind: postgres           # sqlite | postgres | mysql (v2.2) | mongodb (v2.2)
    conn:
      host_ref: "env:PG_HOST"
      port: 5432
      database: publications
      user_ref:     "env:PG_USER"
      password_ref: "env:PG_PASSWORD"
      sslmode: require
    extractions:
      - id: abstracts
        query: |
          SELECT pmid, title, authors, abstract, year
          FROM pubmed_articles
          WHERE abstract IS NOT NULL AND length(abstract) > 200
        id_template:   "pg-abstracts-{pmid}"
        text_template: "{title}\nAuthors: {authors} ({year})\n\n{abstract}"
        metadata:
          section: pubmed
        limit: 50000          # safety cap
        batch_size: 1000

  - name: local-notes
    kind: sqlite
    conn:
      path: /data/notes.db
    extractions:
      - id: notes
        query: "SELECT id, created_at, body FROM notes"
        text_template: "{body}"
        id_template: "sqlite-notes-{id}"
```

## Credential resolution

Fields ending in `_ref` use the prefix-based resolver:

| Ref syntax | Resolves to |
|---|---|
| `env:VAR_NAME` | `os.environ["VAR_NAME"]` |
| `file:/path/to/secret` | contents of the file (stripped) |
| `vault:path#key` | HashiCorp Vault (v2.2+) |

Secrets are resolved at connection time, never written to state.json,
manifest, prepped.jsonl, or log files. A scrubber runs on config echo.

## Output

One JSONL record per row that matches the canonical schema. Each extraction
contributes chunks with:
- `metadata.source_file = "<source-name>:<extraction-id>"`
- `metadata.source_format = "postgres" | "sqlite" | ...`
- `metadata.chunk_type = "db-row"`

Output path: `slm-forge/.runs/<run-id>/ingested-db.jsonl`

## Usage

```bash
# Via config file
bash slm-forge/skills/forge-ingest-db/run.sh <run-id> <path/to/db-sources.yaml>

# Or pointing at a config in the run dir
bash slm-forge/skills/forge-ingest-db/run.sh <run-id>
  # reads from slm-forge/.runs/<run-id>/db-sources.yaml
```

## Adapters

| Kind | Adapter | Driver | Auth | Added |
|---|---|---|---|---|
| `sqlite`     | `sqlite_adapter.py`     | stdlib `sqlite3`            | file path; read-only by default                   | v2.1 |
| `postgres`   | `postgres_adapter.py`   | `psycopg2-binary`           | password / sslmode                                | v2.1 |
| `mysql`      | `mysql_adapter.py`      | `pymysql`                   | password / SSL CA                                 | v2.2 |
| `mongodb`    | `mongo_adapter.py`      | `pymongo`                   | URI-embedded creds                                | v2.2 |
| `duckdb`     | `duckdb_adapter.py`     | `duckdb`                    | file path; supports parquet/csv/json view ATTACH  | v2.3 |
| `mssql`      | `mssql_adapter.py`      | `pymssql` (FreeTDS)         | password; optional charset / tds_version          | v2.3 |
| `clickhouse` | `clickhouse_adapter.py` | `clickhouse-connect` (HTTP) | password; TLS via secure/verify                   | v2.3 |
| `snowflake`  | `snowflake_adapter.py`  | `snowflake-connector-python`| password OR PEM key-pair (preferred)              | v2.3 |
| `bigquery`   | `bigquery_adapter.py`   | `google-cloud-bigquery`     | service-account JSON (path or vault ref)          | v2.3 |
| `cassandra`  | `cassandra_adapter.py`  | `cassandra-driver`          | PlainText auth + optional TLS CA                  | v2.3 |

Adding an adapter requires one entry in `ingest._ADAPTER_MODULES` plus a
new `<kind>_adapter.py` exporting `iter_rows(conn_cfg, extraction, batch_size)`.
Drivers are lazy-imported with a clear `pip install` error on miss.

## Failure modes

| Failure | Recovery |
|---|---|
| Credential ref can't resolve | Abort early; prints which ref + fix hint |
| Driver not installed | Clear error: `pip install psycopg2-binary` |
| Query syntax error | Aborts that extraction, continues to next; logs error |
| Connection timeout | Aborts that source, continues; logs |
| Row template has undefined field | Row skipped with warning |
