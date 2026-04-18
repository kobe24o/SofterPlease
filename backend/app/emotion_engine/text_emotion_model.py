from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path


@dataclass
class TextEmotionPrediction:
    bad_probability: float


class TextEmotionModel:
    """轻量文本情绪模型（Naive Bayes 推理器）。"""

    def __init__(
        self,
        classes: list[str],
        log_prior: dict[str, float],
        log_likelihood: dict[str, dict[str, float]],
        total_tokens: dict[str, int],
        vocab_size: int,
    ):
        self.classes = classes
        self.log_prior = log_prior
        self.log_likelihood = log_likelihood
        self.total_tokens = total_tokens
        self.vocab_size = max(vocab_size, 1)

    @staticmethod
    def tokenize(text: str) -> list[str]:
        text = text.strip().lower()
        chars = [c for c in text if not c.isspace()]
        bigrams = [f"{chars[i]}{chars[i+1]}" for i in range(len(chars) - 1)]
        return chars + bigrams

    @classmethod
    def load(cls, path: str | Path) -> TextEmotionModel:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
        return cls(
            classes=payload["classes"],
            log_prior=payload["log_prior"],
            log_likelihood=payload["log_likelihood"],
            total_tokens=payload["total_tokens"],
            vocab_size=int(payload.get("vocab_size", 1)),
        )

    def predict(self, text: str) -> TextEmotionPrediction:
        logps: dict[str, float] = {c: self.log_prior.get(c, -1e9) for c in self.classes}
        toks = self.tokenize(text)

        for c in self.classes:
            default = math.log(1 / (int(self.total_tokens.get(c, 0)) + self.vocab_size))
            likelihood = self.log_likelihood.get(c, {})
            for tok in toks:
                logps[c] += likelihood.get(tok, default)

        m = max(logps.values())
        exps = {k: math.exp(v - m) for k, v in logps.items()}
        z = sum(exps.values())
        probs = {k: v / z for k, v in exps.items()}

        return TextEmotionPrediction(bad_probability=float(probs.get("bad", 0.5)))
