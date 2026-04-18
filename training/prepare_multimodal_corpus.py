#!/usr/bin/env python3
"""准备多模态情绪训练语料（文本+声学）。

生成内容：
- 合成语音 wav（不同能量/基频/抖动）
- transcript 文本
- label (good/bad)
- score (0-1, 越高越负面)
"""

from __future__ import annotations

import csv
import math
import random
import struct
import wave
from pathlib import Path

random.seed(42)

SR = 16000

GOOD_TEXTS = [
    "我们慢慢说，我在听",
    "谢谢你今天的帮助",
    "先冷静一下再聊",
    "没关系我们一起想办法",
    "你辛苦了先休息一下",
]

BAD_TEXTS = [
    "你怎么又这样",
    "我现在很生气",
    "快点别废话",
    "闭嘴我受够了",
    "为什么总是你",
]

PREFIXES = ["", "请", "现在", "真的", "拜托", "麻烦你"]
SUFFIXES = ["", "。", "！", "!!", "好吗", "行吗"]


def synth_wave(path: Path, duration: float, f0: float, amp: float, jitter: float, noise: float) -> None:
    n = int(SR * duration)
    frames = []
    phase = 0.0
    for i in range(n):
        t = i / SR
        inst_f = f0 * (1 + jitter * math.sin(2 * math.pi * 3.2 * t))
        phase += 2 * math.pi * inst_f / SR
        s = math.sin(phase)
        s += 0.35 * math.sin(2 * phase)
        s += noise * random.uniform(-1.0, 1.0)
        s = max(-1.0, min(1.0, s * amp))
        frames.append(struct.pack('<h', int(s * 32767)))

    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), 'wb') as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        wf.writeframes(b''.join(frames))


def text_variant(base: str) -> str:
    return f"{random.choice(PREFIXES)}{base}{random.choice(SUFFIXES)}".strip()


def build(out_dir: Path, n_per_class: int = 60) -> Path:
    wav_dir = out_dir / 'wav'
    manifest = out_dir / 'manifest.csv'
    rows = []

    for i in range(n_per_class):
        text = text_variant(random.choice(GOOD_TEXTS))
        duration = random.uniform(1.8, 3.2)
        f0 = random.uniform(150, 210)
        amp = random.uniform(0.18, 0.38)
        jitter = random.uniform(0.01, 0.05)
        noise = random.uniform(0.005, 0.02)
        score = round(random.uniform(0.05, 0.35), 3)
        p = wav_dir / f'good_{i:04d}.wav'
        synth_wave(p, duration, f0, amp, jitter, noise)
        rows.append((str(p.relative_to(out_dir)), text, 'good', score))

    for i in range(n_per_class):
        text = text_variant(random.choice(BAD_TEXTS))
        duration = random.uniform(0.8, 2.0)
        f0 = random.uniform(220, 360)
        amp = random.uniform(0.35, 0.85)
        jitter = random.uniform(0.06, 0.18)
        noise = random.uniform(0.02, 0.08)
        score = round(random.uniform(0.65, 0.98), 3)
        p = wav_dir / f'bad_{i:04d}.wav'
        synth_wave(p, duration, f0, amp, jitter, noise)
        rows.append((str(p.relative_to(out_dir)), text, 'bad', score))

    random.shuffle(rows)
    out_dir.mkdir(parents=True, exist_ok=True)
    with manifest.open('w', encoding='utf-8', newline='') as f:
        w = csv.writer(f)
        w.writerow(['audio_relpath', 'transcript', 'label', 'score'])
        w.writerows(rows)

    return manifest


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    out_dir = root / 'training' / 'data' / 'multimodal_corpus'
    manifest = build(out_dir)
    print(f'Prepared corpus: {manifest}')


if __name__ == '__main__':
    main()
