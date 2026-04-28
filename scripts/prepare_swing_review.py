#!/usr/bin/env python3
"""Prepare one multi-video action review workspace from pose JSON/CSV files."""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import re
import signal
import shutil
from dataclasses import dataclass
from contextlib import contextmanager
from pathlib import Path
from typing import Dict, List, Optional, Sequence

import cv2


@dataclass(frozen=True)
class ReviewInput:
    pose_json: Optional[Path]
    features_csv: Optional[Path]
    source_video: Path
    source_id: str


@dataclass(frozen=True)
class PrepareReviewConfig:
    out_dir: Path
    pre_roll_ms: int = 1200
    post_roll_ms: int = 1200
    peak_threshold: float = 1.8
    cooldown_ms: int = 700
    max_candidates_per_video: int = 24
    top_k_if_empty: int = 8
    task_name: str = "Action Review"
    positive_label: str = "action"
    negative_label: str = "other"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Create one review workspace from one or more pose JSON / feature CSV pairs."
        ),
    )
    parser.add_argument(
        "--pose-json",
        type=Path,
        action="append",
        required=True,
        help="Pose JSON created by extract_pose_from_video.py. Repeat for multiple videos.",
    )
    parser.add_argument(
        "--features-csv",
        type=Path,
        action="append",
        required=True,
        help="Feature CSV created by extract_pose_from_video.py. Repeat for multiple videos.",
    )
    parser.add_argument(
        "--video",
        type=Path,
        action="append",
        help=(
            "Optional source video path override. Repeat to match each pose/csv pair. "
            "If omitted, the path inside each pose JSON is used."
        ),
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        required=True,
        help="Output folder for one shared review workspace",
    )
    parser.add_argument("--pre-roll-ms", type=int, default=1200)
    parser.add_argument("--post-roll-ms", type=int, default=1200)
    parser.add_argument("--peak-threshold", type=float, default=1.8)
    parser.add_argument("--cooldown-ms", type=int, default=700)
    parser.add_argument(
        "--max-candidates-per-video",
        type=int,
        default=24,
        help="Maximum number of candidates to keep for each source video",
    )
    parser.add_argument("--top-k-if-empty", type=int, default=8)
    parser.add_argument("--task-name", type=str, default="Action Review")
    parser.add_argument("--positive-label", type=str, default="action")
    parser.add_argument("--negative-label", type=str, default="other")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    review_inputs = build_review_inputs(args)
    config = PrepareReviewConfig(
        out_dir=args.out_dir.expanduser().resolve(),
        pre_roll_ms=args.pre_roll_ms,
        post_roll_ms=args.post_roll_ms,
        peak_threshold=args.peak_threshold,
        cooldown_ms=args.cooldown_ms,
        max_candidates_per_video=args.max_candidates_per_video,
        top_k_if_empty=args.top_k_if_empty,
        task_name=args.task_name,
        positive_label=args.positive_label,
        negative_label=args.negative_label,
    )
    prepare_review_workspace(review_inputs, config)


def prepare_review_workspace(
    review_inputs: Sequence[ReviewInput],
    config: PrepareReviewConfig,
) -> dict:
    out_dir = config.out_dir.expanduser().resolve()
    candidates_dir = out_dir / "candidates"
    candidates_dir.mkdir(parents=True, exist_ok=True)

    copy_review_templates(out_dir)

    manifest_candidates: List[dict] = []
    manifest_sources: List[dict] = []
    failed_sources: List[dict] = []
    existing_manifest = load_existing_manifest(out_dir)
    reusable_sources = index_reusable_sources(existing_manifest, out_dir)
    total_sources = len(review_inputs)

    try:
        for source_order, review_input in enumerate(review_inputs, start=1):
            print(
                f"[prepare {source_order}/{total_sources}] "
                f"{review_input.source_video.name} ({(source_order / max(total_sources, 1)) * 100:.1f}%)",
            )

            reusable = reusable_sources.get(review_input.source_id)
            input_has_pose_features = bool(review_input.pose_json and review_input.features_csv)
            reusable_has_pose_features = bool(reusable["source"].get("has_pose_features")) if reusable else False
            if (
                reusable
                and reusable["source_video"] == str(review_input.source_video)
                and reusable_has_pose_features == input_has_pose_features
            ):
                reused_candidates = [
                    {
                        **candidate,
                        "source_order": source_order,
                    }
                    for candidate in reusable["candidates"]
                ]
                manifest_candidates.extend(reused_candidates)
                manifest_sources.append(
                    {
                        **reusable["source"],
                        "source_order": source_order,
                        "source_name": review_input.source_video.name,
                        "source_video": str(review_input.source_video),
                        "candidate_count": len(reused_candidates),
                    }
                )
                persist_review_workspace(
                    out_dir=out_dir,
                    config=config,
                    manifest_sources=manifest_sources,
                    manifest_candidates=manifest_candidates,
                )
                print(
                    f"[prepare {source_order}/{total_sources}] reused: "
                    f"{review_input.source_video.name}, candidates={len(reused_candidates)}",
                )
                continue
            if reusable and reusable["source_video"] == str(review_input.source_video):
                print(
                    f"[prepare {source_order}/{total_sources}] rebuilding: "
                    f"{review_input.source_video.name}, "
                    "pose availability changed since last manifest",
                )

            try:
                if review_input.pose_json and review_input.features_csv:
                    pose_payload = json.loads(review_input.pose_json.read_text(encoding="utf-8"))
                    rows = read_csv(review_input.features_csv)
                    if not rows:
                        print(f"Skipping empty feature CSV: {review_input.features_csv}")
                        continue

                    scored_rows = score_rows(rows)
                    peak_rows = detect_peaks(
                        scored_rows,
                        threshold=config.peak_threshold,
                        cooldown_ms=config.cooldown_ms,
                        max_candidates=config.max_candidates_per_video,
                        fallback_top_k=config.top_k_if_empty,
                    )
                    source_candidates = build_pose_review_candidates(
                        out_dir=out_dir,
                        source_order=source_order,
                        review_input=review_input,
                        config=config,
                        pose_payload=pose_payload,
                        scored_rows=scored_rows,
                        peak_rows=peak_rows,
                    )
                else:
                    source_candidates = build_raw_review_candidates(
                        out_dir=out_dir,
                        source_order=source_order,
                        review_input=review_input,
                    )
            except Exception as exc:  # noqa: BLE001 - keep long runs resilient to single bad videos.
                failed_sources.append(
                    {
                        "source_id": review_input.source_id,
                        "source_video": str(review_input.source_video),
                        "source_name": review_input.source_video.name,
                        "source_order": source_order,
                        "error": f"{type(exc).__name__}: {exc}",
                    }
                )
                print(
                    f"[prepare {source_order}/{total_sources}] failed: "
                    f"{review_input.source_video.name} -> {type(exc).__name__}: {exc}",
                )
                continue

            manifest_candidates.extend(source_candidates)
            manifest_sources.append(
                {
                    "source_id": review_input.source_id,
                    "source_video": str(review_input.source_video),
                    "source_name": review_input.source_video.name,
                    "source_order": source_order,
                    "candidate_count": len(source_candidates),
                    "has_pose_features": bool(review_input.pose_json and review_input.features_csv),
                }
            )
            persist_review_workspace(
                out_dir=out_dir,
                config=config,
                manifest_sources=manifest_sources,
                manifest_candidates=manifest_candidates,
            )
            print(
                f"[prepare {source_order}/{total_sources}] done: "
                f"{review_input.source_video.name}, candidates={len(source_candidates)}",
            )
    except KeyboardInterrupt:
        persist_review_workspace(
            out_dir=out_dir,
            config=config,
            manifest_sources=manifest_sources,
            manifest_candidates=manifest_candidates,
        )
        print("")
        print(
            "Interrupted during review preparation. "
            "Completed sources have already been saved and will be reused on the next run.",
        )
        raise

    manifest = build_manifest(config, manifest_sources, manifest_candidates)

    print(f"Prepared {len(manifest_candidates)} candidates in: {out_dir}")
    if failed_sources:
        print(f"Skipped {len(failed_sources)} source video(s) due to preparation errors.")
    print(f"Review root: {out_dir}")
    print(f"Recheck page: {out_dir / 'review_recheck.html'}")
    print(f"Mobile label page: {out_dir / 'mobile_label.html'}")
    print("Next step: python3 scripts/serve_action_review.py --review-dir " + str(out_dir))
    return manifest


def build_pose_review_candidates(
    *,
    out_dir: Path,
    source_order: int,
    review_input: ReviewInput,
    config: PrepareReviewConfig,
    pose_payload: dict,
    scored_rows: Sequence[dict],
    peak_rows: Sequence[dict],
) -> List[dict]:
    source_candidates = []
    for idx, peak_row in enumerate(peak_rows, start=1):
        peak_ms = float(peak_row["timestamp_ms"])
        start_ms = max(0.0, peak_ms - config.pre_roll_ms)
        end_ms = peak_ms + config.post_roll_ms
        candidate_id = f"{review_input.source_id}_candidate_{idx:03d}"
        candidate_dir = out_dir / "candidates" / review_input.source_id / candidate_id
        candidate_dir.mkdir(parents=True, exist_ok=True)

        clipped_rows = [
            row
            for row in scored_rows
            if start_ms <= float(row["timestamp_ms"]) <= end_ms
        ]
        clipped_frames = [
            frame
            for frame in pose_payload["frames"]
            if start_ms <= float(frame["timestamp_ms"]) <= end_ms
        ]

        csv_path = candidate_dir / f"{candidate_id}.csv"
        json_path = candidate_dir / f"{candidate_id}.json"
        video_path = candidate_dir / f"{candidate_id}.mp4"

        write_csv(csv_path, clipped_rows)
        json_path.write_text(
            json.dumps(
                {
                    "candidate_id": candidate_id,
                    "source_id": review_input.source_id,
                    "source_video": str(review_input.source_video),
                    "peak_timestamp_ms": peak_ms,
                    "window": {"start_ms": start_ms, "end_ms": end_ms},
                    "frames": clipped_frames,
                    "review_mode": "pose_candidates",
                },
                indent=2,
            ),
            encoding="utf-8",
        )
        clip_video(
            source_video=review_input.source_video,
            out_path=video_path,
            start_ms=start_ms,
            end_ms=end_ms,
            fps=float(pose_payload.get("fps", 30.0)),
        )

        source_candidates.append(
            {
                "candidate_id": candidate_id,
                "source_id": review_input.source_id,
                "source_name": review_input.source_video.name,
                "source_order": source_order,
                "source_candidate_index": idx,
                "peak_timestamp_ms": peak_ms,
                "window_start_ms": start_ms,
                "window_end_ms": end_ms,
                "peak_score": float(peak_row["swing_score"]),
                "video_rel_path": to_rel_path(out_dir, video_path),
                "csv_rel_path": to_rel_path(out_dir, csv_path),
                "json_rel_path": to_rel_path(out_dir, json_path),
                "has_pose_features": True,
                "candidate_kind": "pose_candidate",
            }
        )
    return source_candidates


def build_raw_review_candidates(
    *,
    out_dir: Path,
    source_order: int,
    review_input: ReviewInput,
) -> List[dict]:
    candidate_id = f"{review_input.source_id}_candidate_001"
    candidate_dir = out_dir / "candidates" / review_input.source_id / candidate_id
    candidate_dir.mkdir(parents=True, exist_ok=True)
    video_path = candidate_dir / f"{candidate_id}.mp4"
    json_path = candidate_dir / f"{candidate_id}.json"
    start_ms, end_ms = read_video_window_ms(review_input.source_video)
    materialize_video_asset(review_input.source_video, video_path)
    json_path.write_text(
        json.dumps(
            {
                "candidate_id": candidate_id,
                "source_id": review_input.source_id,
                "source_video": str(review_input.source_video),
                "peak_timestamp_ms": None,
                "window": {"start_ms": start_ms, "end_ms": end_ms},
                "frames": [],
                "review_mode": "raw_video_fallback",
                "note": "Pose outputs were missing; added the original video for manual review.",
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    return [
        {
            "candidate_id": candidate_id,
            "source_id": review_input.source_id,
            "source_name": review_input.source_video.name,
            "source_order": source_order,
            "source_candidate_index": 1,
            "peak_timestamp_ms": None,
            "window_start_ms": start_ms,
            "window_end_ms": end_ms,
            "peak_score": None,
            "video_rel_path": to_rel_path(out_dir, video_path),
            "csv_rel_path": None,
            "json_rel_path": to_rel_path(out_dir, json_path),
            "has_pose_features": False,
            "candidate_kind": "raw_video_fallback",
        }
    ]


def build_manifest(
    config: PrepareReviewConfig,
    manifest_sources: Sequence[dict],
    manifest_candidates: Sequence[dict],
) -> dict:
    return {
        "task_name": config.task_name,
        "positive_label": config.positive_label,
        "negative_label": config.negative_label,
        "pre_roll_ms": config.pre_roll_ms,
        "post_roll_ms": config.post_roll_ms,
        "candidate_count": len(manifest_candidates),
        "source_count": len(manifest_sources),
        "sources": list(manifest_sources),
        "candidates": list(manifest_candidates),
    }


def persist_review_workspace(
    *,
    out_dir: Path,
    config: PrepareReviewConfig,
    manifest_sources: Sequence[dict],
    manifest_candidates: Sequence[dict],
) -> dict:
    with defer_keyboard_interrupt():
        manifest = build_manifest(config, manifest_sources, manifest_candidates)
        manifest_json = json.dumps(manifest, indent=2)
        (out_dir / "manifest.json").write_text(
            manifest_json,
            encoding="utf-8",
        )
        (out_dir / "review_data.js").write_text(
            "window.REVIEW_DATA = " + manifest_json + ";\n",
            encoding="utf-8",
        )
        copy_review_templates(out_dir)
    return manifest


def copy_review_templates(out_dir: Path) -> None:
    template_path = Path(__file__).parent / "templates" / "swing_review_index.html"
    shutil.copyfile(template_path, out_dir / "index.html")
    recheck_template_path = Path(__file__).parent / "templates" / "swing_review_recheck.html"
    shutil.copyfile(recheck_template_path, out_dir / "review_recheck.html")
    mobile_template_path = Path(__file__).parent / "templates" / "swing_mobile_label.html"
    shutil.copyfile(mobile_template_path, out_dir / "mobile_label.html")


def load_existing_manifest(out_dir: Path) -> dict | None:
    manifest_path = out_dir / "manifest.json"
    if not manifest_path.exists():
        return None
    try:
        return json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None


def index_reusable_sources(existing_manifest: dict | None, out_dir: Path) -> Dict[str, dict]:
    if not existing_manifest:
        return {}

    sources = {
        source["source_id"]: source
        for source in existing_manifest.get("sources", [])
        if source.get("source_id")
    }
    candidates_by_source: Dict[str, List[dict]] = {}
    for candidate in existing_manifest.get("candidates", []):
        source_id = candidate.get("source_id")
        if not source_id:
            continue
        candidates_by_source.setdefault(source_id, []).append(candidate)

    reusable: Dict[str, dict] = {}
    for source_id, source in sources.items():
        source_candidates = sorted(
            candidates_by_source.get(source_id, []),
            key=lambda item: int(item.get("source_candidate_index", 0)),
        )
        if not source_candidates:
            continue
        if all(candidate_files_exist(out_dir, candidate) for candidate in source_candidates):
            reusable[source_id] = {
                "source": source,
                "source_video": source.get("source_video"),
                "candidates": source_candidates,
            }
    return reusable


def candidate_files_exist(out_dir: Path, candidate: dict) -> bool:
    required_keys = ["video_rel_path", "json_rel_path"]
    if candidate.get("has_pose_features", True):
        required_keys.append("csv_rel_path")
    for key in required_keys:
        rel_path = candidate.get(key)
        if not rel_path:
            return False
        if not (out_dir / str(rel_path)).exists():
            return False
    return True


def read_video_window_ms(source_video: Path) -> tuple[float, float]:
    capture = cv2.VideoCapture(str(source_video))
    if not capture.isOpened():
        return 0.0, 0.0
    fps = float(capture.get(cv2.CAP_PROP_FPS) or 0.0)
    frame_count = float(capture.get(cv2.CAP_PROP_FRAME_COUNT) or 0.0)
    capture.release()
    if fps <= 0 or frame_count <= 0:
        return 0.0, 0.0
    duration_ms = max(0.0, (frame_count / fps) * 1000.0)
    return 0.0, duration_ms


def materialize_video_asset(source_video: Path, out_path: Path) -> None:
    if out_path.exists() or out_path.is_symlink():
        if out_path.is_symlink() and out_path.resolve() == source_video.resolve():
            return
        out_path.unlink()
    try:
        relative_target = Path(os.path.relpath(source_video, start=out_path.parent))
        out_path.symlink_to(relative_target)
    except OSError:
        shutil.copy2(source_video, out_path)


@contextmanager
def defer_keyboard_interrupt():
    if signal.getsignal(signal.SIGINT) in (signal.SIG_DFL, signal.SIG_IGN):
        yield
        return

    interrupted = {"received": False}
    previous_handler = signal.getsignal(signal.SIGINT)

    def handler(signum, frame):  # noqa: ARG001 - signal handler signature is fixed.
        interrupted["received"] = True

    signal.signal(signal.SIGINT, handler)
    try:
        yield
    finally:
        signal.signal(signal.SIGINT, previous_handler)
        if interrupted["received"]:
            raise KeyboardInterrupt


def build_review_inputs(args: argparse.Namespace) -> List[ReviewInput]:
    pose_paths = [path.expanduser().resolve() for path in args.pose_json]
    csv_paths = [path.expanduser().resolve() for path in args.features_csv]
    if len(pose_paths) != len(csv_paths):
        raise SystemExit("--pose-json and --features-csv must be repeated the same number of times.")

    video_paths = [path.expanduser().resolve() for path in args.video] if args.video else []
    if video_paths and len(video_paths) != len(pose_paths):
        raise SystemExit("--video must be omitted or repeated the same number of times as --pose-json.")

    review_inputs: List[ReviewInput] = []
    used_ids: set[str] = set()
    for index, (pose_json, features_csv) in enumerate(zip(pose_paths, csv_paths), start=1):
        pose_payload = json.loads(pose_json.read_text(encoding="utf-8"))
        source_video = (
            video_paths[index - 1]
            if video_paths
            else Path(pose_payload["source_video"]).expanduser().resolve()
        )
        if not source_video.exists():
            raise SystemExit(f"Source video not found: {source_video}")

        source_id = slugify(source_video.stem)
        if not source_id:
            source_id = f"source_{index:03d}"
        source_id = make_unique_id(source_id, used_ids)
        used_ids.add(source_id)
        review_inputs.append(
            ReviewInput(
                pose_json=pose_json,
                features_csv=features_csv,
                source_video=source_video,
                source_id=source_id,
            )
        )
    return review_inputs


def slugify(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_")


def make_unique_id(base: str, used_ids: set[str]) -> str:
    if base not in used_ids:
        return base
    suffix = 2
    while f"{base}_{suffix}" in used_ids:
        suffix += 1
    return f"{base}_{suffix}"


def to_rel_path(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def read_csv(path: Path) -> List[dict]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: Sequence[dict]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def score_rows(rows: List[dict]) -> List[dict]:
    timestamps = [float(row["timestamp_ms"]) for row in rows]
    wrist = [float(row["smoothed_wrist_speed"]) for row in rows]
    torso = [float(row["torso_separation_deg"]) for row in rows]
    hands = [float(row["hands_to_torso_distance"]) for row in rows]

    torso_velocity = derivative(torso, timestamps)
    hands_velocity = derivative(hands, timestamps)
    wrist_z = zscore(wrist)
    torso_velocity_z = zscore([abs(value) for value in torso_velocity])
    hands_velocity_z = zscore([abs(value) for value in hands_velocity])

    scored = []
    for idx, row in enumerate(rows):
        action_score = (
            0.50 * wrist_z[idx]
            + 0.35 * torso_velocity_z[idx]
            + 0.15 * hands_velocity_z[idx]
        )
        scored.append(
            {
                **row,
                "torso_velocity": round(torso_velocity[idx], 6),
                "hands_velocity": round(hands_velocity[idx], 6),
                "swing_score": round(action_score, 6),
            }
        )
    return scored


def derivative(values: List[float], timestamps_ms: List[float]) -> List[float]:
    result = [0.0]
    for idx in range(1, len(values)):
        dt = (timestamps_ms[idx] - timestamps_ms[idx - 1]) / 1000.0
        if dt <= 0:
            result.append(0.0)
            continue
        result.append((values[idx] - values[idx - 1]) / dt)
    return result


def zscore(values: List[float]) -> List[float]:
    if not values:
        return []
    avg = sum(values) / len(values)
    variance = sum((value - avg) ** 2 for value in values) / len(values)
    std = math.sqrt(variance) or 1.0
    return [(value - avg) / std for value in values]


def detect_peaks(
    scored_rows: List[dict],
    *,
    threshold: float,
    cooldown_ms: int,
    max_candidates: int,
    fallback_top_k: int,
) -> List[dict]:
    peaks: List[dict] = []
    last_peak_ms = -10_000_000.0

    for idx in range(1, len(scored_rows) - 1):
        previous_score = float(scored_rows[idx - 1]["swing_score"])
        current_score = float(scored_rows[idx]["swing_score"])
        next_score = float(scored_rows[idx + 1]["swing_score"])
        current_ms = float(scored_rows[idx]["timestamp_ms"])

        if (
            current_score >= threshold
            and current_score >= previous_score
            and current_score >= next_score
            and current_ms - last_peak_ms >= cooldown_ms
        ):
            peaks.append(scored_rows[idx])
            last_peak_ms = current_ms

    if peaks:
        selected = sorted(peaks, key=lambda row: float(row["swing_score"]), reverse=True)[
            :max_candidates
        ]
        return sorted(selected, key=lambda row: float(row["timestamp_ms"]))

    ranked = sorted(scored_rows, key=lambda row: float(row["swing_score"]), reverse=True)
    return sorted(ranked[:fallback_top_k], key=lambda row: float(row["timestamp_ms"]))


def clip_video(
    *,
    source_video: Path,
    out_path: Path,
    start_ms: float,
    end_ms: float,
    fps: float,
) -> None:
    capture = cv2.VideoCapture(str(source_video))
    if not capture.isOpened():
        raise RuntimeError(f"Unable to open video: {source_video}")

    width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
    height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
    start_frame = max(0, int((start_ms / 1000.0) * fps))
    end_frame = max(start_frame, int((end_ms / 1000.0) * fps))
    writer = None
    selected_codec = None
    for codec in ("avc1", "H264", "mp4v"):
        fourcc = cv2.VideoWriter_fourcc(*codec)
        candidate_writer = cv2.VideoWriter(str(out_path), fourcc, fps, (width, height))
        if candidate_writer.isOpened():
            writer = candidate_writer
            selected_codec = codec
            break
        candidate_writer.release()
    if writer is None:
        capture.release()
        raise RuntimeError(
            f"Unable to create output video writer for {out_path}. Tried codecs: avc1, H264, mp4v.",
        )

    capture.set(cv2.CAP_PROP_POS_FRAMES, start_frame)
    current_frame = start_frame
    while current_frame <= end_frame:
        ok, frame = capture.read()
        if not ok:
            break
        writer.write(frame)
        current_frame += 1

    writer.release()
    capture.release()
    if selected_codec is not None:
        print(f"clip_video codec={selected_codec}: {out_path.name}")


if __name__ == "__main__":
    main()
