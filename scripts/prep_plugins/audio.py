"""
Audio transcription plugin — MP3/WAV/M4A/FLAC/OGG/OPUS via faster-whisper.

Default-on: transcribes audio files when present. Disable per run with
FORGE_DISABLE_TRANSCRIBE=1 if the corpus has no spoken content (music,
silent scans, pure-tone audio).

Chunks transcript by Whisper segment boundaries — each segment becomes
one record with timestamp metadata.

System deps: ffmpeg
Pip deps: faster-whisper (CTranslate2 runtime; no torch required for CPU inference)
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Iterator

from .orchestration_helpers import clean_text


# Model size by options["whisper_model"] — default "base" for CPU-friendly speed.
# On a GPU instance, "large-v3" is better but 10x slower on CPU.
_DEFAULT_MODEL = "base"


# Module-level model cache — loading is expensive, reuse across files.
_cached_model = None
_cached_model_name = None


def _get_model(name: str):
    global _cached_model, _cached_model_name
    if _cached_model is not None and _cached_model_name == name:
        return _cached_model
    try:
        from faster_whisper import WhisperModel
    except ImportError:
        sys.stderr.write("  [faster-whisper not installed; skip audio]\n")
        return None
    try:
        # device="auto" falls back to CPU if no GPU available
        # compute_type int8 is faster + smaller on CPU
        _cached_model = WhisperModel(name, device="auto", compute_type="int8")
        _cached_model_name = name
        return _cached_model
    except Exception as e:
        sys.stderr.write(f"  [whisper load failed: {type(e).__name__}: {e}]\n")
        return None


class _AudioPlugin:
    extensions = (".mp3", ".wav", ".m4a", ".flac", ".ogg", ".opus", ".aac")
    source_format = "audio"
    requires = ("faster-whisper",)
    system_deps = ("ffmpeg",)
    default_on = True
    disable_env = "FORGE_DISABLE_TRANSCRIBE"

    def iter_chunks(self, path: Path, section: str, base_id: str, options: dict) -> Iterator[dict]:
        model_name = options.get("whisper_model", _DEFAULT_MODEL)
        model = _get_model(model_name)
        if model is None:
            return

        try:
            segments, info = model.transcribe(
                str(path),
                language=options.get("whisper_lang"),   # None → auto-detect
                beam_size=options.get("whisper_beam", 5),
                vad_filter=True,  # voice-activity detection skips silence
            )
        except Exception as e:
            sys.stderr.write(f"  [{path}: whisper {type(e).__name__}: {e}]\n")
            return

        # Aggregate segments into chunks of ~30-60 seconds for reasonable
        # training context. Each chunk carries its time range.
        buf_text = []
        buf_start = None
        buf_end = None
        chunk_idx = 0
        TARGET_SEC = options.get("whisper_chunk_sec", 45)

        def _flush():
            nonlocal buf_text, buf_start, buf_end, chunk_idx
            if not buf_text:
                return None
            text = clean_text(" ".join(buf_text))
            if not text:
                buf_text, buf_start, buf_end = [], None, None
                return None
            rec = {
                "id": f"{base_id}-t{chunk_idx:04d}",
                "text": text,
                "format": "pretrain",
                "metadata": {
                    "source_file": str(path),
                    "source_format": path.suffix.lstrip(".").lower(),
                    "section": section,
                    "doc_title": path.stem,
                    "chunk_type": "transcript",
                    "chunk_idx": chunk_idx,
                    "char_count": len(text),
                    "start_sec": round(buf_start, 2) if buf_start is not None else 0,
                    "end_sec": round(buf_end, 2) if buf_end is not None else 0,
                    "language": info.language if hasattr(info, "language") else "unknown",
                },
            }
            chunk_idx += 1
            buf_text, buf_start, buf_end = [], None, None
            return rec

        for seg in segments:
            if buf_start is None:
                buf_start = seg.start
            buf_end = seg.end
            buf_text.append(seg.text)
            if buf_end - buf_start >= TARGET_SEC:
                rec = _flush()
                if rec:
                    yield rec

        final = _flush()
        if final:
            yield final


PLUGIN = _AudioPlugin()
