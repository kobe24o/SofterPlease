from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient

from app.main import app


def auth(user_id: str) -> dict[str, str]:
    return {'x-user-id': user_id}


def test_phase2_end_to_end_with_tenant_scope():
    client = TestClient(app)

    owner = client.post('/v1/users', json={'nickname': '爸爸'}).json()['user_id']
    member = client.post('/v1/users', json={'nickname': '妈妈'}).json()['user_id']

    family_resp = client.post('/v1/families', json={'name': '示例家庭'}, headers=auth(owner))
    assert family_resp.status_code == 200
    family_id = family_resp.json()['family_id']

    add_member = client.post(f'/v1/families/{family_id}/members', json={'user_id': member, 'role': 'member'}, headers=auth(owner))
    assert add_member.status_code == 200

    start_resp = client.post('/v1/sessions/start', json={'family_id': family_id, 'device_id': 'web1'}, headers=auth(member))
    assert start_resp.status_code == 200
    session_id = start_resp.json()['session_id']

    with client.websocket_connect('/v1/realtime/ws') as ws:
        ws.send_json({'session_id': session_id, 'speaker_id': 'member_a', 'anger_score': 0.83, 'transcript': '你怎么还没做完'})
        feedback = ws.receive_json()
        action = client.post('/v1/feedback/actions', json={'feedback_token': feedback['feedback_token'], 'action': 'accepted'}, headers=auth(owner))
        assert action.status_code == 200

        ws.send_json({'session_id': session_id, 'speaker_id': 'member_a', 'anger_score': 0.45, 'transcript': '我们慢慢说'})
        _ = ws.receive_json()

    paged = client.get(f'/v1/sessions/{session_id}/events?limit=1&offset=0', headers=auth(owner))
    assert paged.status_code == 200
    assert paged.json()['total'] >= 2

    speaker_resp = client.get(f'/v1/reports/speaker/{session_id}/member_a', headers=auth(member))
    assert speaker_resp.status_code == 200

    family_daily = client.get(f'/v1/reports/family/{family_id}/daily', headers=auth(owner))
    assert family_daily.status_code == 200

    start = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    end = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
    range_resp = client.get(f'/v1/reports/family/{family_id}/range', params={'start': start, 'end': end}, headers=auth(owner))
    assert range_resp.status_code == 200


def test_tenant_forbidden_for_non_member_and_missing_auth():
    client = TestClient(app)

    owner = client.post('/v1/users', json={'nickname': '爸爸'}).json()['user_id']
    outsider = client.post('/v1/users', json={'nickname': '路人'}).json()['user_id']

    family_id = client.post('/v1/families', json={'name': '示例家庭'}, headers=auth(owner)).json()['family_id']
    session_id = client.post('/v1/sessions/start', json={'family_id': family_id, 'device_id': 'web1'}, headers=auth(owner)).json()['session_id']

    no_auth = client.get(f'/v1/reports/daily/{session_id}')
    assert no_auth.status_code == 401

    forbidden = client.get(f'/v1/reports/daily/{session_id}', headers=auth(outsider))
    assert forbidden.status_code == 403


def test_ws_returns_error_for_unknown_or_missing_session():
    client = TestClient(app)
    with client.websocket_connect('/v1/realtime/ws') as ws:
        ws.send_json({'session_id': 'unknown', 'speaker_id': 's1', 'anger_score': 0.8, 'transcript': 'x'})
        assert ws.receive_json()['type'] == 'error'

        ws.send_json({'speaker_id': 's1', 'anger_score': 0.2, 'transcript': 'x'})
        assert ws.receive_json()['type'] == 'error'


def test_range_report_validates_datetime():
    client = TestClient(app)
    owner = client.post('/v1/users', json={'nickname': '爸爸'}).json()['user_id']
    family_id = client.post('/v1/families', json={'name': '示例家庭'}, headers=auth(owner)).json()['family_id']
    res = client.get(f'/v1/reports/family/{family_id}/range?start=bad&end=bad2', headers=auth(owner))
    assert res.status_code == 400
