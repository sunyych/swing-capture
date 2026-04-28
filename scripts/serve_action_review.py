#!/usr/bin/env python3
"""Serve one action review workspace over Flask for desktop or mobile labeling."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import threading
import time
import uuid
import json
from collections import deque
from datetime import datetime
from pathlib import Path
from typing import Optional

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Serve a prepared action review directory with label save APIs.",
    )
    parser.add_argument("--review-dir", type=Path, required=True)
    parser.add_argument("--host", type=str, default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument(
        "--labels-file",
        type=Path,
        help="Optional override for the saved labels.json path. Defaults to <review-dir>/labels.json",
    )
    parser.add_argument(
        "--train-out-root",
        type=Path,
        help=(
            "Where retraining runs are written. Defaults to artifacts/models/"
            "<review-dir-name>_rechecked when possible, otherwise <review-dir>/training_runs."
        ),
    )
    return parser.parse_args()


def create_app(review_dir: Path, labels_path: Path, train_out_root: Optional[Path] = None):
    try:
        from flask import Flask, jsonify, request, send_from_directory
    except ModuleNotFoundError as exc:
        if exc.name == "flask":
            raise SystemExit(
                "Flask is required to serve the review UI. Activate the project environment "
                "or install training dependencies first:\n"
                "  source .venv-pose/bin/activate\n"
                "  pip install -r scripts/requirements-train.txt"
            ) from exc
        raise

    app = Flask(__name__, static_folder=None)
    script_dir = Path(__file__).parent.resolve()
    project_root = script_dir.parent.resolve()
    train_script = script_dir / "train_swing_csv_classifier.py"
    predict_script = script_dir / "predict_action_csv_classifier.py"
    train_out_root = (train_out_root or default_train_out_root(review_dir)).expanduser().resolve()
    train_jobs: dict[str, dict] = {}
    train_lock = threading.RLock()
    latest_job_id: str | None = None

    def read_labels() -> dict:
        if not labels_path.exists():
            return {}
        return json.loads(labels_path.read_text(encoding="utf-8"))

    def append_train_log(job: dict, line: str) -> None:
        with train_lock:
            job["logs"].append(line.rstrip("\n"))
            job["updated_at"] = time.time()

    def set_train_status(
        job: dict,
        status: str,
        progress: int | None = None,
        error: str | None = None,
    ) -> None:
        with train_lock:
            job["status"] = status
            if progress is not None:
                job["progress"] = max(0, min(100, int(progress)))
            if error is not None:
                job["error"] = error
            job["updated_at"] = time.time()

    def parse_progress_line(job: dict, line: str) -> None:
        if not line.startswith("TRAIN_PROGRESS "):
            return
        parts = line.strip().split(" ", 2)
        if len(parts) < 3:
            return
        try:
            progress = int(parts[1])
        except ValueError:
            return
        with train_lock:
            job["progress"] = max(0, min(100, progress))
            job["message"] = parts[2]
            job["updated_at"] = time.time()

    def serialize_train_job(job: dict, tail: int | None = 300) -> dict:
        with train_lock:
            logs = list(job["logs"])
            if tail is not None:
                logs = logs[-tail:]
            return {
                "id": job["id"],
                "status": job["status"],
                "progress": job["progress"],
                "message": job.get("message", ""),
                "error": job.get("error"),
                "command": job["command"],
                "out_dir": str(job["out_dir"]),
                "log_path": str(job["log_path"]),
                "pid": job.get("pid"),
                "return_code": job.get("return_code"),
                "created_at": job["created_at"],
                "started_at": job.get("started_at"),
                "finished_at": job.get("finished_at"),
                "logs": logs,
            }

    def run_logged_command(job: dict, command: list[str], header_label: str) -> int:
        log_path = Path(job["log_path"])
        env = os.environ.copy()
        env["PYTHONUNBUFFERED"] = "1"
        with log_path.open("a", encoding="utf-8") as log_handle:
            header = f"{header_label}: " + " ".join(command)
            log_handle.write(header + "\n")
            log_handle.flush()
            append_train_log(job, header)
            process = subprocess.Popen(
                command,
                cwd=project_root,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            with train_lock:
                job["pid"] = process.pid
            assert process.stdout is not None
            for line in process.stdout:
                log_handle.write(line)
                log_handle.flush()
                append_train_log(job, line)
                parse_progress_line(job, line)
            return process.wait()

    def run_train_job(job: dict) -> None:
        out_dir = Path(job["out_dir"])
        log_path = Path(job["log_path"])
        out_dir.mkdir(parents=True, exist_ok=True)
        set_train_status(job, "running", 1)
        with train_lock:
            job["started_at"] = time.time()
        try:
            log_path.write_text("", encoding="utf-8")
            return_code = run_logged_command(job, job["command"], "Training command")
            if return_code == 0:
                set_train_status(job, "refreshing_review", 92)
                with train_lock:
                    job["message"] = "Refreshing review suggestions with the new model"
                model_path = out_dir / "action_csv_classifier.joblib"
                predict_output = out_dir / "predictions.auto.json"
                predict_command = [
                    sys.executable,
                    str(predict_script),
                    "--model-path",
                    str(model_path),
                    "--review-dir",
                    str(review_dir),
                    "--labels-json",
                    str(labels_path),
                    "--output-json",
                    str(predict_output),
                    "--apply",
                    "--suggestions-only",
                    "--reset-non-human-labels",
                ]
                predict_return_code = run_logged_command(job, predict_command, "Prediction refresh command")
                with train_lock:
                    job["return_code"] = predict_return_code
                    job["finished_at"] = time.time()
                if predict_return_code == 0:
                    set_train_status(job, "succeeded", 100)
                    with train_lock:
                        job["message"] = "Training finished and review suggestions were refreshed"
                else:
                    set_train_status(job, "failed", error=f"Prediction refresh exited with code {predict_return_code}")
            else:
                with train_lock:
                    job["return_code"] = return_code
                    job["finished_at"] = time.time()
                set_train_status(job, "failed", error=f"Training exited with code {return_code}")
        except Exception as exc:  # noqa: BLE001 - keep the status endpoint useful for local tooling.
            with train_lock:
                job["finished_at"] = time.time()
            append_train_log(job, f"Training failed before completion: {exc}")
            set_train_status(job, "failed", error=str(exc))

    @app.get("/")
    def index():
        return send_from_directory(review_dir, "index.html")

    @app.get("/review_recheck.html")
    def review_recheck():
        template_dir = Path(__file__).parent / "templates"
        template_path = template_dir / "swing_review_recheck.html"
        if template_path.exists():
            return send_from_directory(template_dir, "swing_review_recheck.html")
        return send_from_directory(review_dir, "review_recheck.html")

    @app.get("/mobile_label.html")
    def mobile_label():
        template_dir = Path(__file__).parent / "templates"
        template_path = template_dir / "swing_mobile_label.html"
        if template_path.exists():
            return send_from_directory(template_dir, "swing_mobile_label.html")
        return send_from_directory(review_dir, "mobile_label.html")

    @app.get("/train_status.html")
    def train_status():
        template_dir = Path(__file__).parent / "templates"
        return send_from_directory(template_dir, "swing_train_status.html")

    @app.get("/review_data.js")
    def review_data():
        return send_from_directory(review_dir, "review_data.js")

    @app.get("/manifest.json")
    def manifest():
        return send_from_directory(review_dir, "manifest.json")

    @app.get("/api/labels")
    def get_labels():
        return jsonify(read_labels())

    @app.post("/api/labels")
    def save_labels():
        payload = request.get_json(force=True, silent=False)
        if not isinstance(payload, dict):
            return jsonify({"error": "labels payload must be a JSON object"}), 400
        if labels_path.exists():
            backup_dir = labels_path.parent / "labels_backups"
            backup_dir.mkdir(parents=True, exist_ok=True)
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            backup_path = backup_dir / f"labels.{timestamp}.json"
            backup_path.write_text(labels_path.read_text(encoding="utf-8"), encoding="utf-8")
        labels_path.write_text(
            json.dumps(payload, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        return jsonify({"ok": True, "label_count": len(payload)})

    @app.get("/api/labels/export")
    def export_labels():
        if not labels_path.exists():
            labels_path.write_text("{}", encoding="utf-8")
        return send_from_directory(labels_path.parent, labels_path.name, as_attachment=True)

    @app.post("/api/train/start")
    def start_train():
        nonlocal latest_job_id
        if not labels_path.exists():
            return jsonify({"error": f"Labels file not found: {labels_path}"}), 400
        if not train_script.exists():
            return jsonify({"error": f"Training script not found: {train_script}"}), 500
        if not predict_script.exists():
            return jsonify({"error": f"Prediction script not found: {predict_script}"}), 500

        with train_lock:
            for existing in reversed(list(train_jobs.values())):
                if existing["status"] in {"queued", "running"}:
                    return jsonify(
                        {
                            "ok": True,
                            "reused": True,
                            "job": serialize_train_job(existing),
                            "status_url": f"/train_status.html?job_id={existing['id']}",
                        }
                    )

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        job_id = f"train_{timestamp}_{uuid.uuid4().hex[:8]}"
        out_dir = train_out_root / job_id
        log_path = out_dir / "train.log"
        command = [
            sys.executable,
            str(train_script),
            "--review-dir",
            str(review_dir),
            "--labels-json",
            str(labels_path),
            "--out-dir",
            str(out_dir),
            "--require-human-review",
        ]
        job = {
            "id": job_id,
            "status": "queued",
            "progress": 0,
            "message": "Queued",
            "error": None,
            "command": command,
            "out_dir": out_dir,
            "log_path": log_path,
            "logs": deque(maxlen=1000),
            "created_at": time.time(),
            "started_at": None,
            "finished_at": None,
            "pid": None,
            "return_code": None,
        }
        with train_lock:
            train_jobs[job_id] = job
            latest_job_id = job_id
        thread = threading.Thread(target=run_train_job, args=(job,), daemon=True)
        thread.start()
        return jsonify(
            {
                "ok": True,
                "reused": False,
                "job": serialize_train_job(job),
                "status_url": f"/train_status.html?job_id={job_id}",
            }
        )

    @app.get("/api/train/status/<job_id>")
    def train_status_api(job_id: str):
        with train_lock:
            job = train_jobs.get(job_id)
        if job is None:
            return jsonify({"error": f"Training job not found: {job_id}"}), 404
        return jsonify(serialize_train_job(job))

    @app.get("/api/train/latest")
    def latest_train_api():
        with train_lock:
            job = train_jobs.get(latest_job_id) if latest_job_id else None
        if job is None:
            return jsonify({"job": None})
        return jsonify({"job": serialize_train_job(job)})

    @app.get("/api/train/jobs")
    def train_jobs_api():
        with train_lock:
            jobs = list(train_jobs.values())
        return jsonify({"jobs": [serialize_train_job(job, tail=40) for job in jobs]})

    @app.get("/<path:asset_path>")
    def assets(asset_path: str):
        return send_from_directory(review_dir, asset_path)

    return app


def default_train_out_root(review_dir: Path) -> Path:
    review_dir = review_dir.expanduser().resolve()
    if review_dir.parent.name == "review" and review_dir.parent.parent.name == "artifacts":
        return review_dir.parent.parent / "models" / f"{review_dir.name}_rechecked"
    return review_dir / "training_runs"


def main() -> None:
    args = parse_args()
    review_dir = args.review_dir.expanduser().resolve()
    if not review_dir.exists():
        raise SystemExit(f"Review directory not found: {review_dir}")
    if not (review_dir / "index.html").exists():
        raise SystemExit("index.html not found in review directory. Run prepare_swing_review.py first.")

    labels_path = (
        args.labels_file.expanduser().resolve()
        if args.labels_file
        else review_dir / "labels.json"
    )
    train_out_root = args.train_out_root.expanduser().resolve() if args.train_out_root else None
    app = create_app(review_dir, labels_path, train_out_root=train_out_root)
    print(f"Serving review workspace: {review_dir}")
    print(f"Labels file: {labels_path}")
    print(f"Training output root: {train_out_root or default_train_out_root(review_dir)}")
    print(f"Open in browser: http://{args.host}:{args.port}")
    print(f"Recheck page: http://{args.host}:{args.port}/review_recheck.html")
    print(f"Mobile label page: http://{args.host}:{args.port}/mobile_label.html")
    print(f"Training status page: http://{args.host}:{args.port}/train_status.html")
    app.run(host=args.host, port=args.port, debug=False)


if __name__ == "__main__":
    main()
