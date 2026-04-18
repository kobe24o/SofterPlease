#!/usr/bin/env python3
"""训练轻量中文文本情绪模型（Naive Bayes）。"""

from __future__ import annotations

import csv
import json
import math
import random
from collections import Counter, defaultdict
from pathlib import Path

random.seed(42)


class TextEmotionNB:
    def __init__(self) -> None:
        self.class_counts: Counter[str] = Counter()
        self.token_counts: dict[str, Counter[str]] = defaultdict(Counter)
        self.total_tokens: Counter[str] = Counter()
        self.vocab: set[str] = set()
        self.log_prior: dict[str, float] = {}
        self.log_likelihood: dict[str, dict[str, float]] = {}

    @staticmethod
    def tokenize(text: str) -> list[str]:
        text = text.strip().lower()
        chars = [c for c in text if not c.isspace()]
        bigrams = [f"{chars[i]}{chars[i+1]}" for i in range(len(chars) - 1)]
        return chars + bigrams

    def fit(self, texts: list[str], labels: list[str]) -> None:
        for text, label in zip(texts, labels):
            self.class_counts[label] += 1
            for tok in self.tokenize(text):
                self.token_counts[label][tok] += 1
                self.total_tokens[label] += 1
                self.vocab.add(tok)

        n = sum(self.class_counts.values())
        for label, c in self.class_counts.items():
            self.log_prior[label] = math.log(c / n)

        v = max(len(self.vocab), 1)
        for label in self.class_counts:
            denom = self.total_tokens[label] + v
            self.log_likelihood[label] = {}
            for tok in self.vocab:
                num = self.token_counts[label][tok] + 1
                self.log_likelihood[label][tok] = math.log(num / denom)

    def predict_proba_bad(self, text: str) -> float:
        classes = list(self.class_counts.keys())
        logps: dict[str, float] = {c: self.log_prior.get(c, -1e9) for c in classes}
        for c in classes:
            default = math.log(1 / (self.total_tokens[c] + max(len(self.vocab), 1)))
            for tok in self.tokenize(text):
                logps[c] += self.log_likelihood[c].get(tok, default)

        m = max(logps.values())
        exps = {k: math.exp(v - m) for k, v in logps.items()}
        z = sum(exps.values())
        probs = {k: v / z for k, v in exps.items()}
        return probs.get("bad", 0.5)

    def dump(self) -> dict:
        return {
            "version": "1.0",
            "classes": list(self.class_counts.keys()),
            "log_prior": self.log_prior,
            "log_likelihood": self.log_likelihood,
            "total_tokens": dict(self.total_tokens),
            "vocab_size": len(self.vocab),
        }


def load_dataset(path: Path) -> tuple[list[str], list[str], list[float]]:
    texts, labels, scores = [], [], []
    with path.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            texts.append(row["text"])
            labels.append(row["label"])
            scores.append(float(row["score"]))
    return texts, labels, scores


def split_train_val(idxs: list[int], val_ratio: float = 0.2) -> tuple[list[int], list[int]]:
    random.shuffle(idxs)
    k = int(len(idxs) * (1 - val_ratio))
    return idxs[:k], idxs[k:]


def evaluate(model: TextEmotionNB, texts: list[str], labels: list[str], scores: list[float], idxs: list[int]) -> tuple[float, float]:
    correct = 0
    abs_err = 0.0
    for i in idxs:
        p_bad = model.predict_proba_bad(texts[i])
        pred = "bad" if p_bad >= 0.5 else "good"
        if pred == labels[i]:
            correct += 1
        abs_err += abs(p_bad - scores[i])
    acc = correct / max(len(idxs), 1)
    mae = abs_err / max(len(idxs), 1)
    return acc, mae


def main() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    data_file = repo_root / "training" / "data" / "emotion_text_corpus_zh.csv"
    if not data_file.exists():
        raise FileNotFoundError(f"Dataset not found: {data_file}. Run collect_emotion_text_corpus.py first.")

    texts, labels, scores = load_dataset(data_file)
    idxs = list(range(len(texts)))
    train_idx, val_idx = split_train_val(idxs, 0.2)

    model = TextEmotionNB()
    model.fit([texts[i] for i in train_idx], [labels[i] for i in train_idx])

    train_acc, train_mae = evaluate(model, texts, labels, scores, train_idx)
    val_acc, val_mae = evaluate(model, texts, labels, scores, val_idx)

    out_model = repo_root / "backend" / "models" / "emotion_text_nb_v1.json"
    out_model.parent.mkdir(parents=True, exist_ok=True)
    out_model.write_text(json.dumps(model.dump(), ensure_ascii=False), encoding="utf-8")

    print(f"Saved model -> {out_model}")
    print(f"Train accuracy={train_acc:.4f}, MAE={train_mae:.4f}")
    print(f"Val   accuracy={val_acc:.4f}, MAE={val_mae:.4f}")


if __name__ == "__main__":
    main()
