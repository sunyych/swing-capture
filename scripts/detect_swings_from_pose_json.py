#!/usr/bin/env python3
"""Detect golf-like swing moments from a `.pose.json` file (streaming).

Heuristic: both wrists move quickly across the frame (large horizontal velocity
of the midpoint between left_wrist and right_wrist), combined with high
instantaneous 2D wrist speed. Peaks are merged with a minimum spacing so one
practice swing tends to produce one event.

Outputs a small JSON manifest (timestamps / frame indices). Optionally slices
the source video into per-swing clips with ffmpeg.

Dependencies: ijson (see scripts/requirements-pose.txt). OpenCV only needed
if you use --preview (draw markers on a short excerpt).
"""

from __future__ import annotations

import argparse
import json
import math
import re
import subprocess
import sys
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Deque, Dict, List, Optional, Tuple

import ijson

_SCRIPTS_DIR = Path(__file__).resolve().parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))
from pose_cli_progress import ThrottledFrameProgress  # noqa: E402


MIN_VIS = 0.35

_META_RE_FPS = re.compile(r'"fps"\s*:\s*([0-9.eE+-]+)')
_META_RE_SRC = re.compile(r'"source_video"\s*:\s*"([^"]*)"')


def sniff_pose_meta(path: Path) -> Tuple[float, Optional[str]]:
    """Read `fps` and `source_video` from the first chunk of the file (fast).

    The full JSON can be gigabytes; we must not parse the whole object just to
    read header fields that appear before the `frames` array.
    """
    chunk = path.read_bytes()[:262144]
    text = chunk.decode("utf-8", errors="ignore")
    m = _META_RE_FPS.search(text)
    fps = float(m.group(1)) if m else 30.0
    m2 = _META_RE_SRC.search(text)
    src = m2.group(1) if m2 else None
    return fps, src


@dataclass
class FrameKinematics:
    frame_index: int
    timestamp_ms: float
    mid_x: float
    vx: float  # normalized coords per second; 0 if not computable
    mean_wrist_speed: float  # 2D, normalized / sec


def _landmark_xy_vis(lm: Dict[str, Any], name: str) -> Optional[Tuple[float, float, float]]:
    block = lm.get(name)
    if not isinstance(block, dict):
        return None
    try:
        x = float(block["x"])
        y = float(block["y"])
        vis = float(block.get("visibility", 0.0))
    except (KeyError, TypeError, ValueError):
        return None
    return x, y, vis


def _point_speed(
    cur: Optional[Tuple[float, float, float]],
    prev: Optional[Tuple[float, float, float]],
    ts: float,
    prev_ts: Optional[float],
) -> float:
    if cur is None or prev is None or prev_ts is None or ts <= prev_ts:
        return 0.0
    dt = (ts - prev_ts) / 1000.0
    if dt <= 0.0:
        return 0.0
    dx = cur[0] - prev[0]
    dy = cur[1] - prev[1]
    return math.hypot(dx, dy) / dt


def _percentile_nearest_rank(values: List[float], p: float) -> float:
    if not values:
        return 0.0
    if p <= 0:
        return min(values)
    if p >= 100:
        return max(values)
    s = sorted(values)
    # Nearest-rank definition (inclusive).
    k = max(0, min(len(s) - 1, int(math.ceil(p / 100.0 * len(s)) - 1)))
    return s[k]


def _moving_average(values: List[float], window: int) -> List[float]:
    w = max(1, window)
    out: List[float] = []
    q: Deque[float] = deque()
    s = 0.0
    for v in values:
        q.append(v)
        s += v
        if len(q) > w:
            s -= q.popleft()
        out.append(s / len(q))
    return out


def _greedy_peaks(signal: List[float], min_height: float, min_sep: int) -> List[int]:
    candidates = [i for i, v in enumerate(signal) if v >= min_height]
    candidates.sort(key=lambda i: signal[i], reverse=True)
    picked: List[int] = []
    for i in candidates:
        if any(abs(i - j) < min_sep for j in picked):
            continue
        picked.append(i)
    picked.sort()
    return picked


def _expand_segment(
    center: int,
    signal: List[float],
    floor_frac: float,
) -> Tuple[int, int]:
    peak = signal[center]
    thresh = max(peak * floor_frac, 1e-9)
    left = center
    while left > 0 and signal[left - 1] >= thresh:
        left -= 1
    right = center
    n = len(signal)
    while right + 1 < n and signal[right + 1] >= thresh:
        right += 1
    return left, right


def stream_kinematics(pose_json: Path) -> List[FrameKinematics]:
    rows: List[FrameKinematics] = []
    prev_ts: Optional[float] = None
    prev_mid_x: Optional[float] = None
    prev_lw: Optional[Tuple[float, float, float]] = None
    prev_rw: Optional[Tuple[float, float, float]] = None

    with pose_json.open("rb") as f:
        progress = ThrottledFrameProgress(0, "scan pose json")
        for frame in ijson.items(f, "frames.item"):
            progress.tick(len(rows) + 1)
            frame_index = int(frame.get("frame_index", len(rows)))
            ts = float(frame["timestamp_ms"])
            lm = frame.get("landmarks") or {}
            lw = _landmark_xy_vis(lm, "left_wrist")
            rw = _landmark_xy_vis(lm, "right_wrist")

            vx = 0.0
            mean_speed = 0.0
            mid_x = 0.0

            if (
                lw is not None
                and rw is not None
                and lw[2] >= MIN_VIS
                and rw[2] >= MIN_VIS
            ):
                mid_x = (lw[0] + rw[0]) / 2.0
                sl = _point_speed(lw, prev_lw, ts, prev_ts)
                sr = _point_speed(rw, prev_rw, ts, prev_ts)
                mean_speed = (sl + sr) / 2.0
                if prev_mid_x is not None and prev_ts is not None and ts > prev_ts:
                    dt = (ts - prev_ts) / 1000.0
                    if dt > 0.0:
                        vx = (mid_x - prev_mid_x) / dt
                prev_mid_x = mid_x
                prev_ts = ts
                prev_lw, prev_rw = lw, rw
            else:
                # Break the derivative chain on dropout.
                prev_mid_x = None
                prev_ts = ts
                prev_lw = None
                prev_rw = None

            rows.append(
                FrameKinematics(
                    frame_index=frame_index,
                    timestamp_ms=ts,
                    mid_x=mid_x,
                    vx=vx,
                    mean_wrist_speed=mean_speed,
                )
            )
        progress.finish(len(rows))

    return rows


def build_swing_signal(
    rows: List[FrameKinematics],
    smooth_window: int,
) -> Tuple[List[float], List[float], List[float]]:
    vx_raw = [r.vx for r in rows]
    sp_raw = [r.mean_wrist_speed for r in rows]
    vx_s = _moving_average(vx_raw, smooth_window)
    sp_s = _moving_average(sp_raw, smooth_window)
    # Emphasize lateral burst while still requiring overall hand speed.
    score = [abs(a) * math.sqrt(max(b, 1e-9)) for a, b in zip(vx_s, sp_s)]
    return vx_s, sp_s, score


def detect_swings(
    rows: List[FrameKinematics],
    *,
    smooth_window: int,
    score_percentile: float,
    min_sep_frames: int,
    segment_floor_frac: float,
) -> List[Dict[str, Any]]:
    vx_s, sp_s, score = build_swing_signal(rows, smooth_window)
    min_height = _percentile_nearest_rank(score, score_percentile)
    peaks = _greedy_peaks(score, min_height=min_height, min_sep=min_sep_frames)
    events: List[Dict[str, Any]] = []
    for peak_i in peaks:
        lo, hi = _expand_segment(peak_i, score, segment_floor_frac)
        start = rows[lo]
        peak_row = rows[peak_i]
        end = rows[hi]
        # Direction from smoothed vx near peak (image coords: +x = camera right).
        win_lo = max(0, peak_i - 3)
        win_hi = min(len(vx_s), peak_i + 4)
        mean_vx = sum(vx_s[j] for j in range(win_lo, win_hi)) / max(1, win_hi - win_lo)
        direction = "left_to_right" if mean_vx >= 0.0 else "right_to_left"
        events.append(
            {
                "start_frame": start.frame_index,
                "end_frame": end.frame_index,
                "peak_frame": peak_row.frame_index,
                "start_ms": round(start.timestamp_ms, 2),
                "end_ms": round(end.timestamp_ms, 2),
                "peak_ms": round(peak_row.timestamp_ms, 2),
                "direction": direction,
                "peak_score": round(score[peak_i], 6),
                "peak_abs_vx": round(abs(vx_s[peak_i]), 6),
                "peak_mean_wrist_speed": round(sp_s[peak_i], 6),
            }
        )
    return events


def _which_ffmpeg() -> str:
    return "ffmpeg"


def extract_clips(
    video: Path,
    events: List[Dict[str, Any]],
    out_dir: Path,
    *,
    pad_before_ms: float,
    pad_after_ms: float,
) -> List[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    ffmpeg = _which_ffmpeg()
    written: List[Path] = []
    for idx, ev in enumerate(events, start=1):
        start_ms = float(ev["start_ms"]) - pad_before_ms
        end_ms = float(ev["end_ms"]) + pad_after_ms
        if start_ms < 0:
            start_ms = 0.0
        dur_ms = max(0.0, end_ms - start_ms)
        dur_s = dur_ms / 1000.0
        start_s = start_ms / 1000.0
        out_path = out_dir / f"swing_{idx:04d}_{ev['peak_frame']}.mp4"
        cmd = [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-ss",
            f"{start_s:.3f}",
            "-i",
            str(video),
            "-t",
            f"{dur_s:.3f}",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "20",
            "-c:a",
            "aac",
            "-movflags",
            "+faststart",
            str(out_path),
        ]
        subprocess.run(cmd, check=True)
        written.append(out_path)
    return written


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("pose_json", type=Path, help="Path to `.pose.json` from extract_pose_from_video.py")
    p.add_argument(
        "--source-video",
        type=Path,
        default=None,
        help="Override video path for manifest / clipping (default: source_video in JSON).",
    )
    p.add_argument(
        "--out-json",
        type=Path,
        default=None,
        help="Output manifest JSON. Default: <stem>.swings.json beside the pose json.",
    )
    p.add_argument(
        "--smooth-window",
        type=int,
        default=5,
        help="Moving-average window for vx / wrist speed (frames).",
    )
    p.add_argument(
        "--score-percentile",
        type=float,
        default=99.5,
        help="Keep peaks above this percentile of (|vx_sma| * sqrt(wrist_speed_sma)).",
    )
    p.add_argument(
        "--min-sep-frames",
        type=int,
        default=45,
        help="Minimum frames between detected swing peaks (~1.5s at 30fps).",
    )
    p.add_argument(
        "--segment-floor-frac",
        type=float,
        default=0.25,
        help="When expanding a segment, stop when score drops below this fraction of peak.",
    )
    p.add_argument(
        "--extract-clips",
        action="store_true",
        help="Slice the source video into one MP4 per swing (requires ffmpeg in PATH).",
    )
    p.add_argument(
        "--clips-dir",
        type=Path,
        default=None,
        help="Directory for extracted clips. Default: <stem>_swings_clips beside pose json.",
    )
    p.add_argument(
        "--pad-before-ms",
        type=float,
        default=1000.0,
        help="Extra time before segment start when clipping (default: 1000 ms = 1 s).",
    )
    p.add_argument(
        "--pad-after-ms",
        type=float,
        default=1000.0,
        help="Extra time after segment end when clipping (default: 1000 ms = 1 s).",
    )
    return p.parse_args()


def main() -> None:
    args = parse_args()
    pose_json = args.pose_json.expanduser().resolve()
    if not pose_json.exists():
        raise SystemExit(f"pose json not found: {pose_json}")

    print("Streaming pose JSON (one pass)...", file=sys.stderr, flush=True)
    fps, source_sniff = sniff_pose_meta(pose_json)
    rows = stream_kinematics(pose_json)
    if not rows:
        raise SystemExit("no frames in pose json")

    events = detect_swings(
        rows,
        smooth_window=max(1, args.smooth_window),
        score_percentile=float(args.score_percentile),
        min_sep_frames=max(1, args.min_sep_frames),
        segment_floor_frac=float(args.segment_floor_frac),
    )

    source_video = args.source_video
    if source_video is None and source_sniff:
        source_video = Path(source_sniff)

    manifest: Dict[str, Any] = {
        "pose_json": str(pose_json),
        "source_video": str(source_video) if source_video else None,
        "fps": fps,
        "processed_frames": len(rows),
        "swing_count": len(events),
        "params": {
            "smooth_window": int(args.smooth_window),
            "score_percentile": float(args.score_percentile),
            "min_sep_frames": int(args.min_sep_frames),
            "segment_floor_frac": float(args.segment_floor_frac),
            "min_wrist_visibility": MIN_VIS,
        },
        "swings": events,
    }

    out_json = args.out_json
    if out_json is None:
        stem = pose_json.name
        if stem.endswith(".pose.json"):
            stem = stem[: -len(".pose.json")]
        else:
            stem = pose_json.stem
        out_json = pose_json.parent / f"{stem}.swings.json"

    out_json = out_json.expanduser().resolve()
    out_json.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"Wrote manifest: {out_json} ({len(events)} swings)", file=sys.stderr, flush=True)

    if args.extract_clips:
        if not source_video or not Path(source_video).exists():
            raise SystemExit("extract-clips requires a valid source_video path")
        clips_dir = args.clips_dir
        if clips_dir is None:
            stem = pose_json.name
            if stem.endswith(".pose.json"):
                stem = stem[: -len(".pose.json")]
            else:
                stem = pose_json.stem
            clips_dir = pose_json.parent / f"{stem}_swings_clips"
        paths = extract_clips(
            Path(source_video),
            events,
            clips_dir.expanduser().resolve(),
            pad_before_ms=float(args.pad_before_ms),
            pad_after_ms=float(args.pad_after_ms),
        )
        print(f"Extracted {len(paths)} clips under: {clips_dir}", file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
