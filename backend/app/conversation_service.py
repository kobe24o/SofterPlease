from __future__ import annotations

from dataclasses import dataclass

import librosa
import numpy as np
from sklearn.cluster import AgglomerativeClustering


MAX_MODEL_SEGMENT_SECONDS = 25.0
MAX_DIARIZATION_SEGMENT_SECONDS = 8.0
MAX_RECORDING_SECONDS = 600.0


@dataclass(frozen=True)
class AudioSlice:
    start_sample: int
    end_sample: int
    audio: np.ndarray

    def start_ms(self, sample_rate: int) -> int:
        return round(self.start_sample * 1000 / sample_rate)

    def end_ms(self, sample_rate: int) -> int:
        return round(self.end_sample * 1000 / sample_rate)


@dataclass(frozen=True)
class SpeakerMatch:
    speaker_id: str
    confidence: float
    runner_up_confidence: float


class ConversationService:
    REGISTERED_PROFILE_THRESHOLD = 0.60
    AUTO_PROFILE_THRESHOLD = 0.52
    AUTO_PROFILE_MARGIN = 0.08

    def __init__(self, max_segment_seconds: float = MAX_DIARIZATION_SEGMENT_SECONDS) -> None:
        self.max_segment_seconds = max_segment_seconds

    def split_audio(self, audio: np.ndarray, sample_rate: int) -> list[AudioSlice]:
        mono = np.asarray(audio, dtype=np.float32).reshape(-1)
        if mono.size == 0:
            return []
        intervals = librosa.effects.split(mono, top_db=28, frame_length=1024, hop_length=256)
        if intervals.size == 0:
            return []

        max_gap = round(0.35 * sample_rate)
        padding = round(0.12 * sample_rate)
        min_samples = round(0.45 * sample_rate)
        max_samples = max(1, round(self.max_segment_seconds * sample_rate))
        merged: list[list[int]] = []
        for raw_start, raw_end in intervals:
            start = max(0, int(raw_start) - padding)
            end = min(mono.size, int(raw_end) + padding)
            if merged and start - merged[-1][1] <= max_gap:
                merged[-1][1] = end
            else:
                merged.append([start, end])

        slices: list[AudioSlice] = []
        for start, end in merged:
            cursor = start
            while cursor < end:
                cut = min(cursor + max_samples, end)
                if end - cut < min_samples:
                    cut = end
                if cut - cursor >= min_samples:
                    slices.append(AudioSlice(cursor, cut, mono[cursor:cut].copy()))
                cursor = cut
        return slices

    @staticmethod
    def cosine_similarity(left: np.ndarray, right: np.ndarray) -> float:
        a = np.asarray(left, dtype=np.float32).reshape(-1)
        b = np.asarray(right, dtype=np.float32).reshape(-1)
        if a.size != b.size or not a.size:
            return 0.0
        denominator = float(np.linalg.norm(a) * np.linalg.norm(b))
        return float(np.dot(a, b) / denominator) if denominator > 1e-8 else 0.0

    def cluster_embeddings(self, embeddings: list[np.ndarray]) -> list[str]:
        if not embeddings:
            return []
        if len(embeddings) == 1:
            return ["speaker_1"]
        matrix = np.asarray(embeddings, dtype=np.float32)
        matrix /= np.maximum(np.linalg.norm(matrix, axis=1, keepdims=True), 1e-8)
        labels = AgglomerativeClustering(
            n_clusters=None,
            distance_threshold=0.40,
            metric="cosine",
            linkage="average",
        ).fit_predict(matrix)
        stable_names: dict[int, str] = {}
        result: list[str] = []
        for label in labels.tolist():
            stable_names.setdefault(label, f"speaker_{len(stable_names) + 1}")
            result.append(stable_names[label])
        return result

    def match_speaker_profile(
        self,
        embedding: np.ndarray,
        profiles: dict[str, np.ndarray],
        auto_profile_ids: set[str],
    ) -> SpeakerMatch | None:
        scored = sorted(
            (
                (speaker_id, self.cosine_similarity(embedding, profile_embedding))
                for speaker_id, profile_embedding in profiles.items()
            ),
            key=lambda item: item[1],
            reverse=True,
        )
        if not scored:
            return None

        best_id, best_score = scored[0]
        runner_up = scored[1][1] if len(scored) > 1 else 0.0
        if best_id in auto_profile_ids:
            if best_score >= self.AUTO_PROFILE_THRESHOLD and best_score - runner_up >= self.AUTO_PROFILE_MARGIN:
                return SpeakerMatch(best_id, best_score, runner_up)
            return None
        if best_score >= self.REGISTERED_PROFILE_THRESHOLD:
            return SpeakerMatch(best_id, best_score, runner_up)
        return None

    @staticmethod
    def update_speaker_centroid(
        existing: np.ndarray,
        new_embedding: np.ndarray,
        existing_sample_count: int,
    ) -> np.ndarray:
        old = np.asarray(existing, dtype=np.float32).reshape(-1)
        new = np.asarray(new_embedding, dtype=np.float32).reshape(-1)
        if old.size != new.size or not new.size:
            return new
        old /= max(float(np.linalg.norm(old)), 1e-8)
        new /= max(float(np.linalg.norm(new)), 1e-8)
        count = max(int(existing_sample_count), 1)
        updated = (old * count + new) / (count + 1)
        return updated / max(float(np.linalg.norm(updated)), 1e-8)
