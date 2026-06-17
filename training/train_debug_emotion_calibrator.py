#!/usr/bin/env python3
"""Train a lightweight -1/0/1 calibrator from labeled debug audio records."""

from __future__ import annotations

import json
import math
import random
from collections import Counter
from pathlib import Path


random.seed(42)

CLASSES = [-1, 0, 1]
ANGER_WORDS = [
    "\u751f\u6c14", "\u70e6", "\u95ed\u5634", "\u53d7\u591f", "\u5feb\u70b9",
    "\u4e3a\u4ec0\u4e48", "\u603b\u662f", "\u8ba8\u538c", "\u6068", "\u591f\u4e86",
]
POS_WORDS = [
    "\u8c22\u8c22", "\u6162\u6162", "\u51b7\u9759", "\u4e00\u8d77", "\u8f9b\u82e6",
    "\u559c\u6b22", "\u5f00\u5fc3", "\u5f88\u597d", "\u4e0d\u9519",
]
NEG_WORDS = [
    "\u751f\u6c14", "\u70e6", "\u95ed\u5634", "\u53d7\u591f", "\u5e9f\u8bdd",
    "\u8ba8\u538c", "\u6068", "\u96be\u8fc7", "\u7cdf\u7cd5",
]


def build_features(record: dict) -> dict[str, float]:
    result = record.get("result", {})
    acoustic = result.get("acoustic_features", {})
    text = (record.get("transcript") or result.get("transcript") or "").lower().strip()
    duration = float(record.get("audio_duration_ms", 0)) / 1000
    if duration <= 0:
        duration = max(float(record.get("audio_bytes", 44) - 44) / 32000, 0.1)

    text_len = len(text)
    return {
        "rms": float(acoustic.get("energy_mean", 0.0)),
        "peak": float(acoustic.get("energy_mean", 0.0)) + float(acoustic.get("energy_std", 0.0)),
        "zcr": float(acoustic.get("zcr_mean", 0.0)),
        "duration": duration,
        "f0_est": float(acoustic.get("pitch_mean", 0.0)),
        "pitch_std": float(acoustic.get("pitch_std", 0.0)),
        "pause_ratio": float(acoustic.get("pause_ratio", 0.0)),
        "speaking_rate": float(acoustic.get("speaking_rate", 0.0)),
        "text_len": float(text_len),
        "exclaim": float(text.count("!") + text.count("\uff01")),
        "anger_hits": float(sum(1 for word in ANGER_WORDS if word in text)),
        "pos_hits": float(sum(1 for word in POS_WORDS if word in text)),
        "neg_hits": float(sum(1 for word in NEG_WORDS if word in text)),
        "speech_rate_proxy": float(text_len / max(duration, 0.1)),
    }


def softmax(logits: list[float]) -> list[float]:
    peak = max(logits)
    values = [math.exp(value - peak) for value in logits]
    total = sum(values) or 1.0
    return [value / total for value in values]


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    debug_dir = root / "backend" / "debug_audio"
    records = []

    for path in debug_dir.glob("*.json"):
        payload = json.loads(path.read_text(encoding="utf-8"))
        if "human_label" not in payload:
            continue
        records.append({
            "label": int(payload["human_label"]),
            "features": build_features(payload),
        })

    counts = Counter(row["label"] for row in records)
    missing = [label for label in CLASSES if counts[label] < 3]
    if missing:
        raise SystemExit(
            "Not enough labeled debug recordings. "
            f"Need at least 3 samples for every class; counts={dict(counts)}, missing={missing}. "
            "Open the Web model debug page and label recent client uploads as -1, 0, or 1."
        )

    feature_names = sorted(records[0]["features"])
    x = [[row["features"][name] for name in feature_names] for row in records]
    y = [CLASSES.index(row["label"]) for row in records]
    dimensions = len(feature_names)

    means = [sum(row[index] for row in x) / len(x) for index in range(dimensions)]
    stds = []
    for index in range(dimensions):
        variance = sum((row[index] - means[index]) ** 2 for row in x) / len(x)
        stds.append(math.sqrt(variance) if variance > 1e-12 else 1.0)
    normalized = [
        [(row[index] - means[index]) / stds[index] for index in range(dimensions)]
        for row in x
    ]

    weights = [[0.0] * dimensions for _ in CLASSES]
    biases = [0.0] * len(CLASSES)
    learning_rate = 0.04
    epochs = 700

    for _ in range(epochs):
        grad_w = [[0.0] * dimensions for _ in CLASSES]
        grad_b = [0.0] * len(CLASSES)
        for row, target in zip(normalized, y):
            probabilities = softmax([
                sum(weight * value for weight, value in zip(class_weights, row)) + biases[class_index]
                for class_index, class_weights in enumerate(weights)
            ])
            for class_index in range(len(CLASSES)):
                error = probabilities[class_index] - (1.0 if class_index == target else 0.0)
                grad_b[class_index] += error
                for feature_index in range(dimensions):
                    grad_w[class_index][feature_index] += error * row[feature_index]

        count = len(records)
        for class_index in range(len(CLASSES)):
            biases[class_index] -= learning_rate * grad_b[class_index] / count
            for feature_index in range(dimensions):
                weights[class_index][feature_index] -= learning_rate * grad_w[class_index][feature_index] / count

    correct = 0
    for row, target in zip(normalized, y):
        probabilities = softmax([
            sum(weight * value for weight, value in zip(class_weights, row)) + biases[class_index]
            for class_index, class_weights in enumerate(weights)
        ])
        if max(range(len(CLASSES)), key=probabilities.__getitem__) == target:
            correct += 1

    output = root / "backend" / "models" / "debug_emotion_calibrator_v1.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(
            {
                "version": "1.0",
                "type": "softmax_regression_triclass",
                "classes": CLASSES,
                "feature_names": feature_names,
                "means": means,
                "stds": stds,
                "weights": weights,
                "biases": biases,
                "metrics": {
                    "samples": len(records),
                    "class_counts": {str(key): value for key, value in counts.items()},
                    "train_accuracy": correct / len(records),
                },
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    print(f"Saved calibrator -> {output}")
    print(f"Samples={len(records)} class_counts={dict(counts)} train_accuracy={correct / len(records):.4f}")


if __name__ == "__main__":
    main()
