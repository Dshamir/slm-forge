# COLLABORATORS

## Maintainer

**Daniel Shamir** — [@Dshamir](https://github.com/Dshamir) — Nexless
- Lead architect, primary author of the skill tree
- HuggingFace: [@Nexless](https://huggingface.co/Nexless)
- Contact: open an issue on GitHub

## Orchestration

This codebase was authored interactively in the **Claude Code TUI**, which is the orchestration substrate the project exists to demonstrate. The skill-tree pattern, manifest contract, plan-fit gate doctrine, and post-mortem corpus are all artifacts of multi-session collaboration between the maintainer and Anthropic's Claude models (Opus 4.6 / 4.7 + Haiku 4.5 + Sonnet 4.6).

**The Claude Code TUI is not a contributor in the legal/copyright sense** — Daniel Shamir holds copyright on the assembled toolkit. But the *style* of the codebase (single-responsibility skills, append-only event ledgers, explicit gate semantics, abstention contracts as first-class primitives) reflects design choices that emerge naturally when working with semi-autonomous skills. If you fork this repo and continue developing it in Claude Code yourself, you're participating in the same pattern.

## Case-study collaborators

The dental research SLM v0 case study at [`Nexless/dental-ai-research-slm-0m-20260425-3845`](https://huggingface.co/Nexless/dental-ai-research-slm-0m-20260425-3845) was trained on a corpus contributed by the **Polytechnique Montréal IntelliDent group**. The corpus content remains private; only the trained LoRA adapter + GGUF artifacts are publicly available on HuggingFace. The IntelliDent group's published papers (MeshSegNet, iMeshSegNet, MC-Net, margin-line detection methods, crown-generation pipelines) are the conceptual content the model was specialized on.

## How to contribute

Pull requests welcome. Before opening:

1. **Read the post-mortems** in `docs/POST-MORTEM-*.md` — most "obvious" improvements turn out to be obvious for a reason: they were tried and the trade-off rejected.
2. **Run the smoke tests** in `tests/` — `bash tests/smoke-test.sh` covers the M1 init path, `bash tests/v2-smoke.sh` covers the dispatcher.
3. **Keep skills single-responsibility**. The pattern is one skill per phase + one shared manifest. Resist the urge to merge skills "because they're related."
4. **No secrets in commits.** The repo includes a sanitization pass (see the README). New code should use the same `<YOUR_*>` placeholder convention.
5. **Document failure modes**, not just success paths. Every skill should describe what happens on each rc value (rc=12 = replan-needed, rc=64 = caller error, rc=1 = unrecoverable, etc.).

### Areas where contributions are most welcome

- **Additional file plugins.** v2.3 has 19 (PDF/DOCX/PPTX/TXT/XLSX/CSV/PNG/JPG/TIF/HEIC/MP4/m4a/wav/STL/VTP/OBJ/PLY/MyISAM/EPUB/code/notebooks/email/DICOM/HDF5/ZIP/RAR). Want to add Parquet, MATLAB `.mat`, ROS bag files, etc.? See `scripts/prep_plugins/__init__.py` for the dispatcher contract.
- **Additional DB adapters.** Currently 10 (MySQL/Postgres/Mongo/SQLite/DuckDB/MSSQL/ClickHouse/Snowflake/BigQuery/Cassandra). See `skills/forge-ingest-db/adapters/` for the adapter contract.
- **Cloud provider implementations.** AWS is the only provider today. The dispatcher in `lib/compute.sh` is provider-agnostic; a `lib/compute_gcp.sh` or `lib/compute_modal.sh` would slot in cleanly.
- **Synth template additions.** The current 3 templates (factual/mechanism/clinical) limit the diversity of Q/A shape. v2 plans to expand to ~10. See `skills/forge-synth/SKILL.md`.
- **Smaller-base recipes.** All examples target 7B QLoRA. Recipes for 0.5B / 1.5B from-scratch or LoRA-on-base configurations would broaden the toolkit's reach.

## Contact / Credits

For collaboration on case studies (specialty corpora, evaluation methods, deployment patterns), open an issue describing what you'd like to explore. The toolkit is a moving target — the maintainer is actively developing v2 in a parallel private branch. Public releases land here when they're stable.
