from __future__ import annotations

import json
import math
from pathlib import Path


class TriClassEmotionModel:
    """Lightweight -1/0/1 calibrator using text and acoustic features."""

    def __init__(
        self,
        feature_names: list[str],
        means: list[float],
        stds: list[float],
        classes: list[int],
        weights: list[list[float]],
        biases: list[float],
        version: str = "unknown",
        metrics: dict | None = None,
    ):
        self.feature_names = feature_names
        self.means = means
        self.stds = stds
        self.classes = classes
        self.weights = weights
        self.biases = biases
        self.version = version
        self.metrics = metrics or {}

    @classmethod
    def load(cls, path: str | Path) -> TriClassEmotionModel:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
        return cls(
            feature_names=payload["feature_names"],
            means=payload["means"],
            stds=payload["stds"],
            classes=[int(value) for value in payload["classes"]],
            weights=payload["weights"],
            biases=payload["biases"],
            version=str(payload.get("version", Path(path).stem)),
            metrics=payload.get("metrics", {}),
        )

    def predict_probabilities(self, features: dict[str, float]) -> dict[int, float]:
        normalized = []
        for index, name in enumerate(self.feature_names):
            value = float(features.get(name, 0.0))
            scale = self.stds[index] if self.stds[index] != 0 else 1.0
            normalized.append((value - self.means[index]) / scale)

        logits = [
            sum(weight * value for weight, value in zip(class_weights, normalized)) + self.biases[index]
            for index, class_weights in enumerate(self.weights)
        ]
        peak = max(logits)
        exps = [math.exp(value - peak) for value in logits]
        total = sum(exps) or 1.0
        return {
            label: exps[index] / total
            for index, label in enumerate(self.classes)
        }
