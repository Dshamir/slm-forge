#!/usr/bin/env python3
"""
forge-ingest fan-out — multi-source ingestion orchestrator.

Reads a config.yaml describing N sources, dispatches each to its handler,
merges all outputs into a single prepped.jsonl with cross-source dedup.

Usage:
    python fanout.py <run-id> <config.yaml>
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Iterator

try:
    import yaml
except ImportError:
    sys.stderr.write("forge-ingest: pyyaml required.\n")
    sys.exit(2)

# Bring shared helpers into the path
_THIS = Path(__file__).resolve().parent
sys.path.insert(0, str(_THIS.parent.parent / "scripts"))   # prep_plugins/
sys.path.insert(0, str(_THIS.parent.parent / "lib"))       # secrets

from prep_plugins.orchestration_helpers import hash_text  # noqa: E402
from prep_plugins.schema import validate_chunk            # noqa: E402

try:
    from secrets import resolve_ref, redact_for_logging
except ImportError:
    def resolve_ref(s): return s
    def redact_for_logging(o): return o


REPO_ROOT = _THIS.parent.parent.parent  # .../Exp_dental
RUN_ROOT = _THIS.parent.parent / ".runs"


# ---- Source handlers ------------------------------------------------------

def _handle_local_dir(source: dict, work_dir: Path) -> Path:
    """Run forge-prep against a directory. Returns path to per-source JSONL."""
    target = source.get("path")
    if not target or not Path(target).is_dir():
        raise FileNotFoundError(f"local_dir: path {target!r} not a dir")
    out_path = work_dir / f"{source['name']}.jsonl"
    stats_path = work_dir / f"{source['name']}-stats.json"

    # Pass through enable_plugins as env vars (FORGE_DISABLE_OCR etc.)
    env = os.environ.copy()
    enabled = set(source.get("enable_plugins", []))
    if "ocr" not in enabled:
        env.setdefault("FORGE_DISABLE_OCR", "1")
    if "transcribe" not in enabled and "av" not in enabled:
        env.setdefault("FORGE_DISABLE_TRANSCRIBE", "1")

    orchestrator = REPO_ROOT / "slm-forge" / "scripts" / "prep-orchestrator.py"
    venv_py = os.environ.get("FORGE_VENV", "/tmp/forge-venv") + "/bin/python"
    if not Path(venv_py).is_file():
        venv_py = sys.executable
    result = subprocess.run(
        [venv_py, str(orchestrator),
         "--input", target,
         "--output", str(out_path),
         "--stats", str(stats_path)],
        env=env, capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"prep-orchestrator failed for {source['name']}: {result.stderr[-500:]}")
    return out_path


def _handle_archive(source: dict, work_dir: Path) -> Path:
    """Extract archive to a tmpdir, then dispatch as local_dir."""
    arch_path = Path(source["path"])
    if not arch_path.is_file():
        raise FileNotFoundError(f"archive: {arch_path} not found")
    extract_dir = work_dir / f"{source['name']}-extracted"
    extract_dir.mkdir(parents=True, exist_ok=True)

    name = arch_path.name.lower()
    if name.endswith(".zip"):
        import zipfile
        with zipfile.ZipFile(arch_path) as zf:
            zf.extractall(extract_dir)
    elif any(name.endswith(s) for s in (".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2")):
        import tarfile
        with tarfile.open(arch_path) as tf:
            try:
                tf.extractall(extract_dir, filter="data")
            except TypeError:
                tf.extractall(extract_dir)
    elif name.endswith(".7z"):
        import py7zr
        with py7zr.SevenZipFile(arch_path) as sz:
            sz.extractall(extract_dir)
    elif name.endswith(".rar"):
        import rarfile
        with rarfile.RarFile(arch_path) as rf:
            rf.extractall(extract_dir)
    else:
        raise ValueError(f"archive: unrecognized extension on {arch_path}")

    # Reuse local_dir handler
    delegated = dict(source, kind="local_dir", path=str(extract_dir))
    return _handle_local_dir(delegated, work_dir)


def _handle_http(source: dict, work_dir: Path) -> Path:
    """Download URL, verify sha256 if given, then dispatch by extension."""
    url = source.get("url")
    mirrors = source.get("mirrors", []) or []
    if not url:
        raise ValueError(f"http: source.url required")
    expected_sha = source.get("sha256")
    fname = source.get("filename") or url.rsplit("/", 1)[-1] or f"{source['name']}.bin"
    dl_path = work_dir / f"{source['name']}-dl-{fname}"

    # Retry with exponential backoff across the primary URL + any mirrors.
    # 3 attempts per URL, doubling delay (1s, 2s, 4s).
    candidates = [url] + list(mirrors)
    last_err = None
    for candidate in candidates:
        for attempt in range(3):
            sys.stderr.write(
                f"[ingest] http: downloading {candidate} → {dl_path}"
                f" (attempt {attempt + 1}/3)\n"
            )
            try:
                urllib.request.urlretrieve(candidate, dl_path)
                last_err = None
                break
            except urllib.error.URLError as e:
                last_err = e
                if attempt < 2:
                    time.sleep(2 ** attempt)
        else:
            sys.stderr.write(
                f"[ingest] http: {candidate} exhausted retries: {last_err}\n"
            )
            continue
        # Successful download — break out of mirror loop too
        break
    if last_err is not None:
        raise ConnectionError(
            f"http: download failed across {len(candidates)} URL(s): {last_err.reason}"
        ) from last_err

    if expected_sha:
        actual_sha = hashlib.sha256(dl_path.read_bytes()).hexdigest()
        if actual_sha != expected_sha:
            raise ValueError(
                f"http: sha256 mismatch on {dl_path}: expected {expected_sha}, got {actual_sha}"
            )

    # Dispatch by extension
    ext = Path(fname).suffix.lower()
    if ext == ".jsonl":
        return _handle_jsonl({"name": source["name"], "kind": "jsonl", "path": str(dl_path)}, work_dir)
    if ext in (".zip", ".tar", ".gz", ".tgz", ".bz2", ".tbz2", ".7z", ".rar") or fname.endswith(".tar.gz") or fname.endswith(".tar.bz2"):
        return _handle_archive({"name": source["name"], "kind": "archive", "path": str(dl_path)}, work_dir)
    # Treat as a single-file dir
    single_dir = work_dir / f"{source['name']}-singlefile"
    single_dir.mkdir(exist_ok=True)
    shutil.copy2(dl_path, single_dir / fname)
    return _handle_local_dir({"name": source["name"], "kind": "local_dir", "path": str(single_dir)}, work_dir)


def _handle_jsonl(source: dict, work_dir: Path) -> Path:
    """Pass-through: copy the JSONL into the work dir as-is."""
    src = Path(source["path"])
    if not src.is_file():
        raise FileNotFoundError(f"jsonl: {src} not found")
    out = work_dir / f"{source['name']}.jsonl"
    shutil.copy2(src, out)
    return out


def _handle_hf_dataset(source: dict, work_dir: Path) -> Path:
    """Download an HF dataset split, write each row as a chunk."""
    repo = source.get("repo")
    if not repo:
        raise ValueError("hf_dataset: source.repo required")
    split = source.get("split", "train")
    text_field = source.get("text_field", "text")

    try:
        from datasets import load_dataset
    except ImportError:
        raise ImportError(
            "hf_dataset requires `datasets` package — run:\n"
            "  /tmp/forge-venv/bin/pip install datasets"
        )

    # Pre-check the repo's gated/private status so the operator gets a clear
    # auth error instead of a generic network exception 30s into the run.
    hf_token = (
        source.get("token")
        or os.environ.get("HF_TOKEN")
        or os.environ.get("HUGGING_FACE_HUB_TOKEN")
    )
    try:
        from huggingface_hub import HfApi
        info = HfApi().dataset_info(repo, token=hf_token)
        if getattr(info, "gated", False) and not hf_token:
            raise PermissionError(
                f"hf_dataset {repo!r} is gated; set HF_TOKEN env var (or "
                f"`token:` in the source config) AND accept the dataset's "
                f"terms at https://huggingface.co/datasets/{repo} once."
            )
        if getattr(info, "private", False) and not hf_token:
            raise PermissionError(
                f"hf_dataset {repo!r} is private; set HF_TOKEN env var "
                f"(or `token:` in the source config) with read access."
            )
    except PermissionError:
        raise
    except Exception:
        # huggingface_hub not available or transient — fall through to load_dataset
        # which will surface the actual error itself.
        pass

    load_kwargs = {"split": split, "streaming": False}
    if hf_token:
        load_kwargs["token"] = hf_token
    ds = load_dataset(repo, **load_kwargs)

    out = work_dir / f"{source['name']}.jsonl"
    n = 0
    with open(out, "w") as f:
        for i, row in enumerate(ds):
            text = row.get(text_field)
            if not text:
                continue
            chunk = {
                "id": f"{source['name']}-{i:06d}",
                "text": str(text),
                "format": "pretrain",
                "metadata": {
                    "source_file": f"hf:{repo}#{split}",
                    "source_format": "hf_dataset",
                    "section": source['name'],
                    "doc_title": repo,
                    "chunk_type": "row",
                    "chunk_idx": i,
                    "char_count": len(str(text)),
                },
            }
            ok, _ = validate_chunk(chunk)
            if ok:
                f.write(json.dumps(chunk) + "\n")
                n += 1
    sys.stderr.write(f"[ingest] hf_dataset {repo}#{split}: {n} rows\n")
    return out


def _handle_database(source: dict, work_dir: Path) -> Path:
    """Delegate to forge-ingest-db with the embedded config."""
    db_config_path = source.get("config")
    if not db_config_path or not Path(db_config_path).is_file():
        raise FileNotFoundError(f"database: config {db_config_path!r} not found")

    # forge-ingest-db expects to write into .runs/<run-id>/ingested-db.jsonl
    # We need to use a per-source run subdir to avoid clobbering when there
    # are multiple database sources.
    sub_run = f"{source['name']}-db"
    sub_dir = RUN_ROOT / sub_run
    sub_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(db_config_path, sub_dir / "db-sources.yaml")

    skill_run = REPO_ROOT / "slm-forge" / "skills" / "forge-ingest-db" / "run.sh"
    result = subprocess.run(
        ["bash", str(skill_run), sub_run],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"forge-ingest-db failed for {source['name']}: {result.stderr[-500:]}")

    src_jsonl = sub_dir / "ingested-db.jsonl"
    if not src_jsonl.is_file():
        raise RuntimeError(f"forge-ingest-db produced no output at {src_jsonl}")
    out = work_dir / f"{source['name']}.jsonl"
    shutil.move(str(src_jsonl), out)
    return out


def _handle_git(source: dict, work_dir: Path) -> Path:
    """Clone a git repo and dispatch its working tree as local_dir.

    Config:
      url:         repo URL (https or ssh)
      ref:         optional branch / tag / commit (defaults to HEAD)
      depth:       optional shallow-clone depth (defaults to 1)
      include:     optional list of glob patterns to keep (others removed)
      exclude:     optional list of glob patterns to remove
      auth_token_ref:  optional credential ref for HTTPS auth (env:/file:/vault:)
    """
    url = source.get("url")
    if not url:
        raise ValueError("git: source.url required")
    ref = source.get("ref")
    depth = int(source.get("depth", 1))
    include = source.get("include", []) or []
    exclude = source.get("exclude", []) or []

    # Inject auth token into HTTPS URL if a ref is given
    auth_ref = source.get("auth_token_ref")
    if auth_ref and url.startswith("https://"):
        try:
            from secrets import resolve_ref as _rr  # type: ignore
            tok = _rr(auth_ref)
            url = url.replace("https://", f"https://x-access-token:{tok}@", 1)
        except Exception as e:
            raise ValueError(f"git: auth_token_ref resolve failed: {e}")

    clone_dir = work_dir / f"{source['name']}-git"
    if clone_dir.exists():
        shutil.rmtree(clone_dir)

    cmd = ["git", "clone", "--depth", str(depth)]
    if ref and depth == 1:
        # --branch works for both branch and tag refs; commit SHA needs a
        # full clone + checkout (handled below).
        cmd += ["--branch", ref]
    cmd += [url, str(clone_dir)]
    sys.stderr.write(f"[ingest] git: clone {source.get('url')} (depth={depth})\n")
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if r.returncode != 0:
        # Retry without --branch in case ref was a commit SHA (needs full clone)
        if ref and depth == 1:
            sys.stderr.write(f"[ingest] git: --branch {ref} failed, retrying full clone\n")
            shutil.rmtree(clone_dir, ignore_errors=True)
            r = subprocess.run(
                ["git", "clone", url, str(clone_dir)],
                capture_output=True, text=True, timeout=900,
            )
            if r.returncode == 0 and ref:
                co = subprocess.run(
                    ["git", "-C", str(clone_dir), "checkout", ref],
                    capture_output=True, text=True, timeout=120,
                )
                if co.returncode != 0:
                    raise RuntimeError(f"git: checkout {ref} failed: {co.stderr[-300:]}")
        if r.returncode != 0:
            raise RuntimeError(f"git: clone failed: {r.stderr[-300:]}")

    # Strip .git so it doesn't pollute the corpus walk
    shutil.rmtree(clone_dir / ".git", ignore_errors=True)

    # Apply include/exclude filters
    if include or exclude:
        from fnmatch import fnmatch
        keep = set()
        if include:
            for f in clone_dir.rglob("*"):
                if f.is_file():
                    rel = str(f.relative_to(clone_dir))
                    if any(fnmatch(rel, pat) for pat in include):
                        keep.add(f)
        else:
            keep = {f for f in clone_dir.rglob("*") if f.is_file()}
        if exclude:
            keep = {f for f in keep
                    if not any(fnmatch(str(f.relative_to(clone_dir)), pat)
                               for pat in exclude)}
        # Remove anything not in keep
        for f in list(clone_dir.rglob("*")):
            if f.is_file() and f not in keep:
                try:
                    f.unlink()
                except OSError:
                    pass

    delegated = dict(source, kind="local_dir", path=str(clone_dir))
    return _handle_local_dir(delegated, work_dir)


def _handle_s3(source: dict, work_dir: Path) -> Path:
    """Download an S3 prefix (or single key) to a local dir, then dispatch.

    Config:
      bucket:      my-corpus
      prefix:      "papers/"           # for whole "directory"
      key:         "single-file.jsonl" # OR for one file
      region:      ca-central-1
      endpoint_url: https://s3.example  # MinIO / S3-compatible
      access_key_id_ref:     "env:AWS_ACCESS_KEY_ID"
      secret_access_key_ref: "env:AWS_SECRET_ACCESS_KEY"
      session_token_ref:     "env:AWS_SESSION_TOKEN"  # optional
      include / exclude: optional glob lists
    """
    try:
        import boto3  # type: ignore
    except ImportError:
        raise ImportError(
            "s3 source requires boto3 — run:\n"
            "  /tmp/forge-venv/bin/pip install boto3"
        )
    bucket = source.get("bucket")
    if not bucket:
        raise ValueError("s3: source.bucket required")
    prefix = source.get("prefix")
    key = source.get("key")
    if not prefix and not key:
        raise ValueError("s3: either source.prefix or source.key required")

    s3_kwargs = {}
    if "region" in source:
        s3_kwargs["region_name"] = source["region"]
    if "endpoint_url" in source:
        s3_kwargs["endpoint_url"] = source["endpoint_url"]
    if "access_key_id" in source:
        s3_kwargs["aws_access_key_id"] = source["access_key_id"]
    if "secret_access_key" in source:
        s3_kwargs["aws_secret_access_key"] = source["secret_access_key"]
    if "session_token" in source:
        s3_kwargs["aws_session_token"] = source["session_token"]

    client = boto3.client("s3", **s3_kwargs)
    download_dir = work_dir / f"{source['name']}-s3"
    download_dir.mkdir(parents=True, exist_ok=True)

    keys = [key] if key else []
    if prefix:
        paginator = client.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
            for obj in page.get("Contents", []) or []:
                if obj["Size"] > 0:  # skip "directory marker" objects
                    keys.append(obj["Key"])

    from fnmatch import fnmatch
    include = source.get("include", []) or []
    exclude = source.get("exclude", []) or []
    if include:
        keys = [k for k in keys if any(fnmatch(k, pat) for pat in include)]
    if exclude:
        keys = [k for k in keys if not any(fnmatch(k, pat) for pat in exclude)]

    sys.stderr.write(f"[ingest] s3: downloading {len(keys)} object(s) from s3://{bucket}\n")
    for k in keys:
        # Mirror the key under download_dir, preserving any sub-prefixes
        local_path = download_dir / k.replace("/", os.sep)
        local_path.parent.mkdir(parents=True, exist_ok=True)
        client.download_file(bucket, k, str(local_path))

    delegated = dict(source, kind="local_dir", path=str(download_dir))
    return _handle_local_dir(delegated, work_dir)


def _handle_gcs(source: dict, work_dir: Path) -> Path:
    """Download a GCS prefix (or single object) and dispatch.

    Config:
      bucket:                 my-corpus
      prefix:                 "papers/"          # OR
      object:                 "single-file.jsonl"
      project:                my-gcp-project     # optional
      credentials_json_path:  /path/sa.json      # optional
      credentials_json:       <resolved-from-ref>
    """
    try:
        from google.cloud import storage  # type: ignore
    except ImportError:
        raise ImportError(
            "gcs source requires google-cloud-storage — run:\n"
            "  /tmp/forge-venv/bin/pip install google-cloud-storage"
        )
    bucket_name = source.get("bucket")
    if not bucket_name:
        raise ValueError("gcs: source.bucket required")
    prefix = source.get("prefix")
    obj = source.get("object")
    if not prefix and not obj:
        raise ValueError("gcs: either source.prefix or source.object required")

    creds = None
    if "credentials_json_path" in source:
        from google.oauth2 import service_account  # type: ignore
        creds = service_account.Credentials.from_service_account_file(
            source["credentials_json_path"]
        )
    elif "credentials_json" in source:
        from google.oauth2 import service_account  # type: ignore
        creds = service_account.Credentials.from_service_account_info(
            json.loads(source["credentials_json"])
        )

    client_kwargs = {}
    if "project" in source:
        client_kwargs["project"] = source["project"]
    if creds is not None:
        client_kwargs["credentials"] = creds
    client = storage.Client(**client_kwargs)
    bucket = client.bucket(bucket_name)

    download_dir = work_dir / f"{source['name']}-gcs"
    download_dir.mkdir(parents=True, exist_ok=True)

    blobs = []
    if obj:
        blobs.append(bucket.blob(obj))
    if prefix:
        blobs.extend(client.list_blobs(bucket_name, prefix=prefix))

    from fnmatch import fnmatch
    include = source.get("include", []) or []
    exclude = source.get("exclude", []) or []

    sys.stderr.write(f"[ingest] gcs: downloading from gs://{bucket_name}\n")
    n = 0
    for b in blobs:
        if b.size == 0 and b.name.endswith("/"):
            continue
        if include and not any(fnmatch(b.name, pat) for pat in include):
            continue
        if exclude and any(fnmatch(b.name, pat) for pat in exclude):
            continue
        local_path = download_dir / b.name.replace("/", os.sep)
        local_path.parent.mkdir(parents=True, exist_ok=True)
        b.download_to_filename(str(local_path))
        n += 1
    sys.stderr.write(f"[ingest] gcs: downloaded {n} blob(s)\n")

    delegated = dict(source, kind="local_dir", path=str(download_dir))
    return _handle_local_dir(delegated, work_dir)


def _handle_azure(source: dict, work_dir: Path) -> Path:
    """Download an Azure Blob container/prefix and dispatch.

    Config:
      account:           myaccount
      container:         corpus
      prefix:            "papers/"           # OR
      blob:              "single-file.jsonl"
      sas_token_ref:     "env:AZ_SAS"        # SAS auth (preferred for ingest)
      account_key_ref:   "env:AZ_KEY"        # OR shared-key auth
      connection_string_ref: "env:AZ_CONN"   # OR full connection string
    """
    try:
        from azure.storage.blob import BlobServiceClient  # type: ignore
    except ImportError:
        raise ImportError(
            "azure source requires azure-storage-blob — run:\n"
            "  /tmp/forge-venv/bin/pip install azure-storage-blob"
        )
    container = source.get("container")
    if not container:
        raise ValueError("azure: source.container required")
    prefix = source.get("prefix")
    blob_name = source.get("blob")
    if not prefix and not blob_name:
        raise ValueError("azure: either source.prefix or source.blob required")

    if "connection_string" in source:
        client = BlobServiceClient.from_connection_string(source["connection_string"])
    elif "account" in source:
        url = f"https://{source['account']}.blob.core.windows.net"
        cred = source.get("sas_token") or source.get("account_key")
        if not cred:
            raise ValueError(
                "azure: account auth requires sas_token_ref OR account_key_ref"
            )
        client = BlobServiceClient(account_url=url, credential=cred)
    else:
        raise ValueError(
            "azure: must provide either connection_string_ref OR (account + sas_token/account_key)"
        )

    container_client = client.get_container_client(container)
    download_dir = work_dir / f"{source['name']}-az"
    download_dir.mkdir(parents=True, exist_ok=True)

    from fnmatch import fnmatch
    include = source.get("include", []) or []
    exclude = source.get("exclude", []) or []

    blobs_list = []
    if blob_name:
        blobs_list.append(blob_name)
    if prefix:
        blobs_list.extend(b.name for b in container_client.list_blobs(name_starts_with=prefix))

    sys.stderr.write(f"[ingest] azure: downloading from {container}/\n")
    n = 0
    for bn in blobs_list:
        if include and not any(fnmatch(bn, pat) for pat in include):
            continue
        if exclude and any(fnmatch(bn, pat) for pat in exclude):
            continue
        local_path = download_dir / bn.replace("/", os.sep)
        local_path.parent.mkdir(parents=True, exist_ok=True)
        bc = container_client.get_blob_client(bn)
        with open(local_path, "wb") as f:
            f.write(bc.download_blob().readall())
        n += 1
    sys.stderr.write(f"[ingest] azure: downloaded {n} blob(s)\n")

    delegated = dict(source, kind="local_dir", path=str(download_dir))
    return _handle_local_dir(delegated, work_dir)


_HANDLERS = {
    "local_dir": _handle_local_dir,
    "archive": _handle_archive,
    "http": _handle_http,
    "jsonl": _handle_jsonl,
    "hf_dataset": _handle_hf_dataset,
    "database": _handle_database,
    "git": _handle_git,
    "s3": _handle_s3,
    "gcs": _handle_gcs,
    "azure": _handle_azure,
}


# ---- Merge + dedup --------------------------------------------------------

def merge_with_dedup(per_source_files: dict, out_path: Path,
                     dedup_across: bool = True) -> dict:
    """Merge N JSONLs into one, deduping if requested. Returns stats dict.

    Dedup is two-tier:
      - within-source: always on (catches symlink loops + accidental dupes
        in a single dir/db/jsonl) — drops counted in dedup_drops_by_source
      - across-source: dedup_across=True (default) — uses the same
        cross-source `seen` hash set
    """
    seen = set()
    total = 0
    by_source = {}
    dedup_drops_by_source = {}
    schema_failures = 0

    with open(out_path, "w") as out:
        for source_name, src_path in per_source_files.items():
            seen_in_source: set[str] = set()
            n_in = 0
            n_out = 0
            n_dedup = 0
            for line in open(src_path):
                line = line.strip()
                if not line:
                    continue
                n_in += 1
                try:
                    chunk = json.loads(line)
                except json.JSONDecodeError:
                    continue
                # Validate schema
                ok, _reason = validate_chunk(chunk)
                if not ok:
                    schema_failures += 1
                    continue
                # Prefix source name into provenance — metadata may be absent on chat format
                meta = chunk.setdefault("metadata", {})
                prior_src = meta.get("source_file", source_name)
                meta["source_file"] = f"{source_name}:{prior_src}" if prior_src != source_name else source_name
                # Dedup key — pretrain hashes text, chat hashes role+content
                # pairs (role differences DO matter — same prompt with different
                # system priming should not collapse).
                if chunk.get("format") == "chat":
                    dedup_payload = "\n".join(
                        f"{m.get('role', '')}:{m.get('content', '') or ''}"
                        for m in chunk.get("messages", [])
                    )
                else:
                    dedup_payload = chunk.get("text", "")
                h = hash_text(dedup_payload)
                # Within-source dedup ALWAYS runs (catches symlink loops)
                if h in seen_in_source:
                    n_dedup += 1
                    continue
                seen_in_source.add(h)
                # Cross-source dedup: opt-in via dedup_across_sources
                if dedup_across:
                    if h in seen:
                        n_dedup += 1
                        continue
                    seen.add(h)
                out.write(json.dumps(chunk) + "\n")
                n_out += 1
                total += 1
            by_source[source_name] = n_out
            dedup_drops_by_source[source_name] = n_dedup
            sys.stderr.write(f"[ingest] {source_name}: {n_in} → {n_out} (dedup_drop={n_dedup})\n")

    return {
        "total_chunks": total,
        "by_source": by_source,
        "dedup_drops_by_source": dedup_drops_by_source,
        "schema_failures": schema_failures,
    }


# ---- Main -----------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_id")
    ap.add_argument("config", nargs="?",
                    help="path to config.yaml; defaults to .runs/<run-id>/config.yaml")
    ap.add_argument("--print-config", action="store_true")
    ap.add_argument("--dry-run", action="store_true",
                    help="Parse + plan only — show estimated bytes per source, "
                         "validate handlers exist, return without downloading or "
                         "writing prepped.jsonl. Use this to preview a long-running "
                         "ingest (S3/GCS/HF/audio/video) before committing.")
    args = ap.parse_args()

    run_dir = RUN_ROOT / args.run_id
    config_path = Path(args.config) if args.config else run_dir / "config.yaml"
    if not config_path.is_file():
        sys.stderr.write(f"forge-ingest: config not found: {config_path}\n")
        return 1

    cfg = yaml.safe_load(config_path.read_text())
    if cfg.get("version") != 1:
        sys.stderr.write(f"forge-ingest: unsupported config version {cfg.get('version')}\n")
        return 2

    if args.print_config:
        print(json.dumps(redact_for_logging(cfg), indent=2))
        return 0

    sources = cfg.get("sources", [])
    if not sources:
        sys.stderr.write("forge-ingest: no sources in config\n")
        return 1

    options = cfg.get("options", {}) or {}
    dedup_across = bool(options.get("dedup_across_sources", True))

    if args.dry_run:
        # Plan + estimate, no side effects. Walks each source enough to
        # validate the handler dispatch and size locally-resolvable inputs.
        plan = []
        for source in sources:
            kind = source.get("kind", "?")
            entry = {
                "name": source.get("name"),
                "kind": kind,
                "handler_resolved": kind in _HANDLERS,
            }
            path = source.get("path")
            if kind in ("local_dir", "jsonl") and path and Path(path).exists():
                p = Path(path)
                if p.is_file():
                    entry["est_bytes"] = p.stat().st_size
                else:
                    sz = 0
                    nfiles = 0
                    for f in p.rglob("*"):
                        if f.is_file():
                            try:
                                sz += f.stat().st_size
                                nfiles += 1
                            except OSError:
                                pass
                    entry["est_bytes"] = sz
                    entry["est_files"] = nfiles
            elif kind == "http":
                entry["url"] = source.get("url")
                entry["mirrors_count"] = len(source.get("mirrors", []) or [])
            elif kind in ("s3", "gcs", "azure"):
                entry["bucket"] = source.get("bucket") or source.get("container")
                entry["prefix"] = source.get("prefix") or source.get("key") or source.get("blob") or source.get("object")
            elif kind == "git":
                entry["url"] = source.get("url")
                entry["depth"] = source.get("depth", 1)
            elif kind == "database":
                entry["db_config"] = source.get("config")
            elif kind == "hf_dataset":
                entry["repo"] = source.get("repo")
                entry["split"] = source.get("split", "train")
            plan.append(entry)

        print(json.dumps({
            "status": "dry-run",
            "config_redacted": redact_for_logging(cfg),
            "sources": plan,
            "dedup_across_sources": dedup_across,
            "would_write": str(run_dir / "prepped.jsonl"),
        }, indent=2, default=str))
        return 0

    # Refuse to clobber an existing prepped.jsonl from an earlier run.
    # Operators who genuinely want to re-ingest should pass --force or
    # use a fresh run-id; silently truncating prior work is too dangerous.
    prepped_check = run_dir / "prepped.jsonl"
    if prepped_check.exists() and prepped_check.stat().st_size > 0 \
       and not os.environ.get("FORGE_INGEST_FORCE"):
        sys.stderr.write(
            f"forge-ingest: {prepped_check} already exists and is non-empty.\n"
            f"  Re-running would truncate it. Set FORGE_INGEST_FORCE=1 to\n"
            f"  overwrite, or use a new run-id.\n"
        )
        return 3

    # Disk-space pre-check. Estimate output ≈ sum(input bytes) for jsonl
    # sources + 2x input for db/hf (row→text expansion). Refuse if free
    # space < 1.5x estimate. Skip for sources we can't size (db/hf).
    sized_estimate = 0
    for source in sources:
        kind = source.get("kind")
        path = source.get("path")
        if kind in ("local_dir", "jsonl") and path and Path(path).exists():
            p = Path(path)
            if p.is_file():
                sized_estimate += p.stat().st_size
            elif p.is_dir():
                for f in p.rglob("*"):
                    if f.is_file():
                        try:
                            sized_estimate += f.stat().st_size
                        except OSError:
                            pass
    if sized_estimate > 0:
        try:
            stat = os.statvfs(str(run_dir))
            free_bytes = stat.f_bavail * stat.f_frsize
            need = int(sized_estimate * 1.5)
            if free_bytes < need:
                sys.stderr.write(
                    f"forge-ingest: insufficient disk — need ~{need // 1024 // 1024} MB,"
                    f" have {free_bytes // 1024 // 1024} MB free at {run_dir}\n"
                )
                return 4
        except OSError:
            pass  # statvfs not available on every fs; skip the check

    # Per-source work dir
    work_dir = run_dir / "ingest"
    work_dir.mkdir(parents=True, exist_ok=True)

    per_source_files = {}
    failures = []
    for source in sources:
        name = source.get("name")
        kind = source.get("kind")
        if not name or not kind:
            failures.append({"name": name, "error": "missing name or kind"})
            continue
        handler = _HANDLERS.get(kind)
        if handler is None:
            failures.append({"name": name, "error": f"unknown kind: {kind}"})
            continue
        sys.stderr.write(f"[ingest] === {name} (kind={kind}) ===\n")
        try:
            out_path = handler(source, work_dir)
            per_source_files[name] = out_path
        except Exception as e:
            sys.stderr.write(f"[ingest] {name} FAILED: {type(e).__name__}: {e}\n")
            failures.append({"name": name, "error": f"{type(e).__name__}: {e}"})

    if not per_source_files:
        sys.stderr.write("forge-ingest: ALL sources failed\n")
        (run_dir / "ingest-stats.json").write_text(json.dumps({
            "total_chunks": 0,
            "by_source": {},
            "failures": failures,
        }, indent=2))
        return 1

    # Merge into prepped.jsonl
    prepped_path = run_dir / "prepped.jsonl"
    merge_stats = merge_with_dedup(per_source_files, prepped_path, dedup_across=dedup_across)

    stats = {
        **merge_stats,
        "failures": failures,
        "config_redacted": redact_for_logging(cfg),
        "output_path": str(prepped_path),
    }
    (run_dir / "ingest-stats.json").write_text(json.dumps(stats, indent=2))

    print(json.dumps({
        "status": "completed",
        "path": str(prepped_path),
        "total_chunks": merge_stats["total_chunks"],
        "by_source": merge_stats["by_source"],
        "failures": len(failures),
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
