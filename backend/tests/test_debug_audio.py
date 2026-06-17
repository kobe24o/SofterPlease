import json

from fastapi.testclient import TestClient

import app.main as main_module


def test_debug_audio_can_be_listed_and_labeled(tmp_path, monkeypatch):
    monkeypatch.setattr(main_module, "DEBUG_AUDIO_DIR", tmp_path)
    record_id = "debug-record"
    (tmp_path / "sample.wav").write_bytes(b"RIFF")
    (tmp_path / f"{record_id}.json").write_text(
        json.dumps(
            {
                "id": record_id,
                "created_at": "2026-06-04T00:00:00+00:00",
                "audio_file": "sample.wav",
                "audio_url": f"/v1/debug/audio/{record_id}/file",
                "result": {"emotion_value": 0},
            }
        ),
        encoding="utf-8",
    )

    client = TestClient(main_module.app)
    listed = client.get("/v1/debug/audio")
    labeled = client.post(
        f"/v1/debug/audio/{record_id}/label",
        json={"label": -1, "note": "manual review"},
    )

    assert listed.status_code == 200
    assert listed.json()["items"][0]["id"] == record_id
    assert labeled.status_code == 200
    assert labeled.json()["human_label"] == -1
