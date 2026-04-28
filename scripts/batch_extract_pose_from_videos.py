#!/usr/bin/env python3
"""Batch pose extraction for one or more local videos.

This script keeps the exact same pose JSON / features CSV format as
`extract_pose_from_video.py`, but adds:

1. multi-file input
2. optional native desktop file picker
3. a small extraction manifest for downstream review tooling
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Iterable, List


VIDEO_EXTENSIONS = {
    ".mp4",
    ".mov",
    ".m4v",
    ".avi",
    ".mkv",
    ".webm",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract pose JSON / CSV from multiple short videos.",
    )
    parser.add_argument(
        "videos",
        nargs="*",
        type=Path,
        help="Video files to process. Can be omitted when using --select or --input-dir/--video-dir.",
    )
    parser.add_argument(
        "--video-dir",
        type=Path,
        help="Scan one directory recursively for videos.",
    )
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
        "--out-dir",
        "--output-dir",
        dest="out_dir",
        type=Path,
        default=Path("artifacts/pose"),
        help="Output directory for pose JSON / features CSV.",
    )
    parser.add_argument(
        "--save-overlay",
        action="store_true",
        help="Also write an annotated overlay mp4 for each input video.",
    )
    parser.add_argument(
        "--skip-existing",
        action="store_true",
        help="Reuse existing <stem>.pose.json and <stem>.features.csv when present.",
    )
    parser.add_argument(
        "--manifest-path",
        type=Path,
        help="Optional JSON manifest to write. Defaults to <out-dir>/batch_extract_manifest.json.",
    )
    parser.add_argument("--model-complexity", type=int, choices=(0, 1, 2), default=1)
    parser.add_argument("--min-detection-confidence", type=float, default=0.5)
    parser.add_argument("--min-tracking-confidence", type=float, default=0.5)
    parser.add_argument("--sample-every", type=int, default=1)
    parser.add_argument("--smooth-window", type=int, default=5)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    from extract_pose_from_video import extract_pose_from_video

    videos = collect_videos(args)
    if not videos:
        raise SystemExit(
            "No videos selected. Pass file paths, use --input-dir/--video-dir, or launch with --select.",
        )

    out_dir = args.out_dir.expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = (
        args.manifest_path.expanduser().resolve()
        if args.manifest_path
        else out_dir / "batch_extract_manifest.json"
    )

    records = []
    for index, video_path in enumerate(videos, start=1):
        json_path = out_dir / f"{video_path.stem}.pose.json"
        csv_path = out_dir / f"{video_path.stem}.features.csv"
        overlay_path = out_dir / f"{video_path.stem}.overlay.mp4"

        if args.skip_existing and json_path.exists() and csv_path.exists():
            print(
                f"[{index}/{len(videos)}] Reusing existing pose outputs for {video_path.name}",
            )
            records.append(
                {
                    "video_path": str(video_path),
                    "pose_json": str(json_path),
                    "features_csv": str(csv_path),
                    "overlay_video": str(overlay_path) if overlay_path.exists() else None,
                    "reused_existing": True,
                }
            )
            continue

        print(f"[{index}/{len(videos)}] Extracting pose from {video_path.name}")
        try:
            result = extract_pose_from_video(
                video_path=video_path,
                out_dir=out_dir,
                model_complexity=args.model_complexity,
                min_detection_confidence=args.min_detection_confidence,
                min_tracking_confidence=args.min_tracking_confidence,
                sample_every=args.sample_every,
                save_overlay=args.save_overlay,
                smooth_window=args.smooth_window,
            )
        except SystemExit as exc:
            error_message = str(exc) or "Unknown extraction error"
            print(f"[{index}/{len(videos)}] Failed: {video_path.name} -> {error_message}")
            records.append(record_for_error(video_path, error_message))
            continue
        except Exception as exc:
            error_message = f"{type(exc).__name__}: {exc}"
            print(f"[{index}/{len(videos)}] Failed: {video_path.name} -> {error_message}")
            records.append(record_for_error(video_path, error_message))
            continue

        records.append(record_for_result(result))

    success_count = sum(1 for item in records if item.get("status") == "ok")
    failed_count = sum(1 for item in records if item.get("status") == "failed")

    manifest = {
        "schema": "swingcapture.batch_pose_extract.v1",
        "video_count": len(videos),
        "success_count": success_count,
        "failed_count": failed_count,
        "out_dir": str(out_dir),
        "items": records,
    }
    manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )

    print(f"Batch extraction manifest written to: {manifest_path}")
    print(
        f"Processed {len(videos)} videos into: {out_dir} "
        f"(ok={success_count}, failed={failed_count})",
    )


def collect_videos(args: argparse.Namespace) -> List[Path]:
    seen: set[Path] = set()
    ordered: List[Path] = []
    skipped_hidden = 0

    def add_many(paths: Iterable[Path]) -> None:
        nonlocal skipped_hidden
        for path in paths:
            resolved = path.expanduser().resolve()
            if resolved in seen:
                continue
            if not resolved.exists():
                raise SystemExit(f"Video not found: {resolved}")
            if resolved.is_dir():
                raise SystemExit(f"Expected a file but got a directory: {resolved}")
            if resolved.suffix.lower() not in VIDEO_EXTENSIONS:
                continue
            if not args.include_hidden and is_hidden_path(resolved):
                skipped_hidden += 1
                continue
            seen.add(resolved)
            ordered.append(resolved)

    add_many(args.videos)

    selected_video_dir = args.input_dir or args.video_dir
    if selected_video_dir:
        video_dir = selected_video_dir.expanduser().resolve()
        if not video_dir.exists():
            raise SystemExit(f"--input-dir/--video-dir not found: {video_dir}")
        patterns = args.glob_patterns or ["**/*"]
        matched: List[Path] = []
        for pattern in patterns:
            matched.extend(path for path in video_dir.glob(pattern) if path.is_file())
        add_many(sorted(matched))

    if args.select:
        add_many(select_videos())

    if skipped_hidden:
        print(
            f"Skipped {skipped_hidden} hidden/trash video(s). "
            "Pass --include-hidden to include them.",
        )

    return ordered


def select_videos() -> List[Path]:
    try:
        import tkinter as tk
        from tkinter import filedialog
    except Exception as exc:  # pragma: no cover - desktop dependency
        raise SystemExit(
            "Tkinter is unavailable in this Python environment, so --select cannot open a file picker.",
        ) from exc

    root = tk.Tk()
    root.withdraw()
    root.update()
    selected = filedialog.askopenfilenames(
        title="Select swing videos",
        filetypes=[
            ("Video files", "*.mp4 *.mov *.m4v *.avi *.mkv *.webm"),
            ("All files", "*.*"),
        ],
    )
    root.destroy()
    return [Path(value) for value in selected]


def record_for_result(result) -> dict:
    return {
        "status": "ok",
        "video_path": str(result.video_path),
        "pose_json": str(result.json_path),
        "features_csv": str(result.csv_path),
        "overlay_video": str(result.overlay_path) if result.overlay_path else None,
        "processed_frames": result.processed_frames,
        "fps": result.fps,
        "frame_count": result.frame_count,
        "reused_existing": False,
    }


def record_for_error(video_path: Path, error_message: str) -> dict:
    return {
        "status": "failed",
        "video_path": str(video_path),
        "pose_json": None,
        "features_csv": None,
        "overlay_video": None,
        "processed_frames": 0,
        "fps": 0,
        "frame_count": 0,
        "reused_existing": False,
        "error": error_message,
    }


def is_hidden_path(path: Path) -> bool:
    return any(part.startswith(".") for part in path.parts)


if __name__ == "__main__":
    main()
