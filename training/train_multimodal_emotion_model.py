#!/usr/bin/env python3
"""训练多模态情绪模型：文本特征 + 声学特征。"""

from __future__ import annotations

import csv
import json
import math
import random
import wave
from pathlib import Path

random.seed(42)

ANGER_WORDS = ["生气", "烦", "闭嘴", "受够", "快点", "为什么", "总是"]
POS_WORDS = ["谢谢", "慢慢", "冷静", "一起", "辛苦"]
NEG_WORDS = ["生气", "烦", "闭嘴", "受够", "废话"]


def read_wav(path: Path) -> tuple[list[float], int]:
    with wave.open(str(path), 'rb') as wf:
        sr = wf.getframerate()
        n = wf.getnframes()
        raw = wf.readframes(n)
    samples = []
    for i in range(0, len(raw), 2):
        v = int.from_bytes(raw[i:i+2], byteorder='little', signed=True)
        samples.append(v / 32768.0)
    return samples, sr


def acoustic_features(samples: list[float], sr: int) -> dict[str, float]:
    n = max(len(samples), 1)
    duration = n / max(sr, 1)
    rms = math.sqrt(sum(s * s for s in samples) / n)
    peak = max(abs(s) for s in samples) if samples else 0.0

    zc = 0
    for i in range(1, n):
        if samples[i - 1] * samples[i] < 0:
            zc += 1
    zcr = zc / n

    # 简单基频估计：截断窗口 + 自相关峰值（在 70-450Hz 范围）
    # 仅使用前 2048 采样点，避免训练过慢
    window = samples[:2048] if len(samples) > 2048 else samples
    wn = len(window)
    min_lag = max(int(sr / 450), 1)
    max_lag = max(int(sr / 70), min_lag + 1)
    max_lag = min(max_lag, wn - 1) if wn > 1 else 1

    best_lag = min_lag
    best_corr = -1e9
    if wn > max_lag + 1:
        for lag in range(min_lag, max_lag):
            corr = 0.0
            m = wn - lag
            for i in range(m):
                corr += window[i] * window[i + lag]
            if corr > best_corr:
                best_corr = corr
                best_lag = lag
    f0 = sr / best_lag if best_lag > 0 else 0.0

    return {
        'rms': rms,
        'peak': peak,
        'zcr': zcr,
        'duration': duration,
        'f0_est': f0,
    }


def text_features(text: str) -> dict[str, float]:
    t = text.lower().strip()
    exclaim = t.count('!') + t.count('！')
    anger_hits = sum(1 for w in ANGER_WORDS if w in t)
    pos_hits = sum(1 for w in POS_WORDS if w in t)
    neg_hits = sum(1 for w in NEG_WORDS if w in t)
    length = len(t)
    speaking_rate_proxy = length / max(0.1, 1.8)
    return {
        'text_len': float(length),
        'exclaim': float(exclaim),
        'anger_hits': float(anger_hits),
        'pos_hits': float(pos_hits),
        'neg_hits': float(neg_hits),
        'speech_rate_proxy': speaking_rate_proxy,
    }


def sigmoid(x: float) -> float:
    if x >= 0:
        z = math.exp(-x)
        return 1 / (1 + z)
    z = math.exp(x)
    return z / (1 + z)


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    corpus_dir = root / 'training' / 'data' / 'multimodal_corpus'
    manifest = corpus_dir / 'manifest.csv'
    if not manifest.exists():
        raise FileNotFoundError(f'{manifest} not found. Run prepare_multimodal_corpus.py first.')

    rows = []
    with manifest.open('r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for r in reader:
            audio_path = corpus_dir / r['audio_relpath']
            samples, sr = read_wav(audio_path)
            feats = {}
            feats.update(acoustic_features(samples, sr))
            feats.update(text_features(r['transcript']))
            rows.append({
                'features': feats,
                'label': 1.0 if r['label'] == 'bad' else 0.0,
                'score': float(r['score']),
            })

    feature_names = sorted(rows[0]['features'].keys())
    X = [[row['features'][k] for k in feature_names] for row in rows]
    y = [row['label'] for row in rows]
    s = [row['score'] for row in rows]

    idx = list(range(len(X)))
    random.shuffle(idx)
    cut = int(0.8 * len(idx))
    train_idx, val_idx = idx[:cut], idx[cut:]

    # 标准化
    means, stds = [], []
    d = len(feature_names)
    for j in range(d):
        vals = [X[i][j] for i in train_idx]
        m = sum(vals) / len(vals)
        v = sum((x - m) ** 2 for x in vals) / len(vals)
        sd = math.sqrt(v) if v > 1e-12 else 1.0
        means.append(m)
        stds.append(sd)

    def xnorm(i: int) -> list[float]:
        return [(X[i][j] - means[j]) / stds[j] for j in range(d)]

    # 逻辑回归（梯度下降）
    w = [0.0] * d
    b = 0.0
    lr = 0.06
    epochs = 280

    for _ in range(epochs):
        gw = [0.0] * d
        gb = 0.0
        for i in train_idx:
            xi = xnorm(i)
            z = sum(w[j] * xi[j] for j in range(d)) + b
            p = sigmoid(z)
            err = p - y[i]
            for j in range(d):
                gw[j] += err * xi[j]
            gb += err
        n = len(train_idx)
        for j in range(d):
            w[j] -= lr * gw[j] / n
        b -= lr * gb / n

    def eval_split(idxs: list[int]) -> tuple[float, float]:
        correct = 0
        mae = 0.0
        for i in idxs:
            xi = xnorm(i)
            z = sum(w[j] * xi[j] for j in range(d)) + b
            p = sigmoid(z)
            pred = 1.0 if p >= 0.5 else 0.0
            if pred == y[i]:
                correct += 1
            mae += abs(p - s[i])
        return correct / len(idxs), mae / len(idxs)

    train_acc, train_mae = eval_split(train_idx)
    val_acc, val_mae = eval_split(val_idx)

    model = {
        'version': '1.0',
        'type': 'logistic_regression_multimodal',
        'feature_names': feature_names,
        'means': means,
        'stds': stds,
        'weights': w,
        'bias': b,
        'metrics': {
            'train_accuracy': train_acc,
            'train_mae': train_mae,
            'val_accuracy': val_acc,
            'val_mae': val_mae,
            'samples': len(rows),
        },
    }

    out = root / 'backend' / 'models' / 'multimodal_emotion_v1.json'
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(model, ensure_ascii=False, indent=2), encoding='utf-8')

    print(f'Saved model -> {out}')
    print(f'Train accuracy={train_acc:.4f}, MAE={train_mae:.4f}')
    print(f'Val   accuracy={val_acc:.4f}, MAE={val_mae:.4f}')


if __name__ == '__main__':
    main()
