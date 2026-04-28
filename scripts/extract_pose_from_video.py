#!/usr/bin/env python3
"""Extract pose keypoints and upper-body swing features from a local video.

This script is intentionally desktop-first: you give it a video file and it
produces:
1. a JSON file with frame-by-frame pose landmarks
2. a CSV file with upper-body motion features
3. an optional annotated MP4 overlay for visual inspection

The implementation uses MediaPipe Pose because it is a stable off-the-shelf
pose extractor for offline video processing. In this project, MLX is a better
fit for downstream swing classification over extracted pose sequences rather
than for the initial landmark extraction step.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

import cv2
import mediapipe as mp

_SCRIPTS_DIR = Path(__file__).resolve().parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))
from pose_cli_progress import ThrottledFrameProgress  # noqa: E402


mp_pose = mp.solutions.pose
mp_drawing = mp.solutions.drawing_utils


UPPER_BODY_LANDMARKS = {
    "nose": mp_pose.PoseLandmark.NOSE,
    "left_shoulder": mp_pose.PoseLandmark.LEFT_SHOULDER,
    "right_shoulder": mp_pose.PoseLandmark.RIGHT_SHOULDER,
    "left_elbow": mp_pose.PoseLandmark.LEFT_ELBOW,
    "right_elbow": mp_pose.PoseLandmark.RIGHT_ELBOW,
    "left_wrist": mp_pose.PoseLandmark.LEFT_WRIST,
    "right_wrist": mp_pose.PoseLandmark.RIGHT_WRIST,
    "left_hip": mp_pose.PoseLandmark.LEFT_HIP,
    "right_hip": mp_pose.PoseLandmark.RIGHT_HIP,
}


@dataclass(frozen=True)
class LandmarkPoint:
    x: float
    y: float
    z: float
    visibility: float
    presence: float


@dataclass(frozen=True)
class ExtractionResult:
    video_path: Path
    json_path: Path
    csv_path: Path
    overlay_path: Optional[Path]
    processed_frames: int
    fps: float
    frame_count: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract pose keypoints and upper-body swing features from a video.",
    )
    parser.add_argument("video", type=Path, help="Path to the input video file.")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("artifacts/pose"),
        help="Directory where JSON/CSV/overlay outputs will be written.",
    )
    parser.add_argument(
        "--model-complexity",
        type=int,
        choices=(0, 1, 2),
        default=1,
        help="MediaPipe Pose model complexity. 0 is fastest, 2 is most accurate.",
    )
    parser.add_argument(
        "--min-detection-confidence",
        type=float,
        default=0.5,
        help="Minimum initial pose detection confidence.",
    )
    parser.add_argument(
        "--min-tracking-confidence",
        type=float,
        default=0.5,
        help="Minimum tracking confidence across frames.",
    )
    parser.add_argument(
        "--sample-every",
        type=int,
        default=1,
        help="Only process every Nth frame. 1 means process all frames.",
    )
    parser.add_argument(
        "--save-overlay",
        action="store_true",
        help=(
            "Write <stem>.overlay.mp4 under --out-dir. Omit if you will use "
            "scripts/render_pose_json_on_video.py instead (same default path, "
            "drawn from the JSON overlay for one preview file)."
        ),
    )
    parser.add_argument(
        "--smooth-window",
        type=int,
        default=5,
        help="Rolling window used for wrist speed smoothing in the CSV output.",
    )
    return parser.parse_args()


def extract_pose_from_video(
    *,
    video_path: Path,
    out_dir: Path,
    model_complexity: int = 1,
    min_detection_confidence: float = 0.5,
    min_tracking_confidence: float = 0.5,
    sample_every: int = 1,
    save_overlay: bool = False,
    smooth_window: int = 5,
) -> ExtractionResult:
    video_path = video_path.expanduser().resolve()
    if not video_path.exists():
        raise SystemExit(f"Video not found: {video_path}")

    out_dir = out_dir.expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = video_path.stem
    json_path = out_dir / f"{stem}.pose.json"
    csv_path = out_dir / f"{stem}.features.csv"
    overlay_path = out_dir / f"{stem}.overlay.mp4"

    capture = cv2.VideoCapture(str(video_path))
    if not capture.isOpened():
        raise SystemExit(f"Unable to open video: {video_path}")

    fps = capture.get(cv2.CAP_PROP_FPS) or 30.0
    frame_count = int(capture.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    frame_width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
    frame_height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)

    overlay_writer = None
    if save_overlay:
        fourcc = cv2.VideoWriter_fourcc(*"mp4v")
        overlay_writer = cv2.VideoWriter(
            str(overlay_path),
            fourcc,
            fps,
            (frame_width, frame_height),
        )

    frames: List[dict] = []
    rows: List[dict] = []
    last_frame_landmarks: Optional[Dict[str, LandmarkPoint]] = None
    last_timestamp_ms: Optional[float] = None
    wrist_speed_history: List[float] = []

    read_idx = 0
    progress = ThrottledFrameProgress(
        frame_count if frame_count > 0 else 0,
        "extract pose",
    )

    with mp_pose.Pose(
        static_image_mode=False,
        model_complexity=model_complexity,
        enable_segmentation=False,
        smooth_landmarks=True,
        min_detection_confidence=min_detection_confidence,
        min_tracking_confidence=min_tracking_confidence,
    ) as pose:
        frame_index = 0
        processed_count = 0

        while True:
            ok, frame_bgr = capture.read()
            if not ok:
                break

            read_idx += 1
            progress.tick(read_idx)

            timestamp_ms = (frame_index / fps) * 1000.0
            if frame_index % sample_every != 0:
                frame_index += 1
                continue

            frame_rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
            result = pose.process(frame_rgb)

            landmarks = (
                convert_landmarks(result.pose_landmarks.landmark)
                if result.pose_landmarks
                else {}
            )

            feature_row = build_feature_row(
                frame_index=frame_index,
                timestamp_ms=timestamp_ms,
                landmarks=landmarks,
                previous_landmarks=last_frame_landmarks,
                previous_timestamp_ms=last_timestamp_ms,
                wrist_speed_history=wrist_speed_history,
                smooth_window=max(1, smooth_window),
            )
            rows.append(feature_row)

            frames.append(
                {
                    "frame_index": frame_index,
                    "timestamp_ms": timestamp_ms,
                    "landmarks": {
                        name: {
                            "x": point.x,
                            "y": point.y,
                            "z": point.z,
                            "visibility": point.visibility,
                            "presence": point.presence,
                        }
                        for name, point in landmarks.items()
                    },
                }
            )

            if overlay_writer is not None:
                annotated = frame_bgr.copy()
                if result.pose_landmarks:
                    mp_drawing.draw_landmarks(
                        annotated,
                        result.pose_landmarks,
                        mp_pose.POSE_CONNECTIONS,
                    )
                    draw_upper_body_metrics(annotated, feature_row)
                overlay_writer.write(annotated)

            last_frame_landmarks = landmarks or None
            last_timestamp_ms = timestamp_ms
            processed_count += 1
            frame_index += 1

    progress.finish(read_idx)
    capture.release()
    if overlay_writer is not None:
        overlay_writer.release()

    print("Writing pose JSON and CSV...", file=sys.stderr, flush=True)

    payload = {
        "source_video": str(video_path),
        "fps": fps,
        "frame_count": frame_count,
        "frame_size": {"width": frame_width, "height": frame_height},
        "processed_frames": len(frames),
        "landmarks": list(UPPER_BODY_LANDMARKS.keys()),
        "frames": frames,
    }
    json_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    write_csv(csv_path, rows)

    print(f"Pose JSON written to: {json_path}")
    print(f"Feature CSV written to: {csv_path}")
    if overlay_writer is not None:
        print(f"Overlay video written to: {overlay_path}")
    print(f"Processed {processed_count} sampled frames from {video_path.name}")

    return ExtractionResult(
        video_path=video_path,
        json_path=json_path,
        csv_path=csv_path,
        overlay_path=overlay_path if save_overlay else None,
        processed_frames=processed_count,
        fps=fps,
        frame_count=frame_count,
    )


def main() -> None:
    args = parse_args()
    extract_pose_from_video(
        video_path=args.video,
        out_dir=args.out_dir,
        model_complexity=args.model_complexity,
        min_detection_confidence=args.min_detection_confidence,
        min_tracking_confidence=args.min_tracking_confidence,
        sample_every=args.sample_every,
        save_overlay=args.save_overlay,
        smooth_window=args.smooth_window,
    )


def convert_landmarks(
    raw_landmarks: Iterable[mp.framework.formats.landmark_pb2.NormalizedLandmark],
) -> Dict[str, LandmarkPoint]:
    raw_list = list(raw_landmarks)
    converted: Dict[str, LandmarkPoint] = {}
    for name, landmark_enum in UPPER_BODY_LANDMARKS.items():
      landmark = raw_list[landmark_enum.value]
      converted[name] = LandmarkPoint(
          x=float(landmark.x),
          y=float(landmark.y),
          z=float(landmark.z),
          visibility=float(getattr(landmark, "visibility", 0.0)),
          presence=float(getattr(landmark, "presence", 0.0)),
      )
    return converted


def build_feature_row(
    *,
    frame_index: int,
    timestamp_ms: float,
    landmarks: Dict[str, LandmarkPoint],
    previous_landmarks: Optional[Dict[str, LandmarkPoint]],
    previous_timestamp_ms: Optional[float],
    wrist_speed_history: List[float],
    smooth_window: int,
) -> dict:
    shoulder_angle = segment_angle(
        landmarks.get("left_shoulder"),
        landmarks.get("right_shoulder"),
    )
    hip_angle = segment_angle(
        landmarks.get("left_hip"),
        landmarks.get("right_hip"),
    )
    torso_separation = shoulder_angle - hip_angle

    left_wrist_speed = point_speed(
        landmarks.get("left_wrist"),
        previous_landmarks.get("left_wrist") if previous_landmarks else None,
        timestamp_ms,
        previous_timestamp_ms,
    )
    right_wrist_speed = point_speed(
        landmarks.get("right_wrist"),
        previous_landmarks.get("right_wrist") if previous_landmarks else None,
        timestamp_ms,
        previous_timestamp_ms,
    )
    mean_wrist_speed = mean([left_wrist_speed, right_wrist_speed])
    wrist_speed_history.append(mean_wrist_speed)
    if len(wrist_speed_history) > smooth_window:
        del wrist_speed_history[0]

    shoulder_center = midpoint(
        landmarks.get("left_shoulder"),
        landmarks.get("right_shoulder"),
    )
    wrist_center = midpoint(
        landmarks.get("left_wrist"),
        landmarks.get("right_wrist"),
    )
    hands_to_torso = point_distance(shoulder_center, wrist_center)
    upper_body_presence = mean(
        [
            point.visibility
            for point in landmarks.values()
        ]
    )

    return {
        "frame_index": frame_index,
        "timestamp_ms": round(timestamp_ms, 2),
        "upper_body_presence": round(upper_body_presence, 4),
        "shoulder_angle_deg": round(math.degrees(shoulder_angle), 4),
        "hip_angle_deg": round(math.degrees(hip_angle), 4),
        "torso_separation_deg": round(math.degrees(torso_separation), 4),
        "left_wrist_speed": round(left_wrist_speed, 5),
        "right_wrist_speed": round(right_wrist_speed, 5),
        "mean_wrist_speed": round(mean_wrist_speed, 5),
        "smoothed_wrist_speed": round(mean(wrist_speed_history), 5),
        "hands_to_torso_distance": round(hands_to_torso, 5),
    }


def draw_upper_body_metrics(frame: cv2.typing.MatLike, feature_row: dict) -> None:
    lines = [
        f"torso sep: {feature_row['torso_separation_deg']:.1f} deg",
        f"wrist speed: {feature_row['smoothed_wrist_speed']:.3f}",
        f"hands->torso: {feature_row['hands_to_torso_distance']:.3f}",
    ]
    y = 28
    for line in lines:
        cv2.putText(
            frame,
            line,
            (16, y),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.7,
            (0, 255, 255),
            2,
            cv2.LINE_AA,
        )
        y += 28


def write_csv(path: Path, rows: List[dict]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return

    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def midpoint(
    a: Optional[LandmarkPoint],
    b: Optional[LandmarkPoint],
) -> Optional[Tuple[float, float]]:
    if a is None or b is None:
        return None
    return ((a.x + b.x) / 2.0, (a.y + b.y) / 2.0)


def point_distance(
    a: Optional[Tuple[float, float]],
    b: Optional[Tuple[float, float]],
) -> float:
    if a is None or b is None:
        return 0.0
    dx = b[0] - a[0]
    dy = b[1] - a[1]
    return math.sqrt(dx * dx + dy * dy)


def segment_angle(
    a: Optional[LandmarkPoint],
    b: Optional[LandmarkPoint],
) -> float:
    if a is None or b is None:
        return 0.0
    return math.atan2(b.y - a.y, b.x - a.x)


def point_speed(
    current: Optional[LandmarkPoint],
    previous: Optional[LandmarkPoint],
    timestamp_ms: float,
    previous_timestamp_ms: Optional[float],
) -> float:
    if (
        current is None
        or previous is None
        or previous_timestamp_ms is None
        or timestamp_ms <= previous_timestamp_ms
    ):
        return 0.0

    dt = (timestamp_ms - previous_timestamp_ms) / 1000.0
    if dt <= 0:
        return 0.0

    dx = current.x - previous.x
    dy = current.y - previous.y
    return math.sqrt(dx * dx + dy * dy) / dt


def mean(values: Iterable[float]) -> float:
    values_list = list(values)
    if not values_list:
        return 0.0
    return sum(values_list) / len(values_list)


if __name__ == "__main__":
    main()
