"""
3D mesh metadata plugin — STL / VTP / OBJ / PLY.

These files have NO extractable prose text, but we don't want to silently
drop them either. This plugin emits one sparse metadata chunk per file
containing filename + face/vertex counts + header comments / material refs.
chunk_type="metadata_only" lets forge-audit filter them if the operator
wants a dense training corpus.
"""
from __future__ import annotations

import re
import struct
import sys
from pathlib import Path
from typing import Iterator


def _stl_info(path: Path) -> dict:
    """Return info dict. STL has two variants: ASCII (first line 'solid <name>')
    and binary (80-byte header, uint32 face count, 50 bytes per face).
    """
    info: dict = {"format_variant": None}
    try:
        with open(path, "rb") as f:
            head = f.read(80)
        # ASCII STL?
        if head.lstrip()[:5].lower() == b"solid":
            # Read first line for name
            first_line = head.split(b"\n", 1)[0].decode("ascii", errors="replace").strip()
            info["format_variant"] = "ascii"
            info["solid_name"] = first_line[len("solid "):].strip() if " " in first_line else ""
            # Face count — slow: count occurrences of 'facet normal' in the file
            try:
                with open(path, "r", encoding="ascii", errors="replace") as f2:
                    faces = sum(1 for line in f2 if line.strip().startswith("facet normal"))
                info["faces"] = faces
            except Exception:
                pass
        else:
            info["format_variant"] = "binary"
            with open(path, "rb") as f:
                f.seek(80)
                count_bytes = f.read(4)
                if len(count_bytes) == 4:
                    info["faces"] = struct.unpack("<I", count_bytes)[0]
                # First 80 bytes are a header — sometimes has comment text
                header_text = head.decode("ascii", errors="replace").strip("\x00 \t\r\n")
                if header_text:
                    info["header_text"] = header_text[:120]
    except Exception as e:
        info["error"] = f"{type(e).__name__}: {e}"
    return info


def _obj_info(path: Path) -> dict:
    """Parse .obj header: comment lines + mtllib refs + v/f count."""
    info: dict = {}
    try:
        comments, mtllibs, v, f = [], [], 0, 0
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("#"):
                    c = line.lstrip("# ").strip()
                    if c and len(comments) < 5:
                        comments.append(c)
                elif line.startswith("mtllib "):
                    mtllibs.append(line.strip().split(" ", 1)[1])
                elif line.startswith("v "):
                    v += 1
                elif line.startswith("f "):
                    f += 1
        if comments:
            info["comments"] = comments
        if mtllibs:
            info["material_libraries"] = mtllibs
        info["vertices"] = v
        info["faces"] = f
    except Exception as e:
        info["error"] = f"{type(e).__name__}: {e}"
    return info


def _ply_info(path: Path) -> dict:
    """Parse PLY header (ASCII or binary — header is always ASCII until 'end_header')."""
    info: dict = {}
    try:
        elements = []
        comments = []
        with open(path, "rb") as f:
            while True:
                line = f.readline()
                if not line:
                    break
                s = line.decode("ascii", errors="replace").strip()
                if s == "end_header":
                    break
                if s.startswith("comment "):
                    comments.append(s[len("comment "):])
                elif s.startswith("element "):
                    parts = s.split()
                    if len(parts) >= 3:
                        elements.append({"name": parts[1], "count": int(parts[2])})
        if comments:
            info["comments"] = comments[:5]
        if elements:
            info["elements"] = elements
    except Exception as e:
        info["error"] = f"{type(e).__name__}: {e}"
    return info


def _vtp_info(path: Path) -> dict:
    """VTP is XML — peek the first ~4KB for Piece element with NumberOfPoints/Cells."""
    info: dict = {}
    try:
        head = path.read_bytes()[:4096].decode("utf-8", errors="replace")
        m = re.search(r'NumberOfPoints="(\d+)"', head)
        if m:
            info["points"] = int(m.group(1))
        m = re.search(r'NumberOfCells="(\d+)"', head)
        if m:
            info["cells"] = int(m.group(1))
        m = re.search(r'NumberOfVerts="(\d+)"', head)
        if m:
            info["verts"] = int(m.group(1))
    except Exception as e:
        info["error"] = f"{type(e).__name__}: {e}"
    return info


class _MeshMetadataPlugin:
    extensions = (".stl", ".vtp", ".obj", ".ply")
    source_format = "mesh_metadata"
    requires = ()
    system_deps = ()
    default_on = True
    disable_env = "FORGE_DISABLE_MESH"

    def iter_chunks(self, path: Path, section: str, base_id: str, options: dict) -> Iterator[dict]:
        ext = path.suffix.lower()
        try:
            if ext == ".stl":
                info = _stl_info(path)
            elif ext == ".obj":
                info = _obj_info(path)
            elif ext == ".ply":
                info = _ply_info(path)
            elif ext == ".vtp":
                info = _vtp_info(path)
            else:
                return
        except Exception as e:
            sys.stderr.write(f"  [{path}: {type(e).__name__}: {e}]\n")
            return

        try:
            size_kb = max(1, path.stat().st_size // 1024)
        except Exception:
            size_kb = 0

        info_pieces = [f"{k}: {v}" for k, v in info.items() if v and k != "error"]
        info_str = " | ".join(info_pieces) if info_pieces else "(no header info)"

        text = (
            f"3D mesh file: {path.name} "
            f"({ext.lstrip('.')} format, {size_kb} KB). "
            f"Metadata: {info_str}. "
            f"No extractable prose text (geometry only)."
        )

        yield {
            "id": f"{base_id}-meshmeta",
            "text": text,
            "format": "pretrain",
            "metadata": {
                "source_file": str(path),
                "source_format": ext.lstrip("."),
                "section": section,
                "doc_title": path.stem,
                "chunk_type": "metadata_only",
                "chunk_idx": 0,
                "char_count": len(text),
                "mesh_info": info,
                "file_size_kb": size_kb,
            },
        }


PLUGIN = _MeshMetadataPlugin()
