from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient

from app.main import app


def auth_header(client: TestClient, user_id: str) -> dict[str, str]:
    login = client.post('/v1/auth/login', json={'user_id': user_id})
    token = login.json()['access_token']
    return {'Authorization': f'Bearer {token}'}


def test_phase2_end_to_end_with_tenant_scope():
    client = TestClient(app)

    owner = client.post('/v1/users', json={'nickname': '爸爸'}).json()['user_id']
    member = client.post('/v1/users', json={'nickname': '妈妈'}).json()['user_id']

    family_resp = client.post('/v1/families', json={'name': '示例家庭'}, headers=auth_header(client, owner))
    assert family_resp.status_code == 200
    family_id = family_resp.json()['family_id']

    add_member = client.post(f'/v1/families/{family_id}/members', json={'user_id': member, 'role': 'member'}, headers=auth_header(client, owner))
    assert add_member.status_code == 200

    start_resp = client.post('/v1/sessions/start', json={'family_id': family_id, 'device_id': 'web1'}, headers=auth_header(client, member))
    assert start_resp.status_code == 200
    session_id = start_resp.json()['session_id']

    with client.websocket_connect('/v1/realtime/ws') as ws:
        ws.send_json({'session_id': session_id, 'speaker_id': 'member_a', 'anger_score': 0.83, 'transcript': '你怎么还没做完'})
        feedback = ws.receive_json()
        action = client.post('/v1/feedback/actions', json={'feedback_token': feedback['feedback_token'], 'action': 'accepted'}, headers=auth_header(client, owner))
        assert action.status_code == 200

        ws.send_json({'session_id': session_id, 'speaker_id': 'member_a', 'anger_score': 0.45, 'transcript': '我们慢慢说'})
        _ = ws.receive_json()

    paged = client.get(f'/v1/sessions/{session_id}/events?limit=1&offset=0', headers=auth_header(client, owner))
    assert paged.status_code == 200

    start = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    end = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
    range_resp = client.get(f'/v1/reports/family/{family_id}/range', params={'start': start, 'end': end}, headers=auth_header(client, owner))
    assert range_resp.status_code == 200


def test_tenant_forbidden_for_non_member_and_missing_auth():
    client = TestClient(app)

    owner = client.post('/v1/users', json={'nickname': '爸爸'}).json()['user_id']
    outsider = client.post('/v1/users', json={'nickname': '路人'}).json()['user_id']

    family_id = client.post('/v1/families', json={'name': '示例家庭'}, headers=auth_header(client, owner)).json()['family_id']
    session_id = client.post('/v1/sessions/start', json={'family_id': family_id, 'device_id': 'web1'}, headers=auth_header(client, owner)).json()['session_id']

    no_auth = client.get(f'/v1/reports/daily/{session_id}')
    assert no_auth.status_code == 401

    forbidden = client.get(f'/v1/reports/daily/{session_id}', headers=auth_header(client, outsider))
    assert forbidden.status_code == 403


def test_legacy_x_user_id_still_supported():
    client = TestClient(app)
    owner = client.post('/v1/users', json={'nickname': '爸爸'}).json()['user_id']
    family = client.post('/v1/families', json={'name': '示例家庭'}, headers={'x-user-id': owner})
    assert family.status_code == 200


def test_system_endpoints():
    client = TestClient(app)
    assert client.get('/health').status_code == 200
    assert client.get('/healthz').status_code == 200
    assert client.get('/readyz').status_code == 200
    info = client.get('/v1/system/info')
    assert info.status_code == 200
    assert 'version' in info.json()
