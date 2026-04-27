"""
Geo plugin — .geojson and .shp (ESRI shapefile).

GeoJSON: stdlib JSON. Each Feature's properties are flattened into a
key=value text representation; geometry is summarized (type + coord
count). One chunk per feature.

Shapefiles need pyshp (`shapefile` module). One chunk per record,
attribute table flattened. Geometry summarized similarly.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Iterator

from .orchestration_helpers import MIN_LEN


def _summarize_geom(geom: dict) -> str:
    if not isinstance(geom, dict):
        return ""
    g_type = geom.get("type", "?")
    coords = geom.get("coordinates")
    if coords is None:
        return f"geom={g_type}"

    def _count(c):
        if isinstance(c, (int, float)):
            return 0
        if not c:
            return 0
        if isinstance(c[0], (int, float)):
            return 1
        return sum(_count(sub) for sub in c)

    return f"geom={g_type}({_count(coords)} pts)"


def _iter_geojson(path: Path, section: str, base_id: str) -> Iterator[dict]:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            data = json.load(f)
    except Exception:
        return
    features = (
        data.get("features") if data.get("type") == "FeatureCollection"
        else [data] if data.get("type") == "Feature"
        else []
    )
    for i, feat in enumerate(features):
        props = feat.get("properties", {}) or {}
        kv = "\n".join(f"{k}: {v}" for k, v in props.items() if v not in (None, ""))
        text = f"{kv}\n{_summarize_geom(feat.get('geometry', {}))}".strip()
        if len(text) < MIN_LEN:
            continue
        yield {
            "id": f"{base_id}-{i:05d}",
            "text": text,
            "format": "pretrain",
            "metadata": {
                "source_file": str(path),
                "source_format": "geojson",
                "section": section,
                "doc_title": path.stem,
                "chunk_type": "feature",
                "chunk_idx": i,
                "char_count": len(text),
            },
        }


def _iter_shapefile(path: Path, section: str, base_id: str) -> Iterator[dict]:
    try:
        import shapefile  # pyshp
    except ImportError:
        return
    try:
        sf = shapefile.Reader(str(path))
    except Exception:
        return
    field_names = [f[0] for f in sf.fields[1:]]  # skip DeletionFlag
    for i, sr in enumerate(sf.iterShapeRecords()):
        record = dict(zip(field_names, sr.record))
        kv = "\n".join(f"{k}: {v}" for k, v in record.items() if v not in (None, ""))
        shape = sr.shape.__geo_interface__ if hasattr(sr.shape, "__geo_interface__") else {}
        text = f"{kv}\n{_summarize_geom(shape)}".strip()
        if len(text) < MIN_LEN:
            continue
        yield {
            "id": f"{base_id}-{i:05d}",
            "text": text,
            "format": "pretrain",
            "metadata": {
                "source_file": str(path),
                "source_format": "shapefile",
                "section": section,
                "doc_title": path.stem,
                "chunk_type": "feature",
                "chunk_idx": i,
                "char_count": len(text),
            },
        }


class _GeoPlugin:
    extensions = (".geojson", ".shp")
    source_format = "geo"
    requires = ("pyshp",)  # only for .shp; geojson is stdlib
    system_deps = ()
    default_on = True
    disable_env = "FORGE_DISABLE_GEO"

    def iter_chunks(self, path: Path, section: str, base_id: str, options: dict) -> Iterator[dict]:
        ext = path.suffix.lower()
        if ext == ".geojson":
            yield from _iter_geojson(path, section, base_id)
        elif ext == ".shp":
            yield from _iter_shapefile(path, section, base_id)


PLUGIN = _GeoPlugin()
