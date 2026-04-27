"""
Archive plugin — zip, tar, tar.gz, 7z, rar.

Extracts the archive into a temp dir, then recurses into the orchestrator's
walk() against that temp dir. Each resulting chunk's metadata.source_file
gets prefixed with "<archive>:" so provenance survives.

Depth cap (default 3) prevents zip-bomb / self-referencing-archive issues.
"""
from __future__ import annotations

import shutil
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path
from typing import Iterator

from .orchestration_helpers import norm_id


MAX_DEPTH = 3  # total recursion depth for nested archives


def _is_safe_member(member_name: str, dest: Path) -> bool:
    """Reject zip-slip / tarbomb members.

    A member is safe iff its resolved destination stays inside `dest`.
    Drops absolute paths, drive letters, and any path that escapes via "..".
    Also rejects paths containing NUL bytes (filesystem injection).
    """
    if not member_name or "\x00" in member_name:
        return False
    # Normalize: zip/tar use forward-slashes; on Windows backslash also dangerous
    name = member_name.replace("\\", "/").lstrip("/")
    if not name:
        return False
    target = (dest / name).resolve()
    try:
        target.relative_to(dest.resolve())
    except ValueError:
        return False
    return True


def _extract_zip(path: Path, dest: Path) -> bool:
    try:
        with zipfile.ZipFile(path) as zf:
            members = zf.infolist()
            safe = [m for m in members if _is_safe_member(m.filename, dest)]
            unsafe = len(members) - len(safe)
            if unsafe:
                sys.stderr.write(
                    f"  [zip {path.name}: dropped {unsafe} unsafe member(s) "
                    f"(zip-slip/absolute path)]\n"
                )
            zf.extractall(dest, members=safe)
        return True
    except Exception as e:
        sys.stderr.write(f"  [zip {path}: {type(e).__name__}]\n")
        return False


def _extract_tar(path: Path, dest: Path) -> bool:
    try:
        with tarfile.open(path) as tf:
            # data_filter (Python 3.12+) blocks zip-slip + symlinks-out + special
            # files. On older runtimes we filter manually before extractall.
            try:
                tf.extractall(dest, filter="data")
            except TypeError:
                members = tf.getmembers()
                safe = [m for m in members if _is_safe_member(m.name, dest)
                        and not m.issym() and not m.islnk()]
                unsafe = len(members) - len(safe)
                if unsafe:
                    sys.stderr.write(
                        f"  [tar {path.name}: dropped {unsafe} unsafe member(s)]\n"
                    )
                tf.extractall(dest, members=safe)
        return True
    except Exception as e:
        sys.stderr.write(f"  [tar {path}: {type(e).__name__}]\n")
        return False


def _extract_7z(path: Path, dest: Path) -> bool:
    try:
        import py7zr
    except ImportError:
        sys.stderr.write(f"  [py7zr not installed; skip {path}]\n")
        return False
    try:
        with py7zr.SevenZipFile(path) as sz:
            # py7zr has no per-member extract API as ergonomic as zip/tar.
            # Read names first, build a targets list of safe ones, then
            # extractall(targets=...) to skip unsafe entries.
            all_names = sz.getnames()
            safe = [n for n in all_names if _is_safe_member(n, dest)]
            unsafe = len(all_names) - len(safe)
            if unsafe:
                sys.stderr.write(
                    f"  [7z {path.name}: dropped {unsafe} unsafe member(s)]\n"
                )
            # Re-open: py7zr consumes the file pointer on getnames in some versions
        with py7zr.SevenZipFile(path) as sz:
            sz.extractall(dest, targets=safe) if safe else None
        return True
    except Exception as e:
        sys.stderr.write(f"  [7z {path}: {type(e).__name__}]\n")
        return False


def _extract_rar(path: Path, dest: Path) -> bool:
    try:
        import rarfile
    except ImportError:
        sys.stderr.write(f"  [rarfile not installed; skip {path}]\n")
        return False
    try:
        with rarfile.RarFile(path) as rf:
            members = rf.infolist()
            safe = [m for m in members if _is_safe_member(m.filename, dest)]
            unsafe = len(members) - len(safe)
            if unsafe:
                sys.stderr.write(
                    f"  [rar {path.name}: dropped {unsafe} unsafe member(s)]\n"
                )
            rf.extractall(dest, members=safe)
        return True
    except Exception as e:
        sys.stderr.write(f"  [rar {path}: {type(e).__name__}]\n")
        return False


class _ArchivePlugin:
    extensions = (".zip", ".tar", ".gz", ".tgz", ".bz2", ".tbz2", ".7z", ".rar")
    source_format = "archive"
    requires = ("py7zr", "rarfile")
    system_deps = ("unrar",)  # rarfile wraps the unrar binary
    default_on = True
    disable_env = "FORGE_DISABLE_ARCHIVE"

    def iter_chunks(self, path: Path, section: str, base_id: str, options: dict) -> Iterator[dict]:
        depth = int(options.get("_archive_depth", 0))
        if depth >= MAX_DEPTH:
            sys.stderr.write(f"  [archive depth cap reached; skip {path}]\n")
            return

        # Handle compound .tar.* extensions
        name = path.name.lower()
        is_tar = any(name.endswith(s) for s in (".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2"))

        with tempfile.TemporaryDirectory(prefix="forge-archive-") as tmpdir:
            dest = Path(tmpdir)
            ok = False
            if path.suffix.lower() == ".zip":
                ok = _extract_zip(path, dest)
            elif path.suffix.lower() == ".7z":
                ok = _extract_7z(path, dest)
            elif path.suffix.lower() == ".rar":
                ok = _extract_rar(path, dest)
            elif is_tar:
                ok = _extract_tar(path, dest)
            else:
                # .gz or .bz2 alone (not tar) — leave alone for now
                return

            if not ok:
                return

            # Recurse: call orchestrator's walker. Avoid circular import by
            # importing at use-time.
            sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
            from prep_plugins import get_dispatcher
            dispatcher = get_dispatcher()
            prefix = f"{path.name}:"

            for p in sorted(dest.rglob("*")):
                if not p.is_file():
                    continue
                ext = p.suffix.lower()
                plugin = dispatcher.get(ext)
                if plugin is None:
                    continue
                # Compute section: use archive name for provenance
                inner_section = f"{section}/{path.stem}" if section else path.stem
                inner_base = norm_id(p.stem)
                inner_options = dict(options, _archive_depth=depth + 1)
                for chunk in plugin.iter_chunks(p, inner_section, inner_base, inner_options):
                    # Prefix source_file for provenance
                    chunk["metadata"]["source_file"] = f"{prefix}{chunk['metadata']['source_file']}"
                    chunk["id"] = f"{norm_id(path.stem)}-{chunk['id']}"
                    yield chunk


PLUGIN = _ArchivePlugin()
