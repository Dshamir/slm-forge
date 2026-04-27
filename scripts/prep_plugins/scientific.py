"""
Scientific data plugin — .h5 / .hdf5 (HDF5) and .nc (NetCDF).

These are columnar/array formats common in ML datasets, scientific
publishing, and engineering corpora. Pixel/array data is binary and
not training-text material, but every HDF5/NetCDF file carries a rich
metadata graph (group/variable names, dimensions, units, descriptions,
attributes) that IS valuable as documentation-style training input.

We emit ONE chunk per file containing a flattened text summary of the
schema. Heavy data is never read.
"""
from __future__ import annotations

from pathlib import Path
from typing import Iterator

from .orchestration_helpers import MIN_LEN


def _summarize_hdf5(path: Path) -> str | None:
    try:
        import h5py
    except ImportError:
        return None
    try:
        f = h5py.File(str(path), "r")
    except Exception:
        return None
    lines: list[str] = []
    try:
        # Root attributes
        for k, v in f.attrs.items():
            lines.append(f"@{k}: {v}")

        def _visit(name, obj):
            if isinstance(obj, h5py.Dataset):
                shape = "x".join(str(d) for d in obj.shape) or "scalar"
                lines.append(f"dataset {name}: dtype={obj.dtype} shape={shape}")
            elif isinstance(obj, h5py.Group):
                lines.append(f"group {name}/")
            for ak, av in obj.attrs.items():
                lines.append(f"  @{ak}: {av}")

        f.visititems(_visit)
    finally:
        try:
            f.close()
        except Exception:
            pass
    return "\n".join(lines) if lines else None


def _summarize_netcdf(path: Path) -> str | None:
    # Try netCDF4 first (most complete), fall back to xarray, then h5py
    # (NetCDF4 is HDF5 underneath so h5py reads it as a last resort).
    try:
        import netCDF4  # type: ignore
        ds = netCDF4.Dataset(str(path), "r")
    except ImportError:
        return _summarize_hdf5(path)  # NetCDF4 → HDF5 fallback
    except Exception:
        return None

    lines: list[str] = []
    try:
        for k in ds.ncattrs():
            lines.append(f"@{k}: {getattr(ds, k)}")
        for dname, dim in ds.dimensions.items():
            lines.append(f"dim {dname}: {len(dim)}")
        for vname, var in ds.variables.items():
            shape = "x".join(str(s) for s in var.shape) or "scalar"
            lines.append(f"var {vname}: dtype={var.dtype} shape={shape}")
            for vk in var.ncattrs():
                lines.append(f"  @{vk}: {getattr(var, vk)}")
    finally:
        try:
            ds.close()
        except Exception:
            pass
    return "\n".join(lines) if lines else None


class _ScientificPlugin:
    extensions = (".h5", ".hdf5", ".nc")
    source_format = "scientific"
    requires = ("h5py", "netCDF4")
    system_deps = ()
    default_on = True
    disable_env = "FORGE_DISABLE_SCIENTIFIC"

    def iter_chunks(self, path: Path, section: str, base_id: str, options: dict) -> Iterator[dict]:
        ext = path.suffix.lower()
        text = (_summarize_netcdf(path) if ext == ".nc" else _summarize_hdf5(path))
        if text is None or len(text) < MIN_LEN:
            text = (
                f"Scientific data file: {path.name} ({ext.lstrip('.')}, "
                f"{path.stat().st_size // 1024} KB). "
                f"Schema extraction unavailable (missing h5py/netCDF4 or unreadable)."
            )
            chunk_type = "metadata_only"
        else:
            chunk_type = "schema"
        yield {
            "id": f"{base_id}-sci",
            "text": text,
            "format": "pretrain",
            "metadata": {
                "source_file": str(path),
                "source_format": "h5" if ext in (".h5", ".hdf5") else "netcdf",
                "section": section,
                "doc_title": path.stem,
                "chunk_type": chunk_type,
                "chunk_idx": 0,
                "char_count": len(text),
            },
        }


PLUGIN = _ScientificPlugin()
