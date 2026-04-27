"""
Email plugin — .eml (single message) and .mbox (mbox archive).

Both are stdlib-only (email + mailbox modules); no extra deps. Each
message is one chunk. Headers (From/To/Subject/Date) are concatenated
with the body. Multi-part MIME is walked: text/plain wins, text/html
falls back via simple tag-stripping if no plaintext exists.

Common in operator corpora: archived mail dumps, support-ticket exports,
mailing-list archives.
"""
from __future__ import annotations

import email
import email.policy
import mailbox
import re
from html import unescape
from pathlib import Path
from typing import Iterator

from .orchestration_helpers import MIN_LEN, clean_text


_TAG_RE = re.compile(r"<[^>]+>")


def _html_to_text(html: str) -> str:
    text = _TAG_RE.sub(" ", html)
    text = unescape(text)
    return clean_text(text)


def _msg_body(msg) -> str:
    """Walk a Message; prefer text/plain, fall back to stripped text/html."""
    plain_parts: list[str] = []
    html_parts: list[str] = []
    if msg.is_multipart():
        for part in msg.walk():
            ctype = part.get_content_type()
            if ctype == "text/plain":
                try:
                    plain_parts.append(part.get_content())
                except (KeyError, LookupError):
                    payload = part.get_payload(decode=True)
                    if payload:
                        plain_parts.append(payload.decode("utf-8", errors="replace"))
            elif ctype == "text/html":
                try:
                    html_parts.append(part.get_content())
                except (KeyError, LookupError):
                    payload = part.get_payload(decode=True)
                    if payload:
                        html_parts.append(payload.decode("utf-8", errors="replace"))
    else:
        ctype = msg.get_content_type()
        try:
            body = msg.get_content() if hasattr(msg, "get_content") else msg.get_payload(decode=True)
            if isinstance(body, bytes):
                body = body.decode("utf-8", errors="replace")
            if ctype == "text/html":
                html_parts.append(body)
            else:
                plain_parts.append(body)
        except (KeyError, LookupError, AttributeError):
            pass
    if plain_parts:
        return clean_text("\n\n".join(p for p in plain_parts if p))
    if html_parts:
        return _html_to_text("\n\n".join(p for p in html_parts if p))
    return ""


def _format_chunk(msg, base_id: str, chunk_idx: int, source_file: str,
                  section: str, doc_title: str, source_format: str) -> dict | None:
    headers = []
    for h in ("From", "To", "Cc", "Subject", "Date"):
        v = msg.get(h)
        if v:
            headers.append(f"{h}: {v}")
    body = _msg_body(msg)
    text = "\n".join(headers) + ("\n\n" + body if body else "")
    text = text.strip()
    if len(text) < MIN_LEN:
        return None
    return {
        "id": f"{base_id}-{chunk_idx:05d}",
        "text": text,
        "format": "pretrain",
        "metadata": {
            "source_file": source_file,
            "source_format": source_format,
            "section": section,
            "doc_title": doc_title,
            "chunk_type": "email",
            "chunk_idx": chunk_idx,
            "char_count": len(text),
            "subject": msg.get("Subject", ""),
        },
    }


class _EmailPlugin:
    extensions = (".eml", ".mbox", ".mbx")
    source_format = "email"
    requires = ()
    system_deps = ()
    default_on = True
    disable_env = "FORGE_DISABLE_EMAIL"

    def iter_chunks(self, path: Path, section: str, base_id: str, options: dict) -> Iterator[dict]:
        ext = path.suffix.lower()
        if ext == ".eml":
            try:
                with open(path, "rb") as f:
                    msg = email.message_from_binary_file(f, policy=email.policy.default)
            except Exception:
                return
            chunk = _format_chunk(
                msg, base_id, 0, str(path), section, path.stem, "eml",
            )
            if chunk:
                yield chunk
            return

        # .mbox / .mbx
        try:
            mbx = mailbox.mbox(str(path))
        except Exception:
            return
        for i, msg in enumerate(mbx):
            chunk = _format_chunk(
                msg, base_id, i, str(path), section, path.stem, "mbox",
            )
            if chunk:
                yield chunk


PLUGIN = _EmailPlugin()
