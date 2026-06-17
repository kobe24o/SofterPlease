from __future__ import annotations

import csv
import json
import math
import random
import re
import shutil
import threading
import uuid
import wave
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

import numpy as np
import soundfile as sf


CLASSES = [-1, 0, 1]
ANGER_WORDS = ["生气", "烦", "闭嘴", "受够", "快点", "为什么", "总是", "讨厌", "恨", "够了"]
POS_WORDS = ["谢谢", "慢慢", "冷静", "一起", "辛苦", "喜欢", "开心", "很好", "不错"]
NEG_WORDS = ["生气", "烦", "闭嘴", "受够", "废话", "讨厌", "恨", "难过", "糟糕"]


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def safe_version_name(value: str | None) -> str:
    if value:
        cleaned = re.sub(r"[^a-zA-Z0-9._-]+", "-", value.strip()).strip("-._")
        if cleaned:
            return cleaned[:64]
    return datetime.now().strftime("calibrator-%Y%m%d-%H%M%S")


def text_features(text: str, duration: float) -> dict[str, float]:
    normalized = text.lower().strip()
    return {
        "text_len": float(len(normalized)),
        "exclaim": float(normalized.count("!") + normalized.count("！")),
        "anger_hits": float(sum(1 for word in ANGER_WORDS if word in normalized)),
        "pos_hits": float(sum(1 for word in POS_WORDS if word in normalized)),
        "neg_hits": float(sum(1 for word in NEG_WORDS if word in normalized)),
        "speech_rate_proxy": float(len(normalized) / max(duration, 0.1)),
    }


def audio_diagnostics(path: Path) -> dict[str, float | bool]:
    try:
        audio, sample_rate = sf.read(path, always_2d=False)
        values = np.asarray(audio, dtype=np.float64)
        if values.ndim > 1:
            values = values.mean(axis=1)
        if values.size == 0:
            raise ValueError("empty audio")
        rms = float(np.sqrt(np.mean(values * values)))
        peak = float(np.max(np.abs(values)))
        zcr = float(np.mean(values[:-1] * values[1:] < 0)) if values.size > 1 else 0.0
        duration = float(values.size / max(sample_rate, 1))

        frame_size = max(int(sample_rate * 0.04), 1)
        frame_rms = [
            float(np.sqrt(np.mean(values[index:index + frame_size] ** 2)))
            for index in range(0, values.size, frame_size)
            if values[index:index + frame_size].size
        ]
        active_threshold = max(peak * 0.03, 0.004)
        pause_ratio = float(sum(value < active_threshold for value in frame_rms) / max(len(frame_rms), 1))

        window = values[: min(values.size, 4096)]
        window = window - np.mean(window)
        min_lag = max(int(sample_rate / 450), 1)
        max_lag = min(max(int(sample_rate / 70), min_lag + 1), max(len(window) - 1, min_lag + 1))
        f0 = 0.0
        if len(window) > max_lag + 1 and np.max(np.abs(window)) > 1e-5:
            correlations = [
                float(np.dot(window[:-lag], window[lag:]))
                for lag in range(min_lag, max_lag)
            ]
            best_lag = min_lag + int(np.argmax(correlations))
            f0 = float(sample_rate / best_lag)

        return {
            "sample_rate": float(sample_rate),
            "duration": duration,
            "rms": rms,
            "peak": peak,
            "zcr": zcr,
            "f0_est": f0,
            "pitch_std": 0.0,
            "pause_ratio": pause_ratio,
            "speaking_rate": 0.0,
            "near_silent": bool(rms < 0.003 or peak < 0.015),
        }
    except Exception:
        return {
            "sample_rate": 0.0,
            "duration": 0.0,
            "rms": 0.0,
            "peak": 0.0,
            "zcr": 0.0,
            "f0_est": 0.0,
            "pitch_std": 0.0,
            "pause_ratio": 1.0,
            "speaking_rate": 0.0,
            "near_silent": True,
        }


def build_features(item: dict[str, Any], path: Path) -> dict[str, float]:
    diagnostic = audio_diagnostics(path)
    acoustic = item.get("acoustic_features", {})
    duration = float(diagnostic["duration"])
    features = {
        "rms": float(acoustic.get("energy_mean", diagnostic["rms"])),
        "peak": float(acoustic.get("energy_mean", diagnostic["rms"]))
        + float(acoustic.get("energy_std", max(float(diagnostic["peak"]) - float(diagnostic["rms"]), 0.0))),
        "zcr": float(acoustic.get("zcr_mean", diagnostic["zcr"])),
        "duration": duration,
        "f0_est": float(acoustic.get("pitch_mean", diagnostic["f0_est"])),
        "pitch_std": float(acoustic.get("pitch_std", diagnostic["pitch_std"])),
        "pause_ratio": float(acoustic.get("pause_ratio", diagnostic["pause_ratio"])),
        "speaking_rate": float(acoustic.get("speaking_rate", diagnostic["speaking_rate"])),
    }
    features.update(text_features(str(item.get("transcript", "")), duration))
    return features


def softmax(logits: list[float]) -> list[float]:
    peak = max(logits)
    values = [math.exp(value - peak) for value in logits]
    total = sum(values) or 1.0
    return [value / total for value in values]


class TrainingService:
    def __init__(
        self,
        repo_root: Path,
        debug_audio_dir: Path,
        on_model_ready: Callable[[Path, str], None] | None = None,
    ):
        self.repo_root = repo_root
        self.debug_audio_dir = debug_audio_dir
        self.synthetic_dir = repo_root / "training" / "data" / "multimodal_corpus"
        self.workspace_dir = repo_root / "backend" / "training_workspace"
        self.state_path = self.workspace_dir / "corpus_state.json"
        self.jobs_dir = self.workspace_dir / "jobs"
        self.versions_dir = repo_root / "backend" / "models" / "versions"
        self.active_model_path = repo_root / "backend" / "models" / "debug_emotion_calibrator_v1.json"
        self.on_model_ready = on_model_ready
        self._lock = threading.Lock()
        self._jobs: dict[str, dict[str, Any]] = {}
        self._active_job_id: str | None = None
        self._diagnostics_cache: dict[str, tuple[int, int, dict[str, float | bool]]] = {}

    def _diagnostic(self, path: Path) -> dict[str, float | bool]:
        try:
            stat = path.stat()
            key = str(path.resolve())
            cached = self._diagnostics_cache.get(key)
            if cached and cached[0] == stat.st_mtime_ns and cached[1] == stat.st_size:
                return cached[2]
            result = audio_diagnostics(path)
            self._diagnostics_cache[key] = (stat.st_mtime_ns, stat.st_size, result)
            return result
        except OSError:
            return audio_diagnostics(path)

    def _state(self) -> dict[str, dict[str, Any]]:
        return read_json(self.state_path, {})

    def _save_state(self, state: dict[str, dict[str, Any]]) -> None:
        write_json(self.state_path, state)

    def list_corpus(self) -> list[dict[str, Any]]:
        state = self._state()
        items: list[dict[str, Any]] = []

        for meta_path in sorted(self.debug_audio_dir.glob("*.json")):
            record = read_json(meta_path, {})
            if not record or not record.get("audio_file"):
                continue
            corpus_id = f"debug:{record['id']}"
            path = self.debug_audio_dir / record["audio_file"]
            diagnostic = self._diagnostic(path)
            override = state.get(corpus_id, {})
            label = override.get("label", record.get("human_label"))
            transcript = override.get("transcript", record.get("transcript") or record.get("result", {}).get("transcript") or "")
            items.append({
                "id": corpus_id,
                "source": record.get("source", "uploaded"),
                "kind": "uploaded",
                "filename": record.get("filename") or record["audio_file"],
                "audio_url": record.get("audio_url"),
                "audio_path": str(path),
                "created_at": record.get("created_at"),
                "speaker_id": record.get("speaker_id", "unknown"),
                "transcript": transcript,
                "label": label,
                "selected": bool(override.get("selected", False)),
                "diagnostic": diagnostic,
                "acoustic_features": record.get("result", {}).get("acoustic_features", {}),
            })

        manifest = self.synthetic_dir / "manifest.csv"
        if manifest.exists():
            with manifest.open("r", encoding="utf-8", newline="") as handle:
                for row in csv.DictReader(handle):
                    relative = row["audio_relpath"].replace("\\", "/")
                    corpus_id = f"synthetic:{relative}"
                    path = self.synthetic_dir / relative
                    override = state.get(corpus_id, {})
                    default_label = -1 if row.get("label") == "bad" else 1 if row.get("label") == "good" else 0
                    items.append({
                        "id": corpus_id,
                        "source": "synthetic",
                        "kind": "synthetic",
                        "filename": Path(relative).name,
                        "audio_url": f"/v1/training/corpus/synthetic/audio?path={relative}",
                        "audio_path": str(path),
                        "created_at": None,
                        "speaker_id": "synthetic",
                        "transcript": override.get("transcript", row.get("transcript", "")),
                        "label": override.get("label", default_label),
                        "selected": bool(override.get("selected", False)),
                        "diagnostic": self._diagnostic(path),
                        "acoustic_features": {},
                    })

        items.sort(key=lambda item: (item["kind"] != "uploaded", item.get("created_at") or "", item["filename"]), reverse=False)
        return items

    def update_corpus(
        self,
        ids: list[str],
        *,
        selected: bool | None = None,
        label: int | None = None,
        transcript: str | None = None,
    ) -> dict[str, Any]:
        state = self._state()
        for corpus_id in ids:
            override = state.setdefault(corpus_id, {})
            if selected is not None:
                override["selected"] = selected
            if label is not None:
                override["label"] = label
                override["labeled_at"] = utc_now()
            if transcript is not None:
                override["transcript"] = transcript

            if corpus_id.startswith("debug:"):
                record_id = corpus_id.split(":", 1)[1]
                meta_path = self.debug_audio_dir / f"{record_id}.json"
                record = read_json(meta_path, {})
                if record:
                    if label is not None:
                        record["human_label"] = label
                        record["labeled_at"] = utc_now()
                    if transcript is not None:
                        record["transcript"] = transcript
                    write_json(meta_path, record)
        self._save_state(state)
        return self.corpus_summary()

    def corpus_summary(self) -> dict[str, Any]:
        items = self.list_corpus()
        selected = [item for item in items if item["selected"]]
        labels = Counter(str(item["label"]) for item in selected if item["label"] is not None)
        return {
            "total": len(items),
            "selected": len(selected),
            "selected_labeled": sum(item["label"] is not None for item in selected),
            "selected_class_counts": dict(labels),
            "near_silent": sum(bool(item["diagnostic"]["near_silent"]) for item in items),
        }

    def resolve_synthetic_audio(self, relative: str) -> Path:
        candidate = (self.synthetic_dir / relative.replace("\\", "/")).resolve()
        root = self.synthetic_dir.resolve()
        if root not in candidate.parents or not candidate.is_file():
            raise FileNotFoundError(relative)
        return candidate

    def start_job(self, version_name: str | None, test_ratio: float, activate_after_training: bool) -> dict[str, Any]:
        with self._lock:
            if self._active_job_id and self._jobs.get(self._active_job_id, {}).get("status") in {"queued", "running"}:
                raise RuntimeError("a training job is already running")
            job_id = str(uuid.uuid4())
            version = safe_version_name(version_name)
            job = {
                "id": job_id,
                "version": version,
                "status": "queued",
                "stage": "queued",
                "progress": 0,
                "message": "训练任务已创建",
                "logs": [],
                "created_at": utc_now(),
                "updated_at": utc_now(),
                "test_ratio": test_ratio,
                "activate_after_training": activate_after_training,
                "metrics": None,
                "model_path": None,
            }
            self._jobs[job_id] = job
            self._active_job_id = job_id
            self._save_job(job)
            thread = threading.Thread(target=self._run_job, args=(job_id,), daemon=True)
            thread.start()
            return dict(job)

    def _save_job(self, job: dict[str, Any]) -> None:
        write_json(self.jobs_dir / f"{job['id']}.json", job)

    def _update_job(self, job_id: str, **changes: Any) -> None:
        with self._lock:
            job = self._jobs[job_id]
            message = changes.get("message")
            if message and (not job["logs"] or job["logs"][-1] != message):
                job["logs"].append(message)
                job["logs"] = job["logs"][-80:]
            job.update(changes)
            job["updated_at"] = utc_now()
            self._save_job(job)

    def get_job(self, job_id: str | None = None) -> dict[str, Any] | None:
        with self._lock:
            resolved = job_id or self._active_job_id
            if resolved and resolved in self._jobs:
                return dict(self._jobs[resolved])
        if job_id:
            job = read_json(self.jobs_dir / f"{job_id}.json", None)
            return job
        job_paths = sorted(self.jobs_dir.glob("*.json"), key=lambda path: path.stat().st_mtime, reverse=True)
        return read_json(job_paths[0], None) if job_paths else None

    def _run_job(self, job_id: str) -> None:
        try:
            self._update_job(job_id, status="running", stage="collecting", progress=2, message="读取已勾选且已标注的语料")
            items = [item for item in self.list_corpus() if item["selected"] and item["label"] is not None]
            counts = Counter(int(item["label"]) for item in items)
            missing = [label for label in CLASSES if counts[label] < 2]
            if missing:
                raise ValueError(f"每类至少需要 2 条已勾选语料，当前={dict(counts)}，不足={missing}")

            rows = []
            for index, item in enumerate(items):
                path = Path(item["audio_path"])
                if item["diagnostic"]["near_silent"]:
                    raise ValueError(f"已选语料近似静音，请取消勾选或重新录制：{item['filename']}")
                rows.append({
                    "id": item["id"],
                    "label": int(item["label"]),
                    "features": build_features(item, path),
                })
                progress = 5 + int(20 * (index + 1) / len(items))
                self._update_job(job_id, stage="features", progress=progress, message=f"提取特征 {index + 1}/{len(items)}")

            rng = random.Random(42)
            train_rows: list[dict[str, Any]] = []
            test_rows: list[dict[str, Any]] = []
            ratio = float(self._jobs[job_id]["test_ratio"])
            for label in CLASSES:
                group = [row for row in rows if row["label"] == label]
                rng.shuffle(group)
                test_count = max(1, min(len(group) - 1, round(len(group) * ratio)))
                test_rows.extend(group[:test_count])
                train_rows.extend(group[test_count:])
            rng.shuffle(train_rows)
            rng.shuffle(test_rows)
            self._update_job(
                job_id,
                stage="split",
                progress=28,
                message=f"自动分层切分完成：训练集 {len(train_rows)}，测试集 {len(test_rows)}",
            )

            feature_names = sorted(train_rows[0]["features"])
            dimensions = len(feature_names)
            x_train = [[row["features"][name] for name in feature_names] for row in train_rows]
            means = [sum(row[index] for row in x_train) / len(x_train) for index in range(dimensions)]
            stds = []
            for index in range(dimensions):
                variance = sum((row[index] - means[index]) ** 2 for row in x_train) / len(x_train)
                stds.append(math.sqrt(variance) if variance > 1e-12 else 1.0)

            def normalize(row: dict[str, Any]) -> list[float]:
                return [
                    (float(row["features"][feature_names[index]]) - means[index]) / stds[index]
                    for index in range(dimensions)
                ]

            weights = [[0.0] * dimensions for _ in CLASSES]
            biases = [0.0] * len(CLASSES)
            learning_rate = 0.04
            epochs = 700
            normalized_train = [(normalize(row), CLASSES.index(row["label"])) for row in train_rows]
            for epoch in range(epochs):
                grad_w = [[0.0] * dimensions for _ in CLASSES]
                grad_b = [0.0] * len(CLASSES)
                for values, target in normalized_train:
                    probabilities = softmax([
                        sum(weight * value for weight, value in zip(class_weights, values)) + biases[class_index]
                        for class_index, class_weights in enumerate(weights)
                    ])
                    for class_index in range(len(CLASSES)):
                        error = probabilities[class_index] - (1.0 if class_index == target else 0.0)
                        grad_b[class_index] += error
                        for feature_index in range(dimensions):
                            grad_w[class_index][feature_index] += error * values[feature_index]
                for class_index in range(len(CLASSES)):
                    biases[class_index] -= learning_rate * grad_b[class_index] / len(normalized_train)
                    for feature_index in range(dimensions):
                        weights[class_index][feature_index] -= learning_rate * grad_w[class_index][feature_index] / len(normalized_train)
                if epoch % 35 == 0 or epoch == epochs - 1:
                    progress = 30 + int(58 * (epoch + 1) / epochs)
                    self._update_job(job_id, stage="training", progress=progress, message=f"训练轮次 {epoch + 1}/{epochs}")

            def evaluate(split: list[dict[str, Any]]) -> tuple[float, dict[str, dict[str, int]]]:
                correct = 0
                matrix = {str(label): {str(pred): 0 for pred in CLASSES} for label in CLASSES}
                for row in split:
                    values = normalize(row)
                    probabilities = softmax([
                        sum(weight * value for weight, value in zip(class_weights, values)) + biases[class_index]
                        for class_index, class_weights in enumerate(weights)
                    ])
                    predicted = CLASSES[max(range(len(CLASSES)), key=probabilities.__getitem__)]
                    matrix[str(row["label"])][str(predicted)] += 1
                    correct += int(predicted == row["label"])
                return correct / max(len(split), 1), matrix

            train_accuracy, train_matrix = evaluate(train_rows)
            test_accuracy, test_matrix = evaluate(test_rows)
            version = self._jobs[job_id]["version"]
            model_path = self.versions_dir / f"{version}.json"
            model = {
                "version": version,
                "created_at": utc_now(),
                "type": "softmax_regression_triclass",
                "classes": CLASSES,
                "feature_names": feature_names,
                "means": means,
                "stds": stds,
                "weights": weights,
                "biases": biases,
                "metrics": {
                    "samples": len(rows),
                    "train_samples": len(train_rows),
                    "test_samples": len(test_rows),
                    "class_counts": {str(key): value for key, value in counts.items()},
                    "train_accuracy": train_accuracy,
                    "test_accuracy": test_accuracy,
                    "train_confusion_matrix": train_matrix,
                    "test_confusion_matrix": test_matrix,
                },
                "training": {
                    "test_ratio": ratio,
                    "selected_ids": [row["id"] for row in rows],
                    "train_ids": [row["id"] for row in train_rows],
                    "test_ids": [row["id"] for row in test_rows],
                },
            }
            write_json(model_path, model)
            if self._jobs[job_id]["activate_after_training"]:
                shutil.copyfile(model_path, self.active_model_path)
                if self.on_model_ready:
                    self.on_model_ready(model_path, version)
            self._update_job(
                job_id,
                status="completed",
                stage="completed",
                progress=100,
                message=f"训练完成，测试准确率 {test_accuracy:.3f}",
                metrics=model["metrics"],
                model_path=str(model_path),
            )
        except Exception as exc:
            self._update_job(job_id, status="failed", stage="failed", progress=100, message=str(exc), error=str(exc))

    def list_models(self) -> list[dict[str, Any]]:
        active_payload = read_json(self.active_model_path, {})
        active_version = active_payload.get("version")
        models = []
        for path in sorted(self.versions_dir.glob("*.json"), key=lambda item: item.stat().st_mtime, reverse=True):
            payload = read_json(path, {})
            models.append({
                "version": payload.get("version", path.stem),
                "created_at": payload.get("created_at"),
                "metrics": payload.get("metrics", {}),
                "path": str(path),
                "active": payload.get("version", path.stem) == active_version,
            })
        return models

    def activate_model(self, version: str) -> Path:
        path = self.versions_dir / f"{safe_version_name(version)}.json"
        if not path.exists():
            raise FileNotFoundError(version)
        shutil.copyfile(path, self.active_model_path)
        if self.on_model_ready:
            self.on_model_ready(path, version)
        return path
