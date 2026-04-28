# Pose Extraction Script

This folder contains a desktop-first offline pose extraction tool for SwingCapture.

## What it does

Given a local video file, the script writes:

- `*.pose.json`: frame-by-frame landmarks for upper-body joints
- `*.features.csv`: upper-body motion features such as torso separation and wrist speed
- `*.overlay.mp4`: optional debug render with landmarks and numeric metrics

## Install

```bash
python3 -m venv .venv-pose
source .venv-pose/bin/activate
pip install -r scripts/requirements-pose.txt
```

## Run

```bash
python3 scripts/extract_pose_from_video.py /path/to/video.mp4 --save-overlay
```

Outputs are written to `artifacts/pose/` by default.

## Why this is not using MLX for landmark extraction

The current script uses MediaPipe Pose because it is a stable off-the-shelf
landmark extractor for offline video files. For this project, MLX is more
useful one stage later:

- train a swing classifier on extracted pose sequences
- run a lightweight temporal classifier over keypoint windows
- experiment with faster offline feature post-processing

If you want, the next step can be an `mlx` training script that takes the
exported JSON/CSV sequences and trains a binary `swing / non-swing` model.
