"""
Video transcription plugin — MP4/MKV/MOV/AVI/WEBM via ffmpeg + faster-whisper.

Extracts the audio track via ffmpeg, then delegates to the audio plugin's
Whisper model for transcription. Same chunking strategy (Whisper segment
boundaries, ~45 sec per chunk).

Pre-filter: silent screen recordings (no audio stream) and clips below
FORGE_VIDEO_MIN_DURATION_SEC are skipped without invoking Whisper. Stops
whisper from hallucinating transcripts on UI capture videos.

System deps: ffmpeg + ffprobe
Pip deps: faster-whisper
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Iterator


def _probe_audio_duration(path: Path) -> tuple[bool, float]:
    """Return (has_audio_stream, duration_sec). Returns (False, 0.0) on probe failure."""
    try:
        a = subprocess.run(
            ["ffprobe", "-v", "quiet", "-select_streams", "a",
             "-show_entries", "stream=codec_name", "-of", "csv=p=0", str(path)],
            capture_output=True, text=True, timeout=30,
        )
        has_audio = bool(a.stdout.strip())
        d = subprocess.run(
            ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
             "-of", "csv=p=0", str(path)],
            capture_output=True, text=True, timeout=30,
        )
        dur = float(d.stdout.strip()) if d.stdout.strip() else 0.0
    except (subprocess.TimeoutExpired, ValueError, FileNotFoundError):
        return (False, 0.0)
    return (has_audio, dur)


class _VideoPlugin:
    extensions = (".mp4", ".mkv", ".mov", ".avi", ".webm", ".wmv", ".flv")
    source_format = "video"
    requires = ("faster-whisper",)
    system_deps = ("ffmpeg",)
    default_on = True
    disable_env = "FORGE_DISABLE_TRANSCRIBE"   # shared with audio.py

    def iter_chunks(self, path: Path, section: str, base_id: str, options: dict) -> Iterator[dict]:
        if not shutil.which("ffmpeg"):
            sys.stderr.write(f"  [ffmpeg not installed; skip video {path}]\n")
            return

        # Whitelist filter: skip silent + ultra-short clips. Set
        # FORGE_VIDEO_MIN_DURATION_SEC=0 / FORGE_VIDEO_REQUIRE_AUDIO=0 to disable.
        min_dur = float(os.environ.get("FORGE_VIDEO_MIN_DURATION_SEC", "120"))
        require_audio = os.environ.get("FORGE_VIDEO_REQUIRE_AUDIO", "1") == "1"
        has_audio, dur = _probe_audio_duration(path)
        if require_audio and not has_audio:
            sys.stderr.write(f"  [video {path.name}: no audio stream; skip]\n")
            return
        if dur < min_dur:
            sys.stderr.write(
                f"  [video {path.name}: duration {dur:.0f}s < {min_dur:.0f}s threshold; skip]\n"
            )
            return

        # Extract audio track to a temp WAV, then re-enter audio plugin pipeline
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp_wav = Path(tmp.name)

        try:
            # -vn: drop video, -ac 1: mono, -ar 16000: 16kHz sample rate (whisper-optimal)
            result = subprocess.run(
                ["ffmpeg", "-y", "-i", str(path), "-vn", "-ac", "1", "-ar", "16000",
                 "-f", "wav", str(tmp_wav)],
                capture_output=True, timeout=600,
            )
            if result.returncode != 0:
                sys.stderr.write(f"  [ffmpeg failed for {path}: rc={result.returncode}]\n")
                return

            # Delegate to audio plugin's transcription path (proper relative
            # import so audio.py's `.orchestration_helpers` import resolves)
            from . import audio as _audio
            audio_plugin = _audio.PLUGIN
            for chunk in audio_plugin.iter_chunks(tmp_wav, section, base_id, options):
                # Fix metadata — source file is the original video, not the tmp WAV
                chunk["metadata"]["source_file"] = str(path)
                chunk["metadata"]["source_format"] = path.suffix.lstrip(".").lower()
                chunk["metadata"]["via"] = "ffmpeg-audio-extract"
                yield chunk
        finally:
            try:
                tmp_wav.unlink()
            except FileNotFoundError:
                pass


PLUGIN = _VideoPlugin()
