"""
MySQL auto-revive plugin (v2.2).

Many real corpora include orphaned MySQL data dirs — collections of
.myi / .myd / .frm / .ibd / .ibdata files that mysqld would happily
read, but which the rest of the world treats as opaque binaries.

This plugin detects those files, identifies the parent data directory,
spins up a throwaway `docker run -d --rm mysql:8` against it,
mysqldumps all user databases, parses the dump, and emits one chunk
per row using the same row-template idea as forge-ingest-db.

Caches per-cluster chunks at module scope so the orchestrator can call
iter_chunks() once per file in the cluster without reviving N times —
the first file pays the bring-up cost, every sibling reads from cache.

Falls back gracefully if:
  - docker isn't installed → sparse metadata chunk per file
  - container fails to start / mysqldump errors → metadata chunk
  - FORGE_DISABLE_MYSQL_REVIVE=1 → plugin skipped entirely

Permissions: data dir is rsynced into a temp dir we own and chmodded
0777 before mounting. Avoids the host-uid / mysql-user (uid 999)
mismatch that otherwise turns this into a debugging swamp.
"""
from __future__ import annotations

import atexit
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Iterator


# Registry of containers we've spawned but not yet torn down. Cleaned up
# at process exit (atexit) AND on SIGTERM/SIGINT so a Ctrl+C mid-dump or
# OOM-kill doesn't leave zombie mysqld containers running.
_LIVE_CONTAINERS: set[str] = set()


def _cleanup_containers(*_args):
    for cname in list(_LIVE_CONTAINERS):
        try:
            subprocess.run(
                ["docker", "stop", "-t", "5", cname],
                capture_output=True, timeout=20,
            )
        except Exception:
            pass
        _LIVE_CONTAINERS.discard(cname)


atexit.register(_cleanup_containers)
# Don't override the user's signal handlers if they already installed one
# (e.g. dispatch-v2's trap). Just chain.
for _sig in (signal.SIGTERM, signal.SIGINT):
    _prior = signal.getsignal(_sig)
    def _make_handler(prior_handler):
        def _h(signum, frame):
            _cleanup_containers()
            if callable(prior_handler) and prior_handler not in (
                signal.SIG_DFL, signal.SIG_IGN
            ):
                prior_handler(signum, frame)
            else:
                # Re-raise default behavior
                signal.signal(signum, signal.SIG_DFL)
                os.kill(os.getpid(), signum)
        return _h
    try:
        signal.signal(_sig, _make_handler(_prior))
    except (ValueError, OSError):
        pass  # not in main thread (rare in plugin context)


# Per-process cache: data_dir(str) → list[chunk]
# All cluster chunks attribute to the first .frm/.myi we saw, so subsequent
# files in the same cluster yield nothing (already in prepped.jsonl via cache key).
_CLUSTER_CACHE: dict[str, list[dict]] = {}
_CLUSTER_OWNER: dict[str, str] = {}        # data_dir → first file path that owned it
_PROBED_DOCKER: dict[str, bool] = {}        # cache the docker availability probe

_MYSQL_EXTS = (".frm", ".myi", ".myd", ".ibd", ".ibdata")
_INTERNAL_DBS = frozenset({"mysql", "performance_schema", "information_schema", "sys"})


def _have_docker() -> bool:
    if "result" in _PROBED_DOCKER:
        return _PROBED_DOCKER["result"]
    try:
        rc = subprocess.run(
            ["docker", "version", "--format", "{{.Server.Version}}"],
            capture_output=True, timeout=5,
        ).returncode
        ok = rc == 0
    except Exception:
        ok = False
    _PROBED_DOCKER["result"] = ok
    return ok


def _find_data_dir(path: Path) -> Path | None:
    """Walk upward from `path` looking for a directory whose children
    look like databases (each child dir contains at least one .frm or .ibd).

    The canonical layout is /var/lib/mysql/<db>/<table>.{frm,ibd,myi,myd}.
    `path` is one of those table files, so its parent is <db>, grandparent
    is the data dir. We verify by inspecting the grandparent: if it has
    one or more subdirs that themselves contain MySQL files, it's the
    data dir. Otherwise we walk up one more level (handles nested cases).
    """
    p = path.resolve()
    # Try parent.parent first (the typical case)
    candidate = p.parent.parent
    for _ in range(3):  # bounded walk
        try:
            if not candidate.is_dir():
                candidate = candidate.parent
                continue
        except (PermissionError, OSError):
            return None
        children = [c for c in candidate.iterdir() if c.is_dir()]
        if any(
            any(f.suffix.lower() in _MYSQL_EXTS for f in c.iterdir())
            for c in children
        ):
            return candidate
        candidate = candidate.parent
        if candidate == candidate.parent:  # reached /
            return None
    return None


def _wait_for_port(host: str, port: int, timeout: int = 90) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=2):
                return True
        except OSError:
            time.sleep(1)
    return False


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _container_ready(name: str, timeout: int = 90) -> bool:
    """Poll mysqladmin ping inside the container."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = subprocess.run(
                ["docker", "exec", name, "mysqladmin", "ping", "-uroot",
                 "--silent"],
                capture_output=True, timeout=8,
            )
            if r.returncode == 0:
                return True
        except Exception:
            pass
        time.sleep(2)
    return False


def _revive_and_dump(data_dir: Path) -> str | None:
    """Bring up a throwaway mysql:8 against `data_dir`, dump all user DBs,
    return the SQL text. None on any failure."""
    name = f"forge-mysql-{uuid.uuid4().hex[:8]}"
    port = _free_port()

    # Copy the data dir to a writable tmpdir so mysqld can lock files
    # and we don't risk corrupting the operator's source data.
    # Skip sockets / dangling symlinks left over from prior server runs —
    # shutil.copytree dies on those.
    def _skip_unsafe(src, names):
        skipped = []
        for n in names:
            full = os.path.join(src, n)
            try:
                st = os.lstat(full)
            except OSError:
                skipped.append(n); continue
            if not (os.path.isfile(full) or os.path.isdir(full)):
                skipped.append(n)  # socket / device / fifo / dangling link
        return skipped

    tmp_root = Path(tempfile.mkdtemp(prefix="forge-mysql-revive-"))
    work_dir = tmp_root / "data"
    try:
        shutil.copytree(data_dir, work_dir, ignore=_skip_unsafe)
        os.chmod(tmp_root, 0o777)
        for root, dirs, files in os.walk(work_dir):
            os.chmod(root, 0o777)
            for f in files:
                try:
                    os.chmod(os.path.join(root, f), 0o666)
                except OSError:
                    pass
    except Exception as e:
        sys.stderr.write(f"[mysql_revive] copy failed: {e}\n")
        shutil.rmtree(tmp_root, ignore_errors=True)
        return None

    # Start container.
    # Bind ONLY to loopback so the throwaway DB never accepts off-host
    # connections during the revive window. Without 127.0.0.1: prefix,
    # docker would expose port 3306 on every interface for the LAN.
    run_cmd = [
        "docker", "run", "-d", "--rm", "--name", name,
        "-p", f"127.0.0.1:{port}:3306",
        "-v", f"{work_dir}:/var/lib/mysql",
        "-e", "MYSQL_ALLOW_EMPTY_PASSWORD=1",
        "mysql:8.0",
    ]
    try:
        r = subprocess.run(run_cmd, capture_output=True, timeout=60)
        if r.returncode != 0:
            sys.stderr.write(
                f"[mysql_revive] docker run failed: "
                f"{r.stderr.decode('utf-8', errors='replace')[:200]}\n"
            )
            shutil.rmtree(tmp_root, ignore_errors=True)
            return None
        _LIVE_CONTAINERS.add(name)
    except Exception as e:
        sys.stderr.write(f"[mysql_revive] docker run error: {e}\n")
        shutil.rmtree(tmp_root, ignore_errors=True)
        return None

    sql = None
    try:
        if not _container_ready(name, timeout=120):
            sys.stderr.write("[mysql_revive] container never became ready\n")
        else:
            dump = subprocess.run(
                ["docker", "exec", name, "mysqldump",
                 "-uroot",
                 "--all-databases",
                 "--no-tablespaces",
                 "--skip-extended-insert",
                 "--compact",
                 "--skip-comments",
                 "--single-transaction",
                 "--quick"],
                capture_output=True, timeout=600,
            )
            if dump.returncode == 0:
                sql = dump.stdout.decode("utf-8", errors="replace")
            else:
                sys.stderr.write(
                    f"[mysql_revive] mysqldump failed: "
                    f"{dump.stderr.decode('utf-8', errors='replace')[:200]}\n"
                )
    finally:
        # Best-effort container teardown (--rm cleans up on stop)
        subprocess.run(
            ["docker", "stop", "-t", "5", name],
            capture_output=True, timeout=30,
        )
        _LIVE_CONTAINERS.discard(name)
        shutil.rmtree(tmp_root, ignore_errors=True)
    return sql


# ---- SQL dump → chunks --------------------------------------------------

# Bare INSERT parser. With --skip-extended-insert each statement is
# `INSERT INTO `db`.`table` VALUES (v1,v2,...);` on a single line.
_INSERT_RE = re.compile(
    r"^INSERT\s+INTO\s+`?([\w$]+)`?\.`?([\w$]+)`?(?:\s*\([^)]*\))?\s+VALUES\s*\((.*)\);\s*$",
    re.IGNORECASE,
)
_USE_RE = re.compile(r"^USE\s+`?([\w$]+)`?\s*;", re.IGNORECASE)
# Looser INSERT — when no schema-qualified name (during a USE block)
_INSERT_BARE_RE = re.compile(
    r"^INSERT\s+INTO\s+`?([\w$]+)`?(?:\s*\([^)]*\))?\s+VALUES\s*\((.*)\);\s*$",
    re.IGNORECASE,
)


def _split_values(s: str) -> list[str]:
    """Split a MySQL VALUES tuple body into top-level items.
    Honors quoted strings, backslash escapes, and NULL literals."""
    out, buf, in_str, esc = [], [], False, False
    for ch in s:
        if esc:
            buf.append(ch); esc = False; continue
        if ch == "\\" and in_str:
            esc = True; buf.append(ch); continue
        if ch == "'":
            in_str = not in_str; buf.append(ch); continue
        if ch == "," and not in_str:
            out.append("".join(buf).strip()); buf = []; continue
        buf.append(ch)
    out.append("".join(buf).strip())
    return out


def _format_value(v: str) -> str:
    """Strip quotes from string values, leave NULLs/numbers as-is."""
    v = v.strip()
    if v.upper() == "NULL":
        return ""
    if len(v) >= 2 and v[0] == "'" and v[-1] == "'":
        # Unescape backslash-escaped quotes/backslashes
        inner = v[1:-1].replace("\\'", "'").replace('\\\\', '\\').replace('\\n', '\n')
        return inner
    return v


def _sql_to_chunks(sql: str, data_dir: Path, section: str, base_id: str) -> list[dict]:
    """Convert a mysqldump (--skip-extended-insert) into row chunks.

    One chunk per row. Internal DBs (mysql, sys, ...) skipped.
    """
    chunks: list[dict] = []
    current_db: str | None = None
    chunk_idx = 0
    rows_per_table: dict[tuple[str, str], int] = {}

    for raw in sql.splitlines():
        line = raw.rstrip()
        if not line:
            continue
        m_use = _USE_RE.match(line)
        if m_use:
            current_db = m_use.group(1)
            continue
        m = _INSERT_RE.match(line)
        if m:
            db, table, values = m.group(1), m.group(2), m.group(3)
        else:
            m2 = _INSERT_BARE_RE.match(line)
            if not m2 or current_db is None:
                continue
            db, table, values = current_db, m2.group(1), m2.group(2)

        if db in _INTERNAL_DBS:
            continue
        rows_per_table[(db, table)] = rows_per_table.get((db, table), 0) + 1
        cells = [_format_value(c) for c in _split_values(values)]
        text = f"{db}.{table} row: " + " | ".join(c for c in cells if c)
        if len(text) < 30:
            continue
        chunks.append({
            "id": f"{base_id}-{chunk_idx:05d}",
            "text": text,
            "format": "pretrain",
            "metadata": {
                "source_file": str(data_dir),
                "source_format": "mysql_revive",
                "section": section,
                "doc_title": f"{db}.{table}",
                "chunk_type": "row",
                "chunk_idx": chunk_idx,
                "char_count": len(text),
                "mysql_db": db,
                "mysql_table": table,
            },
        })
        chunk_idx += 1
    sys.stderr.write(
        f"[mysql_revive] {data_dir.name}: extracted {len(chunks)} rows "
        f"from {len(rows_per_table)} tables\n"
    )
    return chunks


def _fallback_metadata_chunk(path: Path, section: str, base_id: str, reason: str) -> dict:
    text = (
        f"MySQL data file: {path.name} (no extraction performed: {reason}). "
        f"To recover the data, mount the parent directory as a mysql:8 "
        f"datadir and dump the tables manually."
    )
    return {
        "id": f"{base_id}-mysql-meta",
        "text": text,
        "format": "pretrain",
        "metadata": {
            "source_file": str(path),
            "source_format": "mysql_revive",
            "section": section,
            "doc_title": path.stem,
            "chunk_type": "metadata_only",
            "chunk_idx": 0,
            "char_count": len(text),
            "fallback_reason": reason,
        },
    }


# ---- Plugin -------------------------------------------------------------

class _MySQLRevivePlugin:
    extensions = (".frm", ".myi", ".myd", ".ibd", ".ibdata")
    source_format = "mysql_revive"
    requires = ()                       # docker is the only real dep, checked at runtime
    system_deps = ("docker",)
    default_on = True
    disable_env = "FORGE_DISABLE_MYSQL_REVIVE"

    def iter_chunks(
        self, path: Path, section: str, base_id: str, options: dict
    ) -> Iterator[dict]:
        # Find the cluster
        data_dir = _find_data_dir(path)
        if data_dir is None:
            yield _fallback_metadata_chunk(path, section, base_id, "no-data-dir-detected")
            return

        cache_key = str(data_dir.resolve())
        if cache_key in _CLUSTER_CACHE:
            # Already extracted by a sibling file. Yield only if THIS file
            # was the cluster owner — otherwise skip to avoid duplicates.
            if _CLUSTER_OWNER.get(cache_key) == str(path.resolve()):
                yield from _CLUSTER_CACHE[cache_key]
            return

        # First file in this cluster — claim ownership and do the work.
        _CLUSTER_OWNER[cache_key] = str(path.resolve())

        if not _have_docker():
            chunks = [_fallback_metadata_chunk(path, section, base_id, "docker-unavailable")]
            _CLUSTER_CACHE[cache_key] = chunks
            yield from chunks
            return

        sys.stderr.write(f"[mysql_revive] reviving {data_dir} (cluster owner: {path.name})\n")
        sql = _revive_and_dump(data_dir)
        if sql is None:
            chunks = [_fallback_metadata_chunk(path, section, base_id, "revive-failed")]
            _CLUSTER_CACHE[cache_key] = chunks
            yield from chunks
            return

        chunks = _sql_to_chunks(sql, data_dir, section, base_id)
        if not chunks:
            chunks = [_fallback_metadata_chunk(path, section, base_id, "no-user-data-rows")]
        _CLUSTER_CACHE[cache_key] = chunks
        yield from chunks


PLUGIN = _MySQLRevivePlugin()
