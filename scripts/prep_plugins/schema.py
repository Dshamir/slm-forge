"""
Canonical chunk schema + validator.

Every plugin + forge-ingest-db adapter MUST emit records that pass
validate_chunk(). The orchestrator + ingest.py run it just before writing
to catch off-spec chunks before they pollute the downstream pipeline.

Using a hand-rolled validator instead of jsonschema to avoid the extra
dependency — the schema is small and well-known.
"""
from __future__ import annotations

from typing import Any


REQUIRED_TOP = ("id", "format")          # text OR messages required (format-dependent)
REQUIRED_META_PRETRAIN = ("source_file", "source_format", "chunk_type")
VALID_FORMATS = ("pretrain", "chat")


def validate_chunk(chunk: Any) -> tuple[bool, str]:
    """Return (ok, reason). reason is empty when ok is True.

    Two valid shapes:
      pretrain → {id, text, format:"pretrain", metadata:{...}}
      chat     → {id, messages:[{role,content}...], format:"chat", metadata?:{...}}

    For pretrain, we enforce the full v1 canonical metadata schema.
    For chat, we are more permissive — these are usually externally-sourced
    SFT datasets that already validated upstream (HF datasets, prior runs).
    """
    if not isinstance(chunk, dict):
        return False, f"not a dict: {type(chunk).__name__}"

    for k in REQUIRED_TOP:
        if k not in chunk:
            return False, f"missing top-level key: {k}"

    if not isinstance(chunk["id"], str) or not chunk["id"]:
        return False, "id must be non-empty string"

    fmt = chunk["format"]
    if fmt not in VALID_FORMATS:
        return False, f"format must be one of {VALID_FORMATS}, got {fmt!r}"

    if fmt == "chat":
        # Chat: needs messages array; metadata is optional and unconstrained
        msgs = chunk.get("messages")
        if not isinstance(msgs, list) or not msgs:
            return False, "chat format requires non-empty messages array"
        any_content = False
        for m in msgs:
            if not isinstance(m, dict):
                return False, "messages entries must be dicts"
            if "role" not in m or "content" not in m:
                return False, "each message needs role + content"
            content = m.get("content")
            # content may be a string (canonical) or a list (multimodal).
            # Either way it has to carry SOMETHING — empty assistant
            # messages survive at the message level but we need at least
            # one non-empty message in the chunk.
            if isinstance(content, str) and content.strip():
                any_content = True
            elif isinstance(content, list) and content:
                any_content = True
        if not any_content:
            return False, "chat chunk has no non-empty message content"
        return True, ""

    # pretrain — enforce v1 canonical schema
    if "text" not in chunk:
        return False, "pretrain format requires text field"
    if not isinstance(chunk["text"], str):
        return False, "text must be string"
    if not chunk["text"].strip():
        return False, "text must be non-empty (whitespace-only rejected)"

    meta = chunk.get("metadata")
    if not isinstance(meta, dict):
        return False, "metadata must be dict"

    for k in REQUIRED_META_PRETRAIN:
        if k not in meta:
            return False, f"metadata missing key: {k}"

    # char_count required and must match len(text). Asymmetric "optional
    # when missing, strict when present" was making the field unreliable
    # for downstream token estimation.
    if "char_count" not in meta:
        return False, "metadata.char_count required"
    if not isinstance(meta["char_count"], int):
        return False, "metadata.char_count must be int"
    if meta["char_count"] != len(chunk["text"]):
        return False, (
            f"metadata.char_count ({meta['char_count']}) != "
            f"len(text) ({len(chunk['text'])})"
        )

    if "chunk_idx" in meta and not isinstance(meta["chunk_idx"], int):
        return False, "metadata.chunk_idx must be int"

    return True, ""
