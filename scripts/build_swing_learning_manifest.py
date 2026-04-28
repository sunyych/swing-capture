#!/usr/bin/env python3
"""Build training manifests from saved swing pose clips + human annotations.

This script is the glue layer for the next stages of the learning system:
1. supervised swing detection
2. reward / preference learning for swing quality
3. SFT data for a small coaching LLM
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Iterable, List


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build detection / reward / LLM manifests from pose clips.",
    )
    parser.add_argument(
        "--clips-dir",
        type=Path,
        required=True,
        help="Directory containing saved *.pose.json clip files.",
    )
    parser.add_argument(
        "--annotations-json",
        type=Path,
        required=True,
        help="Human annotation file matching the template schema.",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        required=True,
        help="Where to write manifest JSONL outputs.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    clips_dir = args.clips_dir.expanduser().resolve()
    annotations_path = args.annotations_json.expanduser().resolve()
    out_dir = args.out_dir.expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    annotations = json.loads(annotations_path.read_text(encoding="utf-8"))
    clip_annotations = {
        item["clipId"]: item
        for item in annotations.get("clips", [])
        if item.get("clipId")
    }
    pairwise_preferences = annotations.get("pairwisePreferences", [])

    pose_clips = load_pose_clips(clips_dir)
    pose_by_clip_id = {
        clip["capture"]["clipId"]: clip
        for clip in pose_clips
        if clip.get("capture", {}).get("clipId")
    }

    detection_rows = []
    llm_rows = []
    reward_rows = []

    for clip_id, annotation in clip_annotations.items():
        pose_clip = pose_by_clip_id.get(clip_id)
        if pose_clip is None:
            continue

        summary = summarize_pose_clip(pose_clip)
        base = {
            "clip_id": clip_id,
            "pose_json_path": pose_clip["__path"],
            "video_path": pose_clip.get("capture", {}).get("videoPath"),
            "summary": summary,
            "annotation": annotation,
        }

        if annotation.get("detectionLabel") is not None:
            detection_rows.append(
                {
                    **base,
                    "label": annotation["detectionLabel"],
                }
            )

        if annotation.get("coachSummary"):
            llm_rows.append(
                {
                    "clip_id": clip_id,
                    "messages": [
                        {
                            "role": "system",
                            "content": (
                                "You are a baseball swing coach. Use the structured "
                                "pose summary and manual labels to produce concise, "
                                "actionable feedback."
                            ),
                        },
                        {
                            "role": "user",
                            "content": json.dumps(
                                {
                                    "clip_id": clip_id,
                                    "summary": summary,
                                    "issues": annotation.get("issues", []),
                                    "quality_scores": annotation.get(
                                        "qualityScores",
                                        {},
                                    ),
                                    "view": annotation.get("view"),
                                },
                                ensure_ascii=False,
                            ),
                        },
                        {
                            "role": "assistant",
                            "content": annotation["coachSummary"],
                        },
                    ],
                }
            )

    for item in pairwise_preferences:
        chosen_id = item.get("chosenClipId")
        rejected_id = item.get("rejectedClipId")
        if not chosen_id or not rejected_id:
            continue
        chosen = pose_by_clip_id.get(chosen_id)
        rejected = pose_by_clip_id.get(rejected_id)
        if chosen is None or rejected is None:
            continue
        reward_rows.append(
            {
                "chosen": {
                    "clip_id": chosen_id,
                    "pose_json_path": chosen["__path"],
                    "summary": summarize_pose_clip(chosen),
                },
                "rejected": {
                    "clip_id": rejected_id,
                    "pose_json_path": rejected["__path"],
                    "summary": summarize_pose_clip(rejected),
                },
                "preference": item.get("reason", "manual_pairwise_preference"),
            }
        )

    write_jsonl(out_dir / "detection_train.jsonl", detection_rows)
    write_jsonl(out_dir / "reward_train.jsonl", reward_rows)
    write_jsonl(out_dir / "llm_sft_train.jsonl", llm_rows)

    (out_dir / "manifest_summary.json").write_text(
        json.dumps(
            {
                "clip_count": len(pose_clips),
                "annotated_clip_count": len(clip_annotations),
                "detection_rows": len(detection_rows),
                "reward_rows": len(reward_rows),
                "llm_rows": len(llm_rows),
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    print(f"detection_train.jsonl -> {out_dir / 'detection_train.jsonl'}")
    print(f"reward_train.jsonl -> {out_dir / 'reward_train.jsonl'}")
    print(f"llm_sft_train.jsonl -> {out_dir / 'llm_sft_train.jsonl'}")
    print(f"manifest_summary.json -> {out_dir / 'manifest_summary.json'}")


def load_pose_clips(clips_dir: Path) -> List[dict]:
    clips = []
    for path in sorted(clips_dir.rglob("*.pose.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        payload["__path"] = str(path)
        clips.append(payload)
    return clips


def write_jsonl(path: Path, rows: Iterable[dict]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False))
            handle.write("\n")


def summarize_pose_clip(payload: dict) -> dict:
    frames = payload.get("frames", [])
    completeness = [float(frame.get("complete", 0.0)) for frame in frames]
    left_wrist_x = series_for_landmark(frames, "leftWrist", "x")
    right_wrist_x = series_for_landmark(frames, "rightWrist", "x")
    left_shoulder_x = series_for_landmark(frames, "leftShoulder", "x")
    right_shoulder_x = series_for_landmark(frames, "rightShoulder", "x")
    left_hip_x = series_for_landmark(frames, "leftHip", "x")
    right_hip_x = series_for_landmark(frames, "rightHip", "x")

    wrist_mid_x = midpoint_series(left_wrist_x, right_wrist_x)
    shoulder_mid_x = midpoint_series(left_shoulder_x, right_shoulder_x)
    hip_mid_x = midpoint_series(left_hip_x, right_hip_x)

    return {
        "frame_count": len(frames),
        "duration_ms": payload.get("event", {}).get("durationMs", 0),
        "mean_completeness": round(mean(completeness), 4),
        "max_completeness": round(max_or_zero(completeness), 4),
        "wrist_mid_x_travel": round(travel(wrist_mid_x), 4),
        "shoulder_mid_x_travel": round(travel(shoulder_mid_x), 4),
        "hip_mid_x_travel": round(travel(hip_mid_x), 4),
        "left_wrist_x_travel": round(travel(left_wrist_x), 4),
        "right_wrist_x_travel": round(travel(right_wrist_x), 4),
    }


def series_for_landmark(
    frames: List[dict],
    landmark_name: str,
    axis: str,
) -> List[float]:
    out = []
    for frame in frames:
        landmark = frame.get("lm", {}).get(landmark_name)
        if not landmark:
            continue
        value = landmark.get(axis)
        if value is None:
            continue
        out.append(float(value))
    return out


def midpoint_series(a: List[float], b: List[float]) -> List[float]:
    if not a or not b:
        return []
    return [(x + y) / 2.0 for x, y in zip(a, b)]


def travel(values: List[float]) -> float:
    if not values:
        return 0.0
    return max(values) - min(values)


def mean(values: List[float]) -> float:
    if not values:
        return 0.0
    return sum(values) / len(values)


def max_or_zero(values: List[float]) -> float:
    if not values:
        return 0.0
    return max(values)


if __name__ == "__main__":
    main()
