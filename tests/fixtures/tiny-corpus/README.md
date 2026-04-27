# tiny-corpus — synthetic test fixture

A small synthetic corpus used by `tests/smoke-test.sh` for end-to-end pipeline
validation without real corpus spend or sensitive data exposure.

- ~100 lines of plain text
- Domain: synthetic patient education (dental, generic, harmless)
- Format: one document per line in `docs.jsonl`, plus a raw `docs.txt`
- License: CC0 / public-domain

This fixture is enough to:
- Smoke-test `forge-source` (S3 sync + format detection)
- Smoke-test `forge-curate` (filter pass-through)
- Smoke-test `forge-shape` (tokenize + split)
- Smoke-test `forge-train` (10M-param model trains in ~5 min on g5.xlarge)

Files:
- `docs.jsonl` — one document per line, `{id, text}` schema
- `docs.txt`   — same content as plain text
