import numpy as np

from app.emotion_engine.emotion_analyzer import EmotionAnalyzer


class MockSenseVoice:
    def __init__(self, text: str):
        self.text = text

    def generate(self, **_kwargs):
        return [{"text": self.text}]


def make_analyzer(text: str) -> EmotionAnalyzer:
    analyzer = EmotionAnalyzer(device="cpu")
    analyzer.multimodal_model = None
    analyzer.tri_class_model = None
    analyzer._sensevoice_model = MockSenseVoice(text)
    return analyzer


def test_sensevoice_is_default_backend(monkeypatch):
    monkeypatch.delenv("EMOTION_BACKEND", raising=False)

    analyzer = EmotionAnalyzer(device="cpu")

    assert analyzer.backend == "sensevoice"


def test_neutral_sensevoice_uses_direct_model_output():
    analyzer = make_analyzer("<|zh|><|NEUTRAL|><|Speech|>我真的生气了，别再说了！")
    features = {
        "pitch_mean": 260.0,
        "pitch_std": 55.0,
        "energy_mean": 0.35,
        "energy_std": 0.12,
        "zcr_mean": 0.12,
        "speaking_rate": 4.8,
        "pause_ratio": 0.08,
        "spectral_centroid_mean": 3200.0,
        "duration": 2.0,
    }

    result = analyzer._sensevoice_based_analysis(
        np.zeros(32000, dtype=np.float32),
        "",
        features,
    )

    assert result.emotion_value == 0
    assert result.model_backend == "sensevoice"
    assert result.raw_emotions == {
        "happy": 0.02,
        "sad": 0.02,
        "angry": 0.02,
        "neutral": 0.9,
    }
    assert result.transcript == "我真的生气了，别再说了！"


def test_happy_and_angry_sensevoice_tags_map_directly():
    features = {"energy_mean": 0.1, "energy_std": 0.02, "pitch_mean": 180.0}

    happy = make_analyzer("<|zh|><|HAPPY|><|Speech|>谢谢你")._sensevoice_based_analysis(
        np.zeros(16000, dtype=np.float32),
        "",
        features,
    )
    angry = make_analyzer("<|zh|><|ANGRY|><|Speech|>别说了")._sensevoice_based_analysis(
        np.zeros(16000, dtype=np.float32),
        "",
        features,
    )

    assert happy.emotion_value == 1
    assert happy.model_backend == "sensevoice"
    assert angry.emotion_value == -1
    assert angry.model_backend == "sensevoice"


def test_sad_sensevoice_short_greeting_is_guarded_to_neutral():
    features = {"energy_mean": 0.1, "energy_std": 0.02, "pitch_mean": 180.0}
    result = make_analyzer("<|zh|><|SAD|><|Speech|>你好你好。")._sensevoice_based_analysis(
        np.zeros(16000, dtype=np.float32),
        "",
        features,
    )

    assert result.emotion_value == 0
    assert result.model_backend == "sensevoice"
    assert result.raw_emotions["neutral"] == 0.9
    assert result.transcript == "你好你好。"


def test_sad_sensevoice_negative_text_stays_negative():
    features = {"energy_mean": 0.1, "energy_std": 0.02, "pitch_mean": 180.0}
    result = make_analyzer("<|zh|><|SAD|><|Speech|>作业怎么又没写完？")._sensevoice_based_analysis(
        np.zeros(16000, dtype=np.float32),
        "",
        features,
    )

    assert result.emotion_value == -1
    assert result.raw_emotions["sad"] == 0.9


def test_sensevoice_load_failure_does_not_fallback_to_rules(monkeypatch):
    analyzer = EmotionAnalyzer(device="cpu")
    monkeypatch.setattr(analyzer, "_ensure_sensevoice_model", lambda: False)
    monkeypatch.setattr(
        analyzer,
        "_rule_based_analysis",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("rules should not run")),
    )

    result = analyzer.analyze(np.zeros(16000, dtype=np.float32), transcript="你好你好", sr=16000)

    assert result.emotion_value == 0
    assert result.confidence == 0.0
    assert result.model_backend == "sensevoice_unavailable"
