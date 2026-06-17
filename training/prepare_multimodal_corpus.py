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
import argparse
import base64
import math
import os
import random
import shutil
import struct
import subprocess
import tempfile
import wave
from pathlib import Path

import librosa
import soundfile as sf

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

NEUTRAL_TEXTS = [
    "我知道了",
    "今天晚饭吃什么",
    "等一下再说",
    "我现在在客厅",
    "这件事晚点处理",
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


def windows_tts_available() -> bool:
    return os.name == "nt" and shutil.which("powershell") is not None


def synthesize_windows_tts(path: Path, text: str, rate: int, volume: int, pitch_steps: float) -> None:
    script = (
        "Add-Type -AssemblyName System.Speech; "
        "$s=New-Object System.Speech.Synthesis.SpeechSynthesizer; "
        "$s.SelectVoice($env:SOFTERPLEASE_TTS_VOICE); "
        "$s.Rate=[int]$env:SOFTERPLEASE_TTS_RATE; "
        "$s.Volume=[int]$env:SOFTERPLEASE_TTS_VOLUME; "
        "$s.SetOutputToWaveFile($env:SOFTERPLEASE_TTS_PATH); "
        "$text=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:SOFTERPLEASE_TTS_TEXT_B64)); "
        "$s.Speak($text); "
        "$s.Dispose();"
    )
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as temp:
        temp_path = Path(temp.name)
    temp_path.unlink(missing_ok=True)
    env = os.environ.copy()
    env.update({
        "SOFTERPLEASE_TTS_VOICE": os.getenv("SOFTERPLEASE_TTS_VOICE", "Microsoft Huihui Desktop"),
        "SOFTERPLEASE_TTS_RATE": str(rate),
        "SOFTERPLEASE_TTS_VOLUME": str(volume),
        "SOFTERPLEASE_TTS_PATH": str(temp_path),
        "SOFTERPLEASE_TTS_TEXT_B64": base64.b64encode(text.encode("utf-8")).decode("ascii"),
    })
    try:
        subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
            check=True,
            env=env,
            capture_output=True,
            text=True,
        )
        audio, sample_rate = sf.read(temp_path, always_2d=False)
        audio = librosa.to_mono(audio.T) if getattr(audio, "ndim", 1) > 1 else audio
        audio = librosa.resample(audio, orig_sr=sample_rate, target_sr=SR)
        if audio.size == 0:
            raise RuntimeError("system TTS produced an empty audio file")
        if pitch_steps:
            audio = librosa.effects.pitch_shift(audio, sr=SR, n_steps=pitch_steps)
        peak = max(float(abs(audio).max()), 1e-6)
        audio = audio * min(0.9 / peak, 1.8)
        path.parent.mkdir(parents=True, exist_ok=True)
        sf.write(path, audio, SR, subtype="PCM_16")
    finally:
        temp_path.unlink(missing_ok=True)


def synthesize_sample(path: Path, text: str, label: str, mode: str, speaker: int) -> str:
    use_tts = mode == "tts" or (mode == "auto" and windows_tts_available())
    if use_tts:
        try:
            rate_ranges = {"good": (-2, 1), "neutral": (-1, 1), "bad": (1, 4)}
            volume_ranges = {"good": (65, 85), "neutral": (60, 80), "bad": (80, 100)}
            pitch_profiles = [-2.5, -1.0, 0.0, 1.5, 3.0]
            synthesize_windows_tts(
                path,
                text,
                random.randint(*rate_ranges[label]),
                random.randint(*volume_ranges[label]),
                pitch_profiles[speaker % len(pitch_profiles)],
            )
            return "windows-system-tts"
        except Exception:
            if mode == "tts":
                raise

    profiles = {
        "good": (random.uniform(1.8, 3.2), random.uniform(150, 210), random.uniform(0.18, 0.38), random.uniform(0.01, 0.05), random.uniform(0.005, 0.02)),
        "neutral": (random.uniform(1.4, 2.8), random.uniform(160, 240), random.uniform(0.18, 0.42), random.uniform(0.02, 0.07), random.uniform(0.008, 0.025)),
        "bad": (random.uniform(0.8, 2.0), random.uniform(220, 360), random.uniform(0.35, 0.85), random.uniform(0.06, 0.18), random.uniform(0.02, 0.08)),
    }
    synth_wave(path, *profiles[label])
    return "tone-fallback-not-speech"


def build(out_dir: Path, n_per_class: int = 60, mode: str = "auto") -> Path:
    wav_dir = out_dir / 'wav'
    manifest = out_dir / 'manifest.csv'
    rows = []

    classes = [
        ("good", GOOD_TEXTS, (0.05, 0.35)),
        ("neutral", NEUTRAL_TEXTS, (0.42, 0.58)),
        ("bad", BAD_TEXTS, (0.65, 0.98)),
    ]
    for label, texts, score_range in classes:
        for i in range(n_per_class):
            text = text_variant(random.choice(texts))
            score = round(random.uniform(*score_range), 3)
            speaker = i % 5
            path = wav_dir / f"{label}_{i:04d}.wav"
            synthesis = synthesize_sample(path, text, label, mode, speaker)
            rows.append((str(path.relative_to(out_dir)), text, label, score, f"voice-{speaker + 1}", synthesis))

    random.shuffle(rows)
    out_dir.mkdir(parents=True, exist_ok=True)
    with manifest.open('w', encoding='utf-8', newline='') as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(['audio_relpath', 'transcript', 'label', 'score', 'speaker', 'synthesis'])
        w.writerows(rows)

    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["auto", "tts", "tones"], default="auto")
    parser.add_argument("--per-class", type=int, default=60)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out_dir = root / 'training' / 'data' / 'multimodal_corpus'
    manifest = build(out_dir, n_per_class=args.per_class, mode=args.mode)
    print(f'Prepared corpus: {manifest} mode={args.mode}')


if __name__ == '__main__':
    main()
