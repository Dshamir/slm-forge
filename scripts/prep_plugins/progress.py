"""
Progress reporter — shared utility for long-running plugins (OCR, audio,
video transcription, MySQL revive). Emits "[<tag>] <i>/<n> · <eta>" lines
to stderr at most every 5 seconds so a 2-hour Whisper run doesn't go
silent the whole time.

Usage:
    from prep_plugins.progress import Progress

    p = Progress("ocr", total=len(images), every_seconds=5)
    for img in images:
        do_ocr(img)
        p.tick()
    p.done()

Disabled when stderr is not a tty AND $FORGE_PROGRESS != "1" — keeps
log files clean unless the operator opts in.
"""
from __future__ import annotations

import os
import sys
import time


class Progress:
    def __init__(self, tag: str, total: int | None = None,
                 every_seconds: float = 5.0):
        self.tag = tag
        self.total = total
        self.every_seconds = every_seconds
        self.count = 0
        self.start = time.time()
        self.last_emit = 0.0
        self.enabled = (
            sys.stderr.isatty()
            or os.environ.get("FORGE_PROGRESS") == "1"
        )

    def tick(self, n: int = 1) -> None:
        self.count += n
        if not self.enabled:
            return
        now = time.time()
        if now - self.last_emit < self.every_seconds:
            return
        self._emit(now)

    def _emit(self, now: float) -> None:
        elapsed = now - self.start
        if self.total and self.count > 0:
            rate = self.count / elapsed if elapsed > 0 else 0
            remaining = (self.total - self.count) / rate if rate > 0 else 0
            mins, secs = divmod(int(remaining), 60)
            hrs, mins = divmod(mins, 60)
            eta = f"{hrs:d}h{mins:02d}m" if hrs else f"{mins:d}m{secs:02d}s"
            sys.stderr.write(
                f"  [{self.tag}] {self.count}/{self.total} "
                f"({100 * self.count / self.total:.0f}%, eta {eta})\n"
            )
        else:
            sys.stderr.write(
                f"  [{self.tag}] {self.count} processed "
                f"({elapsed:.0f}s elapsed)\n"
            )
        self.last_emit = now

    def done(self) -> None:
        if not self.enabled:
            return
        elapsed = time.time() - self.start
        sys.stderr.write(
            f"  [{self.tag}] done — {self.count} items in {elapsed:.1f}s\n"
        )
