import csv
import math
import struct
import time
import wave
from pathlib import Path

from app.training_service import TrainingService


def write_tone(path: Path, frequency: float) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    sample_rate = 16000
    frames = [
        struct.pack("<h", int(math.sin(2 * math.pi * frequency * index / sample_rate) * 8000))
        for index in range(sample_rate // 4)
    ]
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(b"".join(frames))


def test_training_service_selects_splits_versions_and_loads(tmp_path):
    corpus_dir = tmp_path / "training" / "data" / "multimodal_corpus"
    manifest = corpus_dir / "manifest.csv"
    rows = []
    for label, numeric, frequency in [("bad", -1, 300), ("neutral", 0, 220), ("good", 1, 160)]:
        for index in range(2):
            relative = f"wav/{label}_{index}.wav"
            write_tone(corpus_dir / relative, frequency + index)
            rows.append((relative, f"{label} text {index}", label, 0.5))
    manifest.parent.mkdir(parents=True, exist_ok=True)
    with manifest.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["audio_relpath", "transcript", "label", "score"])
        writer.writerows(rows)

    activated = []
    service = TrainingService(tmp_path, tmp_path / "backend" / "debug_audio", lambda path, version: activated.append((path, version)))
    items = service.list_corpus()
    service.update_corpus([item["id"] for item in items], selected=True)
    job = service.start_job("test-version", 0.5, True)

    deadline = time.time() + 15
    while time.time() < deadline:
        status = service.get_job(job["id"])
        if status["status"] in {"completed", "failed"}:
            break
        time.sleep(0.05)

    assert status["status"] == "completed"
    assert status["metrics"]["train_samples"] == 3
    assert status["metrics"]["test_samples"] == 3
    assert service.list_models()[0]["version"] == "test-version"
    assert activated[0][1] == "test-version"
