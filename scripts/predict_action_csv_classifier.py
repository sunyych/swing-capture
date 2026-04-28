#!/usr/bin/env python3
"""Batch predict labels for review candidates with a trained joblib model."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Dict, List

import joblib
import numpy as np

from train_swing_csv_classifier import extract_window_features


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Use action_csv_classifier.joblib to pre-label review candidates.",
    )
    parser.add_argument(
        "--model-path",
        type=Path,
        required=True,
        help="Path to action_csv_classifier.joblib",
    )
    parser.add_argument(
        "--review-dir",
        type=Path,
        required=True,
        help="Review workspace directory containing manifest.json",
    )
    parser.add_argument(
        "--labels-json",
        type=Path,
        help="Existing labels file. Defaults to <review-dir>/labels.json",
    )
    parser.add_argument(
        "--only-unlabeled",
        action="store_true",
        help="Only predict candidates that do not have a label.",
    )
    parser.add_argument(
        "--min-confidence",
        type=float,
        default=0.0,
        help=(
            "Only auto-apply labels whose max probability >= this value. "
            "Prediction metadata is still written for every predicted candidate when --apply is used."
        ),
    )
    parser.add_argument(
        "--positive-label",
        type=str,
        help="Positive swing label used for ranking confidence. Defaults to manifest positive_label or baseball_swing.",
    )
    parser.add_argument(
        "--suggestions-only",
        action="store_true",
        help="Write prediction metadata for review, but do not set label automatically.",
    )
    parser.add_argument(
        "--reset-non-human-labels",
        action="store_true",
        help=(
            "Before writing new suggestions, clear labels and review state that were not confirmed by a human. "
            "Human-reviewed labels are preserved."
        ),
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write predictions back into labels.json (default is dry-run).",
    )
    parser.add_argument(
        "--output-json",
        type=Path,
        help="Optional path to save prediction details JSON.",
    )
    return parser.parse_args()


def is_human_reviewed(record: dict) -> bool:
    return bool(
        record.get("reviewedByHuman")
        or record.get("labelSource") in {"human_review", "mobile_label"}
    )


def reset_non_human_record(record: dict) -> dict:
    preserved = {
        key: value
        for key, value in record.items()
        if key not in {
            "label",
            "labelSource",
            "reviewedByHuman",
            "reviewedAt",
            "updatedAt",
            "autoPredictedLabel",
            "autoPredictedConfidence",
            "autoPositiveLabel",
            "autoPositiveConfidence",
            "autoPredictedClassProbs",
            "autoPredictedByModel",
        }
    }
    return preserved


def main() -> None:
    args = parse_args()
    review_dir = args.review_dir.expanduser().resolve()
    model_path = args.model_path.expanduser().resolve()
    labels_path = (
        args.labels_json.expanduser().resolve()
        if args.labels_json
        else review_dir / "labels.json"
    )
    output_json = (
        args.output_json.expanduser().resolve()
        if args.output_json
        else review_dir / "predictions.auto.json"
    )

    model_bundle = joblib.load(model_path)
    model = model_bundle["model"]
    class_names: List[str] = model_bundle["class_names"]

    manifest = json.loads((review_dir / "manifest.json").read_text(encoding="utf-8"))
    labels = (
        json.loads(labels_path.read_text(encoding="utf-8")) if labels_path.exists() else {}
    )
    positive_label = args.positive_label or manifest.get("positive_label") or "baseball_swing"

    predictions: List[dict] = []
    metadata_updated = 0
    labels_applied = 0
    skipped_label_confidence = 0
    skipped_labeled = 0
    skipped_missing_features = 0

    for candidate in manifest.get("candidates", []):
        candidate_id = candidate["candidate_id"]
        existing = labels.get(candidate_id, {})
        if args.reset_non_human_labels and existing and not is_human_reviewed(existing):
            existing = reset_non_human_record(existing)
        if args.only_unlabeled and existing.get("label"):
            skipped_labeled += 1
            continue

        csv_rel_path = candidate.get("csv_rel_path")
        if not csv_rel_path:
            skipped_missing_features += 1
            continue
        csv_path = review_dir / csv_rel_path
        if not csv_path.exists():
            skipped_missing_features += 1
            continue
        rows = list(csv.DictReader(csv_path.open("r", encoding="utf-8", newline="")))
        if not rows:
            continue

        features = np.asarray([extract_window_features(rows)], dtype=np.float32)
        pred_idx = int(model.predict(features)[0])

        if hasattr(model, "predict_proba"):
            proba = model.predict_proba(features)[0]
            confidence = float(np.max(proba))
            class_probs = {class_names[i]: float(proba[i]) for i in range(len(class_names))}
        else:
            confidence = 1.0
            class_probs = {name: None for name in class_names}

        predicted_label = class_names[pred_idx]
        positive_confidence = class_probs.get(positive_label)
        if positive_confidence is None:
            positive_confidence = confidence if predicted_label == positive_label else 0.0

        predictions.append(
            {
                "candidate_id": candidate_id,
                "predicted_label": predicted_label,
                "confidence": confidence,
                "positive_label": positive_label,
                "positive_confidence": float(positive_confidence),
                "class_probs": class_probs,
                "source_name": candidate.get("source_name"),
            }
        )

        if not args.apply:
            continue

        preserved_label = existing.get("label")
        should_auto_label = (
            not args.suggestions_only
            and not preserved_label
            and confidence >= args.min_confidence
        )
        if not should_auto_label and not preserved_label and confidence < args.min_confidence:
            skipped_label_confidence += 1

        updated_record = {
            **existing,
            "source_id": candidate.get("source_id"),
            "source_name": candidate.get("source_name"),
            "source_order": candidate.get("source_order"),
            "source_candidate_index": candidate.get("source_candidate_index"),
            "peak_score": candidate.get("peak_score"),
            "peak_timestamp_ms": candidate.get("peak_timestamp_ms"),
            "csv_rel_path": candidate.get("csv_rel_path"),
            "json_rel_path": candidate.get("json_rel_path"),
            "video_rel_path": candidate.get("video_rel_path"),
            "window_start_ms": candidate.get("window_start_ms"),
            "window_end_ms": candidate.get("window_end_ms"),
            "autoPredictedLabel": predicted_label,
            "autoPredictedConfidence": confidence,
            "autoPositiveLabel": positive_label,
            "autoPositiveConfidence": float(positive_confidence),
            "autoPredictedClassProbs": class_probs,
            "autoPredictedByModel": str(model_path),
        }
        if should_auto_label:
            updated_record["label"] = predicted_label
            updated_record["labelSource"] = "auto_prediction"
            labels_applied += 1
        elif preserved_label:
            updated_record["label"] = preserved_label
        labels[candidate_id] = updated_record
        metadata_updated += 1

    output_json.parent.mkdir(parents=True, exist_ok=True)
    output_json.write_text(
        json.dumps(
            {
                "prediction_count": len(predictions),
                "positive_label": positive_label,
                "predictions": predictions,
            },
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    if args.apply:
        labels_path.parent.mkdir(parents=True, exist_ok=True)
        labels_path.write_text(
            json.dumps(labels, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )

    print(f"Predictions written to: {output_json}")
    print(f"Total predicted candidates: {len(predictions)}")
    print(f"Skipped candidates without CSV features: {skipped_missing_features}")
    if args.only_unlabeled:
        print(f"Skipped already labeled: {skipped_labeled}")
    if args.apply:
        print(f"Prediction metadata updated: {metadata_updated}")
        print(f"Auto-applied labels: {labels_applied}")
        if args.suggestions_only:
            print("Suggestions-only mode: no labels were auto-applied.")
        print(f"Skipped auto-label by min-confidence: {skipped_label_confidence}")
        print(f"Labels file updated: {labels_path}")
    else:
        print("Dry run only (no labels.json update). Pass --apply to write labels.")


if __name__ == "__main__":
    main()
