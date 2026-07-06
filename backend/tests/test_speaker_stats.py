from datetime import datetime, timezone
import uuid

from fastapi.testclient import TestClient

from app.db import SessionLocal
from app.main import app
from app.models import ConversationSegment


def auth_header(client: TestClient, user_id: str) -> dict[str, str]:
    login = client.post("/v1/auth/login", json={"user_id": user_id})
    return {"Authorization": f"Bearer {login.json()['access_token']}"}


def test_speaker_rename_stats_and_record_drilldown():
    client = TestClient(app)
    owner = client.post("/v1/users", json={"nickname": "统计用户"}).json()["user_id"]
    headers = auth_header(client, owner)
    family_id = client.post("/v1/families", json={"name": "统计家庭"}, headers=headers).json()["family_id"]
    session_id = client.post(
        "/v1/sessions/start",
        json={"family_id": family_id, "device_id": "speaker-test"},
        headers=headers,
    ).json()["session_id"]
    segment_id = str(uuid.uuid4())
    with SessionLocal() as db:
        db.add(ConversationSegment(
            id=segment_id,
            session_id=session_id,
            family_id=family_id,
            sequence_index=0,
            started_at_ms=0,
            ended_at_ms=1200,
            created_at=datetime.now(timezone.utc),
            audio_storage_path="missing-test.wav",
            transcript="今天沟通得很好",
            emotion_value=1,
            emotion_label="happy",
            speaker_embedding=[1.0, 0.0, 0.0],
            speaker_cluster="speaker_legacy",
        ))
        db.commit()

    stats = client.get(f"/v1/families/{family_id}/speaker-stats", headers=headers)
    assert stats.status_code == 200
    legacy = stats.json()["speakers"][0]
    assert legacy["speaker_id"] == "speaker_legacy"
    assert legacy["emotion_score"] == 1
    assert legacy["daily"][0]["emotion_counts"]["positive"] == 1

    renamed = client.patch(
        f"/v1/families/{family_id}/speakers/speaker_legacy",
        json={"display_name": "妈妈"},
        headers=headers,
    )
    assert renamed.status_code == 200
    stable_id = renamed.json()["speaker_id"]
    assert stable_id.startswith("spk_")

    records = client.get(
        f"/v1/families/{family_id}/speaker-records",
        params={"speaker_id": stable_id},
        headers=headers,
    )
    assert records.status_code == 200
    assert records.json()["display_name"] == "妈妈"
    assert records.json()["items"][0]["transcript"] == "今天沟通得很好"
