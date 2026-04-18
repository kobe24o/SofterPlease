from __future__ import annotations

import json
import math
from pathlib import Path


class MultimodalEmotionModel:
    """多模态情绪模型（文本+声学）推理器。"""

    def __init__(self, feature_names: list[str], means: list[float], stds: list[float], weights: list[float], bias: float):
        self.feature_names = feature_names
        self.means = means
        self.stds = stds
        self.weights = weights
        self.bias = bias

    @classmethod
    def load(cls, path: str | Path) -> MultimodalEmotionModel:
        payload = json.loads(Path(path).read_text(encoding='utf-8'))
        return cls(
            feature_names=payload['feature_names'],
            means=payload['means'],
            stds=payload['stds'],
            weights=payload['weights'],
            bias=payload['bias'],
        )

    @staticmethod
    def _sigmoid(x: float) -> float:
        if x >= 0:
            z = math.exp(-x)
            return 1 / (1 + z)
        z = math.exp(x)
        return z / (1 + z)

    def predict_bad_probability(self, features: dict[str, float]) -> float:
        xs = []
        for i, name in enumerate(self.feature_names):
            v = float(features.get(name, 0.0))
            xs.append((v - self.means[i]) / (self.stds[i] if self.stds[i] != 0 else 1.0))
        z = sum(self.weights[i] * xs[i] for i in range(len(xs))) + self.bias
        return self._sigmoid(z)
