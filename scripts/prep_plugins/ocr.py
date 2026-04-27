"""
OCR plugin — image text extraction via Tesseract.

Handles PNG/JPG/JPEG/TIFF/BMP/GIF/WEBP + HEIC (via pillow-heif).

Default-on: runs automatically whenever image files are present in the
corpus. Disable per run with FORGE_DISABLE_OCR=1 if you know the images
are graphics-only (e.g. dental x-rays, 3D renderings).

System deps: tesseract-ocr (apt) + tesseract-ocr-eng.
Pip deps: pytesseract, Pillow, pillow-heif.
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Iterator

from .orchestration_helpers import clean_text


_HEIC_EXTS = (".heic", ".heif")


def _register_heif():
    """Register HEIF opener with Pillow (needs pillow-heif)."""
    try:
        from pillow_heif import register_heif_opener
        register_heif_opener()
        return True
    except ImportError:
        return False


class _OcrPlugin:
    extensions = (".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".gif", ".webp",
                  ".heic", ".heif")
    source_format = "image"
    requires = ("pytesseract", "Pillow", "pillow-heif")
    system_deps = ("tesseract-ocr",)
    default_on = True
    disable_env = "FORGE_DISABLE_OCR"

    def iter_chunks(self, path: Path, section: str, base_id: str, options: dict) -> Iterator[dict]:
        try:
            from PIL import Image
            import pytesseract
        except ImportError:
            sys.stderr.write(f"  [pytesseract/Pillow not installed; skip {path}]\n")
            return

        # HEIC/HEIF requires pillow-heif registration
        if path.suffix.lower() in _HEIC_EXTS and not _register_heif():
            sys.stderr.write(f"  [pillow-heif not installed; skip HEIC {path}]\n")
            return

        try:
            img = Image.open(path)
            # Grayscale helps tesseract accuracy on mixed-contrast images
            img = img.convert("L")
            text = pytesseract.image_to_string(img, lang=options.get("ocr_lang", "eng"))
        except Exception as e:
            sys.stderr.write(f"  [{path}: {type(e).__name__}: {e}]\n")
            return

        text = clean_text(text)
        if not text or len(text.strip()) < 10:
            # Image had no legible text — emit a sparse metadata chunk anyway
            # so the forge can report "saw 120 images, 17 had text"
            try:
                size_kb = max(1, path.stat().st_size // 1024)
            except Exception:
                size_kb = 0
            meta_text = (
                f"Image file: {path.name} "
                f"({path.suffix.lstrip('.').lower()}, {size_kb} KB). "
                f"OCR found no legible text."
            )
            yield {
                "id": f"{base_id}-imgmeta",
                "text": meta_text,
                "format": "pretrain",
                "metadata": {
                    "source_file": str(path),
                    "source_format": path.suffix.lstrip(".").lower(),
                    "section": section,
                    "doc_title": path.stem,
                    "chunk_type": "metadata_only",
                    "chunk_idx": 0,
                    "char_count": len(meta_text),
                    "ocr_attempted": True,
                    "ocr_result": "no-text",
                },
            }
            return

        yield {
            "id": f"{base_id}-ocr",
            "text": text,
            "format": "pretrain",
            "metadata": {
                "source_file": str(path),
                "source_format": path.suffix.lstrip(".").lower(),
                "section": section,
                "doc_title": path.stem,
                "chunk_type": "ocr",
                "chunk_idx": 0,
                "char_count": len(text),
                "ocr_engine": "tesseract",
            },
        }


PLUGIN = _OcrPlugin()
