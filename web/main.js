const API = 'http://localhost:8000';

const startBtn = document.getElementById('startBtn');
const endBtn = document.getElementById('endBtn');
const sendBtn = document.getElementById('sendBtn');
const acceptBtn = document.getElementById('acceptBtn');
const reportBtn = document.getElementById('reportBtn');
const eventsBtn = document.getElementById('eventsBtn');
const timeseriesBtn = document.getElementById('timeseriesBtn');
const effectBtn = document.getElementById('effectBtn');

const sessionText = document.getElementById('sessionText');
const speakerInput = document.getElementById('speakerInput');
const textInput = document.getElementById('textInput');
const scoreInput = document.getElementById('scoreInput');
const feedback = document.getElementById('feedback');
const report = document.getElementById('report');

let sessionId = null;
let familyId = null;
let userId = null;
let ws = null;
let latestFeedbackToken = null;

function authHeaders() {
  return { 'Content-Type': 'application/json', 'x-user-id': userId };
}

async function ensureFamily() {
  const userResp = await fetch(`${API}/v1/users`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ nickname: 'Web演示用户' })
  });
  const user = await userResp.json();
  userId = user.user_id;

  const familyResp = await fetch(`${API}/v1/families`, {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify({ name: '演示家庭' })
  });
  const family = await familyResp.json();
  familyId = family.family_id;
}

startBtn.addEventListener('click', async () => {
  await ensureFamily();

  const res = await fetch(`${API}/v1/sessions/start`, {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify({ family_id: familyId, device_id: 'web-client' })
  });
  const data = await res.json();
  sessionId = data.session_id;
  sessionText.textContent = `当前会话：${sessionId}`;

  ws = new WebSocket('ws://localhost:8000/v1/realtime/ws');
  ws.onmessage = (evt) => {
    const payload = JSON.parse(evt.data);
    latestFeedbackToken = payload.feedback_token;
    feedback.textContent = JSON.stringify(payload, null, 2);
    acceptBtn.disabled = !latestFeedbackToken;
  };

  startBtn.disabled = true;
  endBtn.disabled = false;
  sendBtn.disabled = false;
  reportBtn.disabled = false;
  eventsBtn.disabled = false;
  timeseriesBtn.disabled = false;
  effectBtn.disabled = false;
});

endBtn.addEventListener('click', async () => {
  await fetch(`${API}/v1/sessions/end`, {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify({ session_id: sessionId })
  });

  if (ws) ws.close();
  startBtn.disabled = false;
  endBtn.disabled = true;
  sendBtn.disabled = true;
  acceptBtn.disabled = true;
});

sendBtn.addEventListener('click', () => {
  const payload = {
    session_id: sessionId,
    speaker_id: speakerInput.value,
    transcript: textInput.value,
    anger_score: Number(scoreInput.value)
  };
  ws.send(JSON.stringify(payload));
});

acceptBtn.addEventListener('click', async () => {
  if (!latestFeedbackToken) return;
  const res = await fetch(`${API}/v1/feedback/actions`, {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify({ feedback_token: latestFeedbackToken, action: 'accepted' })
  });
  const data = await res.json();
  report.textContent = JSON.stringify({ feedback_action: data }, null, 2);
});

reportBtn.addEventListener('click', async () => {
  const res = await fetch(`${API}/v1/reports/daily/${sessionId}`, { headers: { 'x-user-id': userId } });
  const data = await res.json();
  report.textContent = JSON.stringify({ report: data }, null, 2);
});

eventsBtn.addEventListener('click', async () => {
  const res = await fetch(`${API}/v1/sessions/${sessionId}/events`, { headers: { 'x-user-id': userId } });
  const data = await res.json();
  report.textContent = JSON.stringify({ events: data.items }, null, 2);
});

timeseriesBtn.addEventListener('click', async () => {
  const res = await fetch(`${API}/v1/reports/timeseries/${sessionId}`, { headers: { 'x-user-id': userId } });
  const data = await res.json();
  report.textContent = JSON.stringify({ timeseries: data.points }, null, 2);
});

effectBtn.addEventListener('click', async () => {
  const res = await fetch(`${API}/v1/reports/effectiveness/${sessionId}`, { headers: { 'x-user-id': userId } });
  const data = await res.json();
  report.textContent = JSON.stringify({ effectiveness: data }, null, 2);
});
