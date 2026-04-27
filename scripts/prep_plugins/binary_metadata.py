"""
Binary metadata plugin — raw binaries + compiled artifacts.

For .bin .dll .so .dylib .exe .o .a .class — files with no text interpretation
but that we still want tracked. Emits one sparse metadata chunk per file
with filename + size + detected magic bytes.

MYSQL binary storage files (.myi .myd .frm .ibd) get chunked here too, but
v2.2 adds a specialized auto-revive plugin that can bring up a temporary
MySQL instance + dump tables properly. For v2.1 they fall through here.
"""
from __future__ import annotations

from pathlib import Path
from typing import Iterator


# Magic-byte patterns for quick file-type detection
_MAGIC_PATTERNS = [
    (b"\x7fELF",       "ELF executable/object"),
    (b"MZ",            "PE/Windows executable"),
    (b"\xca\xfe\xba\xbe", "Java class file"),
    (b"\xfe\xed\xfa\xce", "Mach-O (32-bit)"),
    (b"\xfe\xed\xfa\xcf", "Mach-O (64-bit)"),
    (b"PK\x03\x04",    "ZIP archive (unexpected binary)"),
    (b"\xfe\x01\x01",  "MySQL MyISAM index (.MYI)"),
    (b"\xfe\xfe\x07",  "MySQL MyISAM data (.MYD)"),
    (b"\xfe\xfe\xfe",  "MySQL FRM (structure)"),
]


def _detect_magic(path: Path) -> str:
    try:
        with open(path, "rb") as f:
            head = f.read(8)
        for pattern, label in _MAGIC_PATTERNS:
            if head.startswith(pattern):
                return label
        return "unknown-binary"
    except Exception:
        return "read-error"


class _BinaryMetadataPlugin:
    extensions = (
        # Generic binary
        ".bin", ".dat",
        # Native code
        ".so", ".dylib", ".dll", ".exe", ".o", ".a", ".lib",
        # JVM
        ".class", ".jar",  # .jar has structure but we treat it as provenance-only here
        # MySQL internal storage (v2.2 replaces with auto-revive)
        ".myi", ".myd", ".frm", ".ibd", ".ibdata",
        # Databases (file-based, but reading them needs SQLite/etc — deferred to forge-ingest-db)
        ".db",  # SQLite files SHOULD use forge-ingest-db; sparse metadata for now
    )
    source_format = "binary_metadata"
    requires = ()
    system_deps = ()
    default_on = True
    disable_env = "FORGE_DISABLE_BINARY_METADATA"

    def iter_chunks(self, path: Path, section: str, base_id: str, options: dict) -> Iterator[dict]:
        try:
            size = path.stat().st_size
        except Exception:
            size = 0
        size_kb = max(1, size // 1024)
        magic = _detect_magic(path)
        ext = path.suffix.lower()

        text = (
            f"Binary file: {path.name} "
            f"({ext.lstrip('.') or 'noext'}, {size_kb} KB, detected: {magic}). "
            f"No extractable text content."
        )

        # Helpful hint for MySQL files
        if ext in (".myi", ".myd", ".frm", ".ibd", ".ibdata"):
            text += (
                " This is a MySQL internal storage file. To ingest it, "
                "run a local mysqld against the data directory and use "
                "forge-ingest-db with a connection string."
            )
        elif ext == ".db":
            text += (
                " Looks like a SQLite database. Use forge-ingest-db "
                "with kind=sqlite to extract table contents."
            )

        yield {
            "id": f"{base_id}-binmeta",
            "text": text,
            "format": "pretrain",
            "metadata": {
                "source_file": str(path),
                "source_format": ext.lstrip(".") or "binary",
                "section": section,
                "doc_title": path.stem,
                "chunk_type": "metadata_only",
                "chunk_idx": 0,
                "char_count": len(text),
                "file_size_kb": size_kb,
                "magic": magic,
            },
        }


PLUGIN = _BinaryMetadataPlugin()
