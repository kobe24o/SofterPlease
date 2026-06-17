from app.emotion_engine.emotion_analyzer import EmotionAnalyzer


def test_sensevoice_is_default_backend(monkeypatch):
    monkeypatch.delenv("EMOTION_BACKEND", raising=False)

    analyzer = EmotionAnalyzer()

    assert analyzer.backend == "sensevoice"
    status = analyzer.get_status()
    assert status["sensevoice_model_id"] == "iic/SenseVoiceSmall"
    assert status["sensevoice_loaded"] is False


def test_emotion2vec_backend_can_be_selected(monkeypatch):
    monkeypatch.setenv("EMOTION_BACKEND", "emotion2vec")

    analyzer = EmotionAnalyzer()

    assert analyzer.backend == "emotion2vec"
    status = analyzer.get_status()
    assert status["emotion2vec_model_id"] == "iic/emotion2vec_plus_large"
    assert status["emotion2vec_loaded"] is False


def test_emotion2vec_score_parser_normalizes_funasr_labels():
    analyzer = EmotionAnalyzer()
    result = [{
        "labels": [
            "生气/angry",
            "厌恶/disgusted",
            "恐惧/fearful",
            "开心/happy",
            "中立/neutral",
            "其他/other",
            "难过/sad",
            "<unk>",
        ],
        "scores": [0.1, 0.2, 0.3, 0.8, 0.4, 0.05, 0.15, 0.01],
    }]

    scores = analyzer._extract_emotion2vec_scores(result)

    assert scores["angry"] == 0.1
    assert scores["disgusted"] == 0.2
    assert scores["fearful"] == 0.3
    assert scores["happy"] == 0.8
    assert scores["neutral"] == 0.4
    assert scores["other"] == 0.05
    assert scores["sad"] == 0.15
    assert scores["unknown"] == 0.01
