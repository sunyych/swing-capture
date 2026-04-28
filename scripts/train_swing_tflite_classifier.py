#!/usr/bin/env python3
"""Train and export an on-device TFLite swing classifier."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import List

import numpy as np
import tensorflow as tf
from sklearn.model_selection import train_test_split

from train_swing_csv_classifier import (
    extract_window_features,
    is_human_reviewed,
    make_feature_names,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Train a small dense classifier and export .tflite for mobile inference.",
    )
    parser.add_argument("--review-dir", type=Path, required=True)
    parser.add_argument("--labels-json", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--test-size", type=float, default=0.25)
    parser.add_argument("--random-state", type=int, default=42)
    parser.add_argument(
        "--require-human-review",
        action="store_true",
        help="Train only on labels that were confirmed in review_recheck.html.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    review_dir = args.review_dir.expanduser().resolve()
    labels = json.loads(args.labels_json.expanduser().resolve().read_text(encoding="utf-8"))
    manifest = json.loads((review_dir / "manifest.json").read_text(encoding="utf-8"))

    features: List[List[float]] = []
    targets: List[str] = []
    sample_meta: List[dict] = []
    skipped_unreviewed = 0
    skipped_missing_features = 0

    for candidate in manifest["candidates"]:
        label_info = labels.get(candidate["candidate_id"])
        if not label_info or label_info.get("label") in {None, "", "skip"}:
            continue
        if args.require_human_review and not is_human_reviewed(label_info):
            skipped_unreviewed += 1
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

        features.append(extract_window_features(rows))
        targets.append(label_info["label"])
        sample_meta.append(
            {
                "candidate_id": candidate["candidate_id"],
                "label": label_info["label"],
            }
        )

    if len(features) < 20:
        raise SystemExit("Need at least 20 labeled samples for useful TFLite training.")

    class_names = sorted(set(targets))
    if len(class_names) < 2:
        raise SystemExit("Need at least 2 classes to train classifier.")
    class_to_index = {name: idx for idx, name in enumerate(class_names)}

    X = np.asarray(features, dtype=np.float32)
    y = np.asarray([class_to_index[item] for item in targets], dtype=np.int32)

    X_train, X_test, y_train, y_test = train_test_split(
        X,
        y,
        test_size=args.test_size,
        random_state=args.random_state,
        stratify=y,
    )

    model = tf.keras.Sequential(
        [
            tf.keras.layers.Input(shape=(X.shape[1],)),
            tf.keras.layers.Dense(64, activation="relu"),
            tf.keras.layers.Dense(32, activation="relu"),
            tf.keras.layers.Dense(len(class_names), activation="softmax"),
        ]
    )
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=1e-3),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )

    history = model.fit(
        X_train,
        y_train,
        validation_data=(X_test, y_test),
        epochs=args.epochs,
        batch_size=args.batch_size,
        verbose=0,
    )

    loss, accuracy = model.evaluate(X_test, y_test, verbose=0)
    y_pred = np.argmax(model.predict(X_test, verbose=0), axis=1)
    swing_index = class_to_index.get("baseball_swing")
    if swing_index is not None:
        tp = int(np.sum((y_test == swing_index) & (y_pred == swing_index)))
        fp = int(np.sum((y_test != swing_index) & (y_pred == swing_index)))
        fn = int(np.sum((y_test == swing_index) & (y_pred != swing_index)))
        precision = tp / (tp + fp) if (tp + fp) else 0.0
        recall = tp / (tp + fn) if (tp + fn) else 0.0
        f1 = (
            (2 * precision * recall) / (precision + recall)
            if (precision + recall)
            else 0.0
        )
    else:
        precision = recall = f1 = 0.0

    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    tflite_model = converter.convert()

    out_dir = args.out_dir.expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    tflite_path = out_dir / "swing_classifier.tflite"
    tflite_path.write_bytes(tflite_model)

    metadata = {
        "schema": "swingcapture.tflite_classifier.v1",
        "input_dim": int(X.shape[1]),
        "class_names": class_names,
        "class_to_index": class_to_index,
        "feature_names": make_feature_names(),
        "sample_count": int(len(features)),
        "eval": {
            "loss": float(loss),
            "accuracy": float(accuracy),
            "baseball_swing_precision": float(precision),
            "baseball_swing_recall": float(recall),
            "baseball_swing_f1": float(f1),
        },
        "history": {
            "train_loss_last": float(history.history["loss"][-1]),
            "train_acc_last": float(history.history["accuracy"][-1]),
            "val_loss_last": float(history.history["val_loss"][-1]),
            "val_acc_last": float(history.history["val_accuracy"][-1]),
        },
        "samples": sample_meta,
    }
    (out_dir / "swing_classifier_labels.json").write_text(
        json.dumps(
            {
                "class_names": class_names,
                "class_to_index": class_to_index,
            },
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    (out_dir / "swing_classifier_report.json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    if skipped_unreviewed:
        print(f"Skipped unreviewed labels: {skipped_unreviewed}")
    if skipped_missing_features:
        print(f"Skipped labels without CSV features: {skipped_missing_features}")

    print(f"TFLite model written to: {tflite_path}")
    print(f"Labels written to: {out_dir / 'swing_classifier_labels.json'}")
    print(f"Report written to: {out_dir / 'swing_classifier_report.json'}")
    if args.require_human_review:
        print(f"Skipped unreviewed labels: {skipped_unreviewed}")


if __name__ == "__main__":
    main()
