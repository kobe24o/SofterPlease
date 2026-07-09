from datetime import datetime, timezone
import uuid

from fastapi.testclient import TestClient

from app.db import SessionLocal
from app.main import app
from app.models import ConversationSegment, EmotionEvent, SpeakerIdentity


def auth_header(client: TestClient, user_id: str) -> dict[str, str]:
    login = client.post("/v1/auth/login", json={"user_id": user_id})
    return {"Authorization": f"Bearer {login.json()['access_token']}"}


def test_local_family_member_assignment_and_speaker_data_reset():
    client = TestClient(app)
    owner = client.post("/v1/users", json={"nickname": "owner"}).json()["user_id"]
    headers = auth_header(client, owner)
    family_id = client.post("/v1/families", json={"name": "family"}, headers=headers).json()["family_id"]
    child = client.post(
        f"/v1/families/{family_id}/local-members",
        json={"display_name": "child"},
        headers=headers,
    )
    assert child.status_code == 200
    child_id = child.json()["user_id"]

    family = client.get(f"/v1/families/{family_id}", headers=headers).json()
    assert any(member["user_id"] == child_id for member in family["members"])

    session_id = client.post(
        "/v1/sessions/start",
        json={"family_id": family_id, "device_id": "speaker-reset-test"},
        headers=headers,
    ).json()["session_id"]
    segment_id = str(uuid.uuid4())
    with SessionLocal() as db:
        event = EmotionEvent(
            session_id=session_id,
            family_id=family_id,
            speaker_id="spk_auto",
            speaker_confidence=0.9,
            transcript="hello",
            anger_score=0.1,
            emotion_level="calm",
        )
        db.add(event)
        db.flush()
        event_id = event.id
        db.add(ConversationSegment(
            id=segment_id,
            session_id=session_id,
            family_id=family_id,
            emotion_event_id=event_id,
            sequence_index=0,
            started_at_ms=0,
            ended_at_ms=1200,
            created_at=datetime.now(timezone.utc),
            audio_storage_path="missing-test.wav",
            transcript="hello",
            emotion_value=0,
            emotion_label="neutral",
            speaker_embedding=[1.0, 0.0, 0.0],
            speaker_cluster="speaker_1",
            predicted_speaker_id="spk_auto",
            speaker_confidence=0.9,
        ))
        db.add(SpeakerIdentity(
            id="spk_auto",
            family_id=family_id,
            display_name="auto",
            voice_embedding=[1.0, 0.0, 0.0],
            sample_count=1,
        ))
        db.commit()

    assigned = client.patch(
        f"/v1/conversation-segments/{segment_id}/speaker",
        json={"user_id": child_id, "learn_voice": False},
        headers=headers,
    )
    assert assigned.status_code == 200
    assert assigned.json()["segment"]["resolved_speaker_id"] == child_id
    with SessionLocal() as db:
        assert db.get(EmotionEvent, event_id).speaker_id == child_id

    voice_reset = client.delete(
        f"/v1/families/{family_id}/speaker-data",
        params={"scope": "voice"},
        headers=headers,
    )
    assert voice_reset.status_code == 200
    with SessionLocal() as db:
        segment = db.get(ConversationSegment, segment_id)
        assert segment.corrected_speaker_id == child_id
        assert db.get(SpeakerIdentity, "spk_auto") is None

    all_reset = client.delete(
        f"/v1/families/{family_id}/speaker-data",
        params={"scope": "all"},
        headers=headers,
    )
    assert all_reset.status_code == 200
    with SessionLocal() as db:
        segment = db.get(ConversationSegment, segment_id)
        event = db.get(EmotionEvent, event_id)
        assert segment.corrected_speaker_id is None
        assert segment.predicted_speaker_id is None
        assert segment.role_confirmed is False
        assert event.speaker_id == "unknown"
