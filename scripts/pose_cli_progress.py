"""Throttled single-line progress on stderr for frame-based CLI tools."""

from __future__ import annotations

import sys
from typing import TextIO


class ThrottledFrameProgress:
    """Emit \\r-updated progress; call ``finish()`` when the frame loop ends."""

    def __init__(
        self,
        total_frames: int,
        label: str,
        *,
        stream: TextIO | None = None,
    ) -> None:
        self.total = max(0, int(total_frames))
        self.label = label.rstrip()
        self._stream = stream or sys.stderr
        if self.total > 0:
            self._step = max(1, self.total // 200)
        else:
            self._step = 500

    def tick(self, current: int) -> None:
        if current < 1:
            return
        if self.total > 0:
            if (
                current == 1
                or current % self._step == 0
                or current >= self.total
            ):
                self._emit(current)
        else:
            if current == 1 or current % self._step == 0:
                self._emit(current)

    def _emit(self, current: int) -> None:
        if self.total > 0:
            c = min(current, self.total)
            pct = 100.0 * c / self.total
            line = f"\r{self.label}  {c}/{self.total}  ({pct:.1f}%)\033[K"
        else:
            line = f"\r{self.label}  {current} frames\033[K"
        self._stream.write(line)
        self._stream.flush()

    def finish(self, final: int) -> None:
        if final < 1:
            self._stream.write(f"\r{self.label}  (no frames)\033[K\n")
            self._stream.flush()
            return
        if self.total > 0:
            c = min(final, self.total)
            pct = 100.0 * c / self.total
            line = f"\r{self.label}  {c}/{self.total}  ({pct:.1f}%)\033[K\n"
        else:
            line = f"\r{self.label}  {final} frames\033[K\n"
        self._stream.write(line)
        self._stream.flush()
