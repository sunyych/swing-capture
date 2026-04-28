#!/usr/bin/env python3
"""One-command launcher for multi-video swing review.

Typical use:

1. choose multiple videos with a native file picker
2. extract pose JSON / feature CSV for each video
3. build one shared web review workspace
4. optionally serve the review site immediately
"""

from __future__ import annotations

import argparse
import webbrowser
from pathlib import Path
from typing import List

from batch_extract_pose_from_videos import collect_videos
from prepare_swing_review import (
    PrepareReviewConfig,
    ReviewInput,
    prepare_review_workspace,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Select multiple swing videos, prepare one web review workspace, and optionally serve it.",
    )
    parser.add_argument(
        "videos",
        nargs="*",
        type=Path,
        help="Video files to include. Can be omitted when using --select or --input-dir/--video-dir.",
    )
    parser.add_argument("--video-dir", type=Path, help="Scan one directory recursively for videos.")
    parser.add_argument(
        "--input-dir",
        type=Path,
        help="Alias of --video-dir. Scan one directory recursively for videos.",
    )
    parser.add_argument(
        "--glob",
        dest="glob_patterns",
        action="append",
        help="Optional glob pattern relative to --input-dir/--video-dir, for example '**/*.mp4'. Repeatable.",
    )
    parser.add_argument(
        "--include-hidden",
        action="store_true",
        help="Include hidden files (for example .trashed-*) when scanning input directories.",
    )
    parser.add_argument(
        "--select",
        action="store_true",
        help="Open a native multi-select file picker to choose videos.",
    )
    parser.add_argument(
        "--pose-out-dir",
        type=Path,
        default=Path("artifacts/pose"),
        help="Where pose JSON / feature CSV files are stored.",
    )
    parser.add_argument(
        "--review-dir",
        type=Path,
        default=Path("artifacts/review/swing_batch_review"),
        help="Where the generated web review workspace is written.",
    )
    parser.add_argument("--task-name", type=str, default="Swing Review")
    parser.add_argument("--positive-label", type=str, default="baseball_swing")
    parser.add_argument("--negative-label", type=str, default="other")
    parser.add_argument("--pre-roll-ms", type=int, default=1200)
    parser.add_argument("--post-roll-ms", type=int, default=1200)
    parser.add_argument("--peak-threshold", type=float, default=1.8)
    parser.add_argument("--cooldown-ms", type=int, default=700)
    parser.add_argument("--max-candidates-per-video", type=int, default=24)
    parser.add_argument("--top-k-if-empty", type=int, default=8)
    parser.add_argument("--skip-existing", action="store_true")
    parser.add_argument(
        "--reuse-existing-pose-only",
        action="store_true",
        help=(
            "Do not run pose extraction. Only include videos that already have both "
            "<stem>.pose.json and <stem>.features.csv in --pose-out-dir."
        ),
    )
    parser.add_argument(
        "--include-missing-pose-videos",
        action="store_true",
        help=(
            "When pose outputs are missing, still include the original video in review "
            "as one raw fallback candidate for manual labeling."
        ),
    )
    parser.add_argument("--save-overlay", action="store_true")
    parser.add_argument("--model-complexity", type=int, choices=(0, 1, 2), default=1)
    parser.add_argument("--min-detection-confidence", type=float, default=0.5)
    parser.add_argument("--min-tracking-confidence", type=float, default=0.5)
    parser.add_argument("--sample-every", type=int, default=1)
    parser.add_argument("--smooth-window", type=int, default=5)
    parser.add_argument(
        "--no-serve",
        action="store_true",
        help="Only prepare the workspace, do not start the web server.",
    )
    parser.add_argument("--host", type=str, default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument(
        "--force-rebuild-review",
        action="store_true",
        help="Always rebuild review workspace even if review-dir already contains index.html.",
    )
    parser.add_argument(
        "--open-browser",
        action="store_true",
        help="Open the review URL in the default browser after the server starts.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    review_dir = args.review_dir.expanduser().resolve()
    review_ready = (review_dir / "index.html").exists()
    has_video_inputs = bool(args.videos) or bool(args.video_dir) or bool(args.input_dir) or bool(args.select)
    review_dir_exists = review_dir.exists()

    if review_ready and not args.force_rebuild_review and not has_video_inputs:
        print(f"Found existing review workspace: {review_dir}")
        if args.no_serve:
            print(f"Review workspace ready at: {review_dir}")
            return
        serve_review_workspace(
            review_dir=review_dir,
            host=args.host,
            port=args.port,
            open_browser=args.open_browser,
        )
        return

    if review_dir_exists and not review_ready and not has_video_inputs:
        raise SystemExit(
            "Review directory exists but is incomplete (missing index.html). "
            "Please rebuild once with video inputs, for example: "
            "python3 scripts/launch_swing_review.py --video-dir <dir> --glob \"**/*.mp4\" "
            "--pose-out-dir <pose_dir> --review-dir <review_dir> --skip-existing. "
            "After rebuild completes, you can run with only --review-dir to serve.",
        )

    videos = collect_videos(args)
    if not videos:
        raise SystemExit(
            "No videos selected. Pass file paths, use --input-dir/--video-dir, or launch with --select. "
            "If review workspace already exists, run with only --review-dir to serve it.",
        )

    pose_out_dir = args.pose_out_dir.expanduser().resolve()
    pose_out_dir.mkdir(parents=True, exist_ok=True)

    review_inputs: List[ReviewInput] = []
    used_source_ids: set[str] = set()
    extract_pose_from_video = None
    skipped_missing_pose: List[Path] = []
    failed_pose_extractions: List[tuple[Path, str]] = []

    for index, video_path in enumerate(videos, start=1):
        pose_json = pose_out_dir / f"{video_path.stem}.pose.json"
        features_csv = pose_out_dir / f"{video_path.stem}.features.csv"
        has_existing_pose = pose_json.exists() and features_csv.exists()

        if args.reuse_existing_pose_only:
            if not has_existing_pose:
                if args.include_missing_pose_videos:
                    print(
                        f"[{index}/{len(videos)}] Including raw video for {video_path.name}: "
                        "pose outputs are missing",
                    )
                else:
                    skipped_missing_pose.append(video_path)
                    print(
                        f"[{index}/{len(videos)}] Skipping {video_path.name}: "
                        "--reuse-existing-pose-only enabled and pose outputs are missing",
                    )
                    continue
            else:
                print(f"[{index}/{len(videos)}] Reusing existing pose outputs for {video_path.name}")
        elif has_existing_pose and args.skip_existing:
            print(f"[{index}/{len(videos)}] Reusing existing pose outputs for {video_path.name}")
        else:
            if extract_pose_from_video is None:
                from extract_pose_from_video import extract_pose_from_video as _extract_pose_from_video

                extract_pose_from_video = _extract_pose_from_video
            print(f"[{index}/{len(videos)}] Extracting pose for {video_path.name}")
            try:
                extract_pose_from_video(
                    video_path=video_path,
                    out_dir=pose_out_dir,
                    model_complexity=args.model_complexity,
                    min_detection_confidence=args.min_detection_confidence,
                    min_tracking_confidence=args.min_tracking_confidence,
                    sample_every=args.sample_every,
                    save_overlay=args.save_overlay,
                    smooth_window=args.smooth_window,
                )
            except SystemExit as exc:
                error_message = str(exc) or "Unknown extraction error"
                failed_pose_extractions.append((video_path, error_message))
                print(f"[{index}/{len(videos)}] Failed pose extraction for {video_path.name}: {error_message}")
            except Exception as exc:
                error_message = f"{type(exc).__name__}: {exc}"
                failed_pose_extractions.append((video_path, error_message))
                print(f"[{index}/{len(videos)}] Failed pose extraction for {video_path.name}: {error_message}")
            # Refresh pose availability after extraction so we do not create
            # raw fallback candidates for videos that now have pose outputs.
            has_existing_pose = pose_json.exists() and features_csv.exists()

        if not has_existing_pose and not args.include_missing_pose_videos:
            skipped_missing_pose.append(video_path)
            print(
                f"[{index}/{len(videos)}] Skipping {video_path.name}: "
                "pose outputs are missing",
            )
            continue

        source_id = make_unique_source_id(slugify(video_path.stem) or f"source_{index:03d}", used_source_ids)
        used_source_ids.add(source_id)
        review_inputs.append(
            ReviewInput(
                pose_json=pose_json if has_existing_pose else None,
                features_csv=features_csv if has_existing_pose else None,
                source_video=video_path,
                source_id=source_id,
            )
        )

    if skipped_missing_pose:
        print(
            f"Skipped {len(skipped_missing_pose)} video(s) without existing pose outputs. "
            "Pass --include-missing-pose-videos to keep them as raw fallback candidates.",
        )
    if failed_pose_extractions:
        print(f"Failed pose extraction for {len(failed_pose_extractions)} video(s); skipped from review inputs.")

    if not review_inputs:
        raise SystemExit(
            "No videos are ready for review workspace preparation. "
            "Either generate pose outputs first, or rerun with pose extraction enabled.",
        )

    print(f"Preparing review workspace for {len(review_inputs)} video(s)...")
    print(f"Review workspace output: {review_dir}")
    config = PrepareReviewConfig(
        out_dir=review_dir,
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
    print("Review workspace preparation completed.")

    if args.no_serve:
        print(f"Review workspace ready at: {review_dir}")
        return

    serve_review_workspace(
        review_dir=review_dir,
        host=args.host,
        port=args.port,
        open_browser=args.open_browser,
    )


def slugify(value: str) -> str:
    lowered = value.lower()
    chars = [char if char.isalnum() else "_" for char in lowered]
    slug = "".join(chars).strip("_")
    while "__" in slug:
        slug = slug.replace("__", "_")
    return slug


def make_unique_source_id(base: str, used_ids: set[str]) -> str:
    if base not in used_ids:
        return base
    suffix = 2
    while f"{base}_{suffix}" in used_ids:
        suffix += 1
    return f"{base}_{suffix}"


def serve_review_workspace(review_dir: Path, host: str, port: int, open_browser: bool) -> None:
    from serve_action_review import create_app, default_train_out_root

    labels_path = review_dir / "labels.json"
    app = create_app(review_dir, labels_path)
    url = f"http://{host}:{port}"
    print(f"Serving review workspace: {review_dir}")
    print(f"Labels file: {labels_path}")
    print(f"Training output root: {default_train_out_root(review_dir)}")
    print(f"Open in browser: {url}")
    print(f"Recheck page: {url}/review_recheck.html")
    print(f"Mobile label page: {url}/mobile_label.html")
    print(f"Training status page: {url}/train_status.html")
    if open_browser:
        webbrowser.open(url)
    app.run(host=host, port=port, debug=False)


if __name__ == "__main__":
    main()
