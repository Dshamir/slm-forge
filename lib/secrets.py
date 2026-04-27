"""
slm-forge/lib/secrets.py — credential resolver for ref-style configs.

Ports the key ideas from backend/src/services/vault-client.ts:
  - env-var fallback (always available)
  - in-memory TTL cache (5 min default)
  - graceful degradation when Vault unreachable
  - never log resolved secret values

Public API:
    resolve_ref(ref: str) -> str            # plain string (legacy)
    resolve_secret(ref: str) -> Secret      # safer wrapper; .reveal() to use
    Secret                                  # __repr__/__str__ both hide value
    redact_for_logging(obj: Any) -> Any     # walks dict, replaces *_ref values

Ref syntax:
    env:VAR_NAME      → os.environ["VAR_NAME"]
    file:/abs/path    → file contents (stripped)
    vault:path#key    → HashiCorp Vault KV v2 (requires VAULT_ADDR + VAULT_TOKEN)
    <plain string>    → returned as-is

Vault is OPTIONAL — if VAULT_ADDR is missing, vault: refs raise a clear
NotImplementedError directing to env: alternatives. This matches the TS
client's behavior of "try Vault first, env-var fallback always works".

Stack-trace safety:
    Secret instances render as '<Secret ref=env:PG_PASSWORD>' in repr() and
    '<REDACTED>' in str(). A traceback that captures local variables holding
    a Secret won't leak the actual value. Callers that need to USE the value
    explicitly call .reveal() — every leak point is then grep-able.
"""
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from copy import deepcopy
from pathlib import Path
from typing import Any


# Cache TTL — same default as vault-client.ts (300_000 ms = 5 min)
CACHE_TTL_SEC = int(os.environ.get("FORGE_SECRETS_CACHE_TTL_SEC",
                                    os.environ.get("VAULT_CACHE_TTL_MS", "300000"))) // 1000 \
    if (os.environ.get("VAULT_CACHE_TTL_MS") or "").isdigit() \
    else int(os.environ.get("FORGE_SECRETS_CACHE_TTL_SEC", "300"))

_cache: dict[str, tuple[str, float]] = {}   # ref → (value, expires_at_epoch)


class Secret:
    """Stack-trace-safe holder for a resolved credential.

    repr() and str() both REDACT the value — only the originating ref
    name is exposed. Call .reveal() to get the underlying string when
    actually passing the credential to a driver.

    Equality compares the underlying value (so test assertions still
    work). Hash matches the value too for set/dict membership.
    """
    __slots__ = ("_value", "_ref")

    def __init__(self, value: str, ref: str = "<inline>"):
        # use object.__setattr__ to honor __slots__
        object.__setattr__(self, "_value", value)
        object.__setattr__(self, "_ref", ref)

    def reveal(self) -> str:
        return self._value

    def __repr__(self) -> str:
        return f"<Secret ref={self._ref}>"

    def __str__(self) -> str:
        return "<REDACTED>"

    def __eq__(self, other) -> bool:
        if isinstance(other, Secret):
            return self._value == other._value
        return False

    def __hash__(self) -> int:
        return hash(self._value)

    def __setattr__(self, *_args, **_kwargs):
        raise AttributeError("Secret is immutable")


def _cache_get(ref: str):
    entry = _cache.get(ref)
    if entry is None:
        return None
    value, expires_at = entry
    if expires_at < time.time():
        _cache.pop(ref, None)
        return None
    return value


def _cache_put(ref: str, value: str):
    _cache[ref] = (value, time.time() + CACHE_TTL_SEC)


def _resolve_env(ref: str) -> str:
    var = ref[len("env:"):]
    val = os.environ.get(var)
    if val is None:
        raise KeyError(
            f"env ref '{ref}': environment variable {var!r} not set. "
            f"Either set it, switch the config to a different ref kind, "
            f"or use a literal value."
        )
    return val


def _resolve_file(ref: str) -> str:
    p = Path(ref[len("file:"):])
    if not p.is_file():
        raise FileNotFoundError(f"file ref '{ref}': {p} not found")
    return p.read_text().strip()


def _resolve_vault(ref: str) -> str:
    """KV v2 ref syntax: vault:path#key
    Reads VAULT_ADDR + VAULT_TOKEN from env; supports the standard KV v2
    layout where data lives under {path}/data/{secret-path}."""
    body = ref[len("vault:"):]
    if "#" not in body:
        raise ValueError(
            f"vault ref '{ref}': missing #key suffix "
            f"(syntax: vault:secret/path#field-name)"
        )
    path, key = body.rsplit("#", 1)
    addr = os.environ.get("VAULT_ADDR")
    token = os.environ.get("VAULT_TOKEN")
    if not addr or not token:
        raise NotImplementedError(
            f"vault ref '{ref}': VAULT_ADDR + VAULT_TOKEN required. "
            f"Either set them OR rewrite as env:VAR_NAME using a process "
            f"env-var that holds the same secret."
        )
    # KV v2 read: GET {addr}/v1/{mount}/data/{rest_of_path}
    # Convention: first path segment is the KV mount, rest is the secret path.
    # If path doesn't already include /data/, insert it after the mount.
    if "/data/" not in path:
        parts = path.split("/", 1)
        if len(parts) == 2:
            mount, rest = parts
            api_path = f"{mount}/data/{rest}"
        else:
            api_path = f"{path}/data/"
    else:
        api_path = path
    url = f"{addr.rstrip('/')}/v1/{api_path.lstrip('/')}"
    req = urllib.request.Request(url, headers={"X-Vault-Token": token})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as e:
        raise PermissionError(
            f"vault ref '{ref}': HTTP {e.code} from {url}. Check token + path."
        ) from e
    except urllib.error.URLError as e:
        raise ConnectionError(
            f"vault ref '{ref}': could not reach {addr}: {e.reason}"
        ) from e
    data = (payload.get("data") or {}).get("data") or {}
    if key not in data:
        raise KeyError(f"vault ref '{ref}': key {key!r} not found at {api_path}")
    return str(data[key])


def resolve_ref(ref: str) -> str:
    """Resolve a config ref to a concrete string. Cached for CACHE_TTL_SEC.

    Returns a plain str — convenient for adapters but visible in stack
    traces. For new code, prefer resolve_secret() which wraps the value
    in a Secret() that hides itself from repr/str.
    """
    if not isinstance(ref, str):
        return str(ref)

    cached = _cache_get(ref)
    if cached is not None:
        return cached

    if ref.startswith("env:"):
        value = _resolve_env(ref)
    elif ref.startswith("file:"):
        value = _resolve_file(ref)
    elif ref.startswith("vault:"):
        value = _resolve_vault(ref)
    else:
        # Plain literal — returned as-is. NOT cached (no point).
        return ref

    _cache_put(ref, value)
    return value


def resolve_secret(ref: str) -> Secret:
    """Same as resolve_ref but returns a Secret wrapper.

    Use this when the resolved value flows through code paths that might
    raise — Python's traceback machinery captures local frame variables
    by default, so a plain string in a `password = resolve_ref(...)`
    local can leak via the post-mortem dump. Secret instances render as
    '<REDACTED>' in any traceback.
    """
    if not isinstance(ref, str):
        return Secret(str(ref), "<non-string>")
    return Secret(resolve_ref(ref), ref)


def redact_for_logging(obj: Any) -> Any:
    """Deep-copy obj, replacing any *_ref VALUES with '<redacted>'.

    Use this BEFORE printing/logging configs. The intent is that even a
    stack-trace dump of the config object never reveals which actual env
    var or vault path was used — only the field names + redaction marker.
    """
    # Don't deepcopy Secret instances — their __setattr__ blocks it.
    # Replace them with a sentinel string before deepcopy.
    def _pre_replace(node):
        if isinstance(node, Secret):
            return "<redacted-secret>"
        if isinstance(node, dict):
            return {k: _pre_replace(v) for k, v in node.items()}
        if isinstance(node, (list, tuple)):
            return type(node)(_pre_replace(v) for v in node)
        return node

    out = deepcopy(_pre_replace(obj))

    def walk(node):
        if isinstance(node, dict):
            for k, v in list(node.items()):
                if k.endswith("_ref") and isinstance(v, str):
                    node[k] = "<redacted>"
                else:
                    walk(v)
        elif isinstance(node, list):
            for item in node:
                walk(item)
    walk(out)
    return out


def clear_cache():
    """Wipe the secret cache (for tests)."""
    _cache.clear()
