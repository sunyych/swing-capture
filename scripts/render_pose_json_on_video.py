#!/usr/bin/env python3
"""Render pose landmarks from a `.pose.json` file onto a video.

Reads JSON produced by `extract_pose_from_video.py` (normalized x/y in 0–1)
and writes an MP4 with skeleton lines, joint circles, and optional labels so
you can visually verify that the stored landmarks match the source footage.

Dependencies: OpenCV + stdlib only (no MediaPipe required).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import cv2

_SCRIPTS_DIR = Path(__file__).resolve().parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))
from pose_cli_progress import ThrottledFrameProgress  # noqa: E402

# Upper-body edges consistent with MediaPipe-style topology for the landmarks
# emitted by `extract_pose_from_video.py`.
CONNECTIONS: List[Tuple[str, str]] = [
    ("nose", "left_shoulder"),
    ("nose", "right_shoulder"),
    ("left_shoulder", "right_shoulder"),
    ("left_shoulder", "left_elbow"),
    ("left_elbow", "left_wrist"),
    ("right_shoulder", "right_elbow"),
    ("right_elbow", "right_wrist"),
    ("left_shoulder", "left_hip"),
    ("right_shoulder", "right_hip"),
    ("left_hip", "right_hip"),
]

# BGR; left-ish vs right-ish for quick reading.
LANDMARK_COLORS: Dict[str, Tuple[int, int, int]] = {
    "nose": (200, 200, 255),
    "left_shoulder": (0, 200, 0),
    "right_shoulder": (255, 100, 0),
    "left_elbow": (0, 160, 80),
    "right_elbow": (255, 140, 60),
    "left_wrist": (0, 255, 128),
    "right_wrist": (0, 128, 255),
    "left_hip": (60, 180, 60),
    "right_hip": (200, 80, 200),
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Overlay pose JSON landmarks onto a video (same default path as extract --save-overlay).",
    )
    p.add_argument("video", type=Path, help="Source video path.")
    p.add_argument(
        "pose_json",
        type=Path,
        nargs="?",
        default=None,
        help=(
            "Path to `.pose.json`. If omitted, tries: "
            "(1) <video_stem>.pose.json beside the video, "
            "(2) ./artifacts/pose/<video_stem>.pose.json from the current working directory."
        ),
    )
    p.add_argument(
        "--out",
        type=Path,
        default=None,
        help=(
            "Output MP4 path. Default: same directory as the pose JSON, "
            "<video_stem>.overlay.mp4 (overwrites extract --save-overlay output if present)."
        ),
    )
    p.add_argument(
        "--side-by-side",
        action="store_true",
        help="Output width = 2 * source: original | annotated (easier to compare).",
    )
    p.add_argument(
        "--min-visibility",
        type=float,
        default=0.0,
        help="Skip drawing a landmark if visibility is below this (0–1). Lines require both ends visible.",
    )
    p.add_argument(
        "--no-labels",
        action="store_true",
        help="Do not draw landmark name text near each joint.",
    )
    p.add_argument(
        "--point-radius",
        type=int,
        default=8,
        help="Circle radius for each joint in pixels.",
    )
    p.add_argument(
        "--line-thickness",
        type=int,
        default=3,
        help="Skeleton line thickness.",
    )
    return p.parse_args()


def load_pose_json(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if "frames" not in data:
        raise SystemExit("Invalid pose JSON: missing 'frames' array.")
    return data


def norm_to_pixel(
    x: float, y: float, width: int, height: int
) -> Tuple[int, int]:
    px = int(round(x * width))
    py = int(round(y * height))
    return px, py


def get_lm(
    landmarks: Dict[str, Any], name: str
) -> Optional[Dict[str, float]]:
    lm = landmarks.get(name)
    if not isinstance(lm, dict):
        return None
    return lm


def draw_pose_on_frame(
    frame_bgr: Any,
    landmarks: Dict[str, Any],
    *,
    min_visibility: float,
    draw_labels: bool,
    point_radius: int,
    line_thickness: int,
) -> None:
    h, w = frame_bgr.shape[:2]

    def ok(name: str) -> bool:
        lm = get_lm(landmarks, name)
        if lm is None:
            return False
        vis = float(lm.get("visibility", 0.0))
        return vis >= min_visibility

    def pt(name: str) -> Optional[Tuple[int, int]]:
        lm = get_lm(landmarks, name)
        if lm is None or not ok(name):
            return None
        return norm_to_pixel(float(lm["x"]), float(lm["y"]), w, h)

    for a, b in CONNECTIONS:
        pa, pb = pt(a), pt(b)
        if pa is None or pb is None:
            continue
        cv2.line(frame_bgr, pa, pb, (180, 180, 180), line_thickness, cv2.LINE_AA)

    for name in landmarks:
        if name not in LANDMARK_COLORS:
            continue
        p = pt(name)
        if p is None:
            continue
        color = LANDMARK_COLORS.get(name, (0, 255, 255))
        cv2.circle(frame_bgr, p, point_radius, color, -1, cv2.LINE_AA)
        cv2.circle(frame_bgr, p, point_radius + 2, (40, 40, 40), 1, cv2.LINE_AA)
        if draw_labels:
            cv2.putText(
                frame_bgr,
                name,
                (p[0] + 10, p[1] - 6),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.5,
                (0, 255, 255),
                2,
                cv2.LINE_AA,
            )


def resolve_pose_json_path(video: Path, explicit: Optional[Path]) -> Path:
    stem = video.stem
    if explicit is not None:
        p = explicit.expanduser().resolve()
        if not p.is_file():
            raise SystemExit(f"Pose JSON not found: {p}")
        return p
    candidates = [
        video.parent / f"{stem}.pose.json",
        Path.cwd() / "artifacts" / "pose" / f"{stem}.pose.json",
    ]
    for c in candidates:
        if c.is_file():
            return c.resolve()
    tried = ", ".join(str(c) for c in candidates)
    raise SystemExit(f"Pose JSON not found for '{stem}'. Tried: {tried}")


def default_out_path(
    video: Path, json_path: Path, *, side_by_side: bool
) -> Path:
    """Match `extract_pose_from_video.py` overlay naming so we do not leave a second MP4 elsewhere."""
    stem = video.stem
    if side_by_side:
        return json_path.parent / f"{stem}.overlay_compare.mp4"
    return json_path.parent / f"{stem}.overlay.mp4"


def main() -> None:
    args = parse_args()
    video_path = args.video.expanduser().resolve()
    if not video_path.exists():
        raise SystemExit(f"Video not found: {video_path}")

    json_path = resolve_pose_json_path(video_path, args.pose_json)

    out_path = args.out
    if out_path is None:
        out_path = default_out_path(
            video_path, json_path, side_by_side=args.side_by_side
        )
    else:
        out_path = out_path.expanduser().resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    payload = load_pose_json(json_path)
    frames_json: List[dict[str, Any]] = sorted(
        payload["frames"], key=lambda f: int(f["frame_index"])
    )

    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise SystemExit(f"Unable to open video: {video_path}")

    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    fw = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
    fh = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
    if fw <= 0 or fh <= 0:
        raise SystemExit("Could not read frame size from video.")

    out_w = fw * (2 if args.side_by_side else 1)
    out_h = fh
    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    writer = cv2.VideoWriter(str(out_path), fourcc, fps, (out_w, out_h))
    if not writer.isOpened():
        raise SystemExit(f"Unable to open VideoWriter for: {out_path}")

    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    progress = ThrottledFrameProgress(
        total_frames if total_frames > 0 else 0,
        "render overlay",
    )

    j_idx = 0
    current_landmarks: Dict[str, Any] = {}
    frame_i = 0
    draw_labels = not args.no_labels

    while True:
        ok, frame_bgr = cap.read()
        if not ok:
            break

        while j_idx < len(frames_json) and int(
            frames_json[j_idx]["frame_index"]
        ) <= frame_i:
            lm = frames_json[j_idx].get("landmarks")
            if isinstance(lm, dict):
                current_landmarks = lm
            j_idx += 1

        annotated = frame_bgr.copy()
        if current_landmarks:
            draw_pose_on_frame(
                annotated,
                current_landmarks,
                min_visibility=args.min_visibility,
                draw_labels=draw_labels,
                point_radius=max(1, args.point_radius),
                line_thickness=max(1, args.line_thickness),
            )

        if args.side_by_side:
            out_frame = cv2.hconcat([frame_bgr, annotated])
        else:
            out_frame = annotated

        writer.write(out_frame)
        frame_i += 1
        progress.tick(frame_i)

    progress.finish(frame_i)
    cap.release()
    writer.release()
    print(f"Wrote: {out_path}")
    print(f"  frames rendered: {frame_i}, pose keyframes in JSON: {len(frames_json)}")


if __name__ == "__main__":
    main()
