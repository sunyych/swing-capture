#!/usr/bin/env python3
"""Build detector / quality / coaching datasets from a review workspace."""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
from typing import Iterable, List, Optional


QUALITY_KEYS = ["setup", "load", "rotation", "contact", "finish"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build learning manifests from one prepared review workspace and its labels.json.",
    )
    parser.add_argument("--review-dir", type=Path, required=True)
    parser.add_argument(
        "--labels-json",
        type=Path,
        help="Optional label file override. Defaults to <review-dir>/labels.json.",
    )
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument(
        "--min-quality-gap",
        type=float,
        default=3.0,
        help="Minimum total-score gap required before auto-generating a pairwise preference row.",
    )
    parser.add_argument(
        "--require-human-review",
        action="store_true",
        help="Build rows only from labels that were confirmed in review_recheck.html.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    review_dir = args.review_dir.expanduser().resolve()
    labels_path = (
        args.labels_json.expanduser().resolve()
        if args.labels_json
        else review_dir / "labels.json"
    )
    out_dir = args.out_dir.expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    if not labels_path.exists():
        raise SystemExit(f"Labels file not found: {labels_path}")

    manifest = json.loads((review_dir / "manifest.json").read_text(encoding="utf-8"))
    labels = json.loads(labels_path.read_text(encoding="utf-8"))

    detection_rows = []
    quality_rows = []
    llm_rows = []
    reward_rows = []
    scored_positive_samples = []
    skipped_unreviewed = 0
    skipped_missing_features = 0

    for candidate in manifest.get("candidates", []):
        label_info = labels.get(candidate["candidate_id"])
        if not isinstance(label_info, dict):
            continue

        label = label_info.get("label")
        if label not in {None, "", "skip"} and args.require_human_review and not is_human_reviewed(label_info):
            skipped_unreviewed += 1
            continue

        json_rel_path = candidate.get("json_rel_path")
        if not json_rel_path:
            continue
        candidate_json = review_dir / json_rel_path
        csv_rel_path = candidate.get("csv_rel_path")
        candidate_csv = review_dir / csv_rel_path if csv_rel_path else None
        if not candidate_json.exists():
            continue
        if not candidate_csv or not candidate_csv.exists():
            skipped_missing_features += 1
            continue

        payload = json.loads(candidate_json.read_text(encoding="utf-8"))
        rows = read_csv(candidate_csv)
        summary = summarize_candidate(payload, rows)
        base = {
            "candidate_id": candidate["candidate_id"],
            "source_id": candidate["source_id"],
            "source_name": candidate["source_name"],
            "video_path": payload.get("source_video"),
            "pose_json_path": str(candidate_json),
            "features_csv_path": str(candidate_csv),
            "summary": summary,
        }

        if label not in {None, "", "skip"}:
            detection_rows.append(
                {
                    **base,
                    "label": label,
                    "view": label_info.get("view", "unknown"),
                }
            )

        quality_scores = normalize_quality_scores(label_info.get("qualityScores"))
        issues = normalized_issue_list(label_info.get("issues"))
        coach_summary = (label_info.get("coachSummary") or "").strip()
        total_quality = sum(quality_scores.values())

        if label == manifest.get("positive_label"):
            quality_rows.append(
                {
                    **base,
                    "quality_scores": quality_scores,
                    "issues": issues,
                    "view": label_info.get("view", "unknown"),
                    "quality_total": total_quality,
                }
            )
            scored_positive_samples.append(
                {
                    **base,
                    "quality_scores": quality_scores,
                    "issues": issues,
                    "view": label_info.get("view", "unknown"),
                    "quality_total": total_quality,
                }
            )

        if label == manifest.get("positive_label") and coach_summary:
            llm_rows.append(
                {
                    "candidate_id": candidate["candidate_id"],
                    "messages": [
                        {
                            "role": "system",
                            "content": (
                                "You are a concise baseball swing coach. Read the "
                                "structured pose summary and manual labels, then give "
                                "specific and actionable improvement advice."
                            ),
                        },
                        {
                            "role": "user",
                            "content": json.dumps(
                                {
                                    "candidate_id": candidate["candidate_id"],
                                    "view": label_info.get("view", "unknown"),
                                    "summary": summary,
                                    "quality_scores": quality_scores,
                                    "issues": issues,
                                },
                                ensure_ascii=False,
                            ),
                        },
                        {
                            "role": "assistant",
                            "content": coach_summary,
                        },
                    ],
                }
            )

    reward_rows.extend(
        auto_pairwise_preferences(
            scored_positive_samples,
            min_quality_gap=args.min_quality_gap,
        )
    )

    write_jsonl(out_dir / "detection_train.jsonl", detection_rows)
    write_jsonl(out_dir / "quality_train.jsonl", quality_rows)
    write_jsonl(out_dir / "reward_train.jsonl", reward_rows)
    write_jsonl(out_dir / "llm_sft_train.jsonl", llm_rows)

    (out_dir / "manifest_summary.json").write_text(
        json.dumps(
            {
                "review_dir": str(review_dir),
                "labels_path": str(labels_path),
                "candidate_count": len(manifest.get("candidates", [])),
                "labeled_count": len([value for value in labels.values() if value.get("label")]),
                "detection_rows": len(detection_rows),
                "quality_rows": len(quality_rows),
                "reward_rows": len(reward_rows),
                "llm_rows": len(llm_rows),
                "skipped_unreviewed": skipped_unreviewed,
                "skipped_missing_features": skipped_missing_features,
            },
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    print(f"detection_train.jsonl -> {out_dir / 'detection_train.jsonl'}")
    print(f"quality_train.jsonl -> {out_dir / 'quality_train.jsonl'}")
    print(f"reward_train.jsonl -> {out_dir / 'reward_train.jsonl'}")
    print(f"llm_sft_train.jsonl -> {out_dir / 'llm_sft_train.jsonl'}")
    print(f"manifest_summary.json -> {out_dir / 'manifest_summary.json'}")
    if args.require_human_review:
        print(f"Skipped unreviewed labels: {skipped_unreviewed}")
    print(f"Skipped candidates without CSV features: {skipped_missing_features}")


def read_csv(path: Path) -> List[dict]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def write_jsonl(path: Path, rows: Iterable[dict]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False))
            handle.write("\n")


def is_human_reviewed(label_info: dict) -> bool:
    return bool(
        label_info.get("reviewedByHuman")
        or label_info.get("labelSource") == "human_review"
    )


def normalize_quality_scores(raw: Optional[dict]) -> dict:
    normalized = {}
    raw = raw or {}
    for key in QUALITY_KEYS:
        value = raw.get(key, 3)
        try:
            value = int(value)
        except (TypeError, ValueError):
            value = 3
        normalized[key] = min(5, max(1, value))
    return normalized


def normalized_issue_list(raw: object) -> List[str]:
    if not isinstance(raw, list):
        return []
    seen = set()
    issues = []
    for item in raw:
        value = str(item).strip()
        if not value or value in seen:
            continue
        seen.add(value)
        issues.append(value)
    return issues


def summarize_candidate(payload: dict, rows: List[dict]) -> dict:
    frames = payload.get("frames", [])
    timestamps = [float(frame.get("timestamp_ms", 0.0)) for frame in frames]
    left_wrist_x = landmark_series(frames, "left_wrist", "x")
    right_wrist_x = landmark_series(frames, "right_wrist", "x")
    left_wrist_y = landmark_series(frames, "left_wrist", "y")
    right_wrist_y = landmark_series(frames, "right_wrist", "y")
    shoulder_tilt = angle_series(frames, "left_shoulder", "right_shoulder")
    hip_tilt = angle_series(frames, "left_hip", "right_hip")

    csv_summary = summarize_feature_rows(rows)
    duration_ms = payload.get("window", {}).get("end_ms", 0.0) - payload.get("window", {}).get("start_ms", 0.0)
    if duration_ms <= 0 and len(timestamps) > 1:
        duration_ms = timestamps[-1] - timestamps[0]

    return {
        "frame_count": len(frames),
        "duration_ms": round(float(duration_ms), 2),
        "mean_pose_visibility": round(mean(frame_visibility(frame) for frame in frames), 4),
        "left_wrist_x_travel": round(travel(left_wrist_x), 4),
        "right_wrist_x_travel": round(travel(right_wrist_x), 4),
        "left_wrist_y_travel": round(travel(left_wrist_y), 4),
        "right_wrist_y_travel": round(travel(right_wrist_y), 4),
        "shoulder_tilt_range_deg": round(travel(shoulder_tilt), 4),
        "hip_tilt_range_deg": round(travel(hip_tilt), 4),
        "feature_summary": csv_summary,
    }


def summarize_feature_rows(rows: List[dict]) -> dict:
    if not rows:
        return {}
    numeric_columns = [
        "upper_body_presence",
        "torso_separation_deg",
        "left_wrist_speed",
        "right_wrist_speed",
        "mean_wrist_speed",
        "smoothed_wrist_speed",
        "hands_to_torso_distance",
        "torso_velocity",
        "hands_velocity",
        "swing_score",
    ]
    summary = {}
    for column in numeric_columns:
        values = []
        for row in rows:
            value = row.get(column)
            if value in {None, ""}:
                continue
            values.append(float(value))
        if not values:
            continue
        summary[column] = {
            "min": round(min(values), 4),
            "max": round(max(values), 4),
            "mean": round(mean(values), 4),
        }
    return summary


def landmark_series(frames: List[dict], name: str, axis: str) -> List[float]:
    values = []
    for frame in frames:
        landmark = (frame.get("landmarks") or {}).get(name)
        if not isinstance(landmark, dict):
            continue
        value = landmark.get(axis)
        if value is None:
            continue
        values.append(float(value))
    return values


def angle_series(frames: List[dict], a_name: str, b_name: str) -> List[float]:
    values = []
    for frame in frames:
        landmarks = frame.get("landmarks") or {}
        a = landmarks.get(a_name)
        b = landmarks.get(b_name)
        if not isinstance(a, dict) or not isinstance(b, dict):
            continue
        dx = float(b.get("x", 0.0)) - float(a.get("x", 0.0))
        dy = float(b.get("y", 0.0)) - float(a.get("y", 0.0))
        values.append(math.degrees(math.atan2(dy, dx)))
    return values


def frame_visibility(frame: dict) -> float:
    landmarks = frame.get("landmarks") or {}
    values = []
    for landmark in landmarks.values():
        if not isinstance(landmark, dict):
            continue
        visibility = landmark.get("visibility")
        if visibility is None:
            continue
        values.append(float(visibility))
    return mean(values)


def travel(values: Iterable[float]) -> float:
    values = list(values)
    if not values:
        return 0.0
    return max(values) - min(values)


def mean(values: Iterable[float]) -> float:
    values = list(values)
    if not values:
        return 0.0
    return sum(values) / len(values)


def auto_pairwise_preferences(samples: List[dict], min_quality_gap: float) -> List[dict]:
    reward_rows = []
    grouped: dict[str, List[dict]] = {}
    for sample in samples:
        group_key = f"{sample['source_id']}::{sample.get('view', 'unknown')}"
        grouped.setdefault(group_key, []).append(sample)

    for group_samples in grouped.values():
        sorted_samples = sorted(
            group_samples,
            key=lambda item: item["quality_total"],
            reverse=True,
        )
        for better in sorted_samples:
            for worse in reversed(sorted_samples):
                gap = better["quality_total"] - worse["quality_total"]
                if gap < min_quality_gap:
                    continue
                if better["candidate_id"] == worse["candidate_id"]:
                    continue
                reward_rows.append(
                    {
                        "chosen": {
                            "candidate_id": better["candidate_id"],
                            "summary": better["summary"],
                            "quality_scores": better["quality_scores"],
                            "issues": better["issues"],
                        },
                        "rejected": {
                            "candidate_id": worse["candidate_id"],
                            "summary": worse["summary"],
                            "quality_scores": worse["quality_scores"],
                            "issues": worse["issues"],
                        },
                        "preference": f"manual_quality_gap_{gap:.1f}",
                    }
                )
                break
    return reward_rows


if __name__ == "__main__":
    main()
