# SofterPlease (Phase-2 Scaffold)

用于“家庭说话情绪反馈”项目第二阶段的可运行骨架代码（加入租户隔离）。

## 目录

- `backend/` FastAPI API 与 WebSocket 实时反馈服务（SQLite 持久化）
- `backend/tests/` API + WebSocket 自动化测试
- `web/` Demo 页面
- `infra/docker-compose.yml` 本地一键启动
- `docs/phase1-plan.md` 阶段说明

## 第二阶段重点

- 新增 `x-user-id` 鉴权头（基于用户身份）
- 所有家庭/会话/报表接口加入成员权限校验
- 非家庭成员读取会话与报表将返回 `403`

## 快速启动

### 方案 A：Docker Compose

```bash
cd infra
docker compose up
```

- API: http://localhost:8000/docs
- Web: http://localhost:5173

### 方案 B：本地 Python

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements.txt
uvicorn backend.app.main:app --reload --port 8000
```

## API 概览（需 `x-user-id`）

- `POST /v1/users`（创建用户，不需要鉴权头）
- `POST /v1/families`
- `POST /v1/families/{family_id}/members`
- `POST /v1/sessions/start`
- `POST /v1/sessions/end`
- `POST /v1/feedback/actions`
- `GET /v1/reports/daily/{session_id}`
- `GET /v1/reports/timeseries/{session_id}`
- `GET /v1/reports/speaker/{session_id}/{speaker_id}`
- `GET /v1/reports/family/{family_id}/daily`
- `GET /v1/reports/family/{family_id}/range?start=<ISO>&end=<ISO>`
- `GET /v1/reports/effectiveness/{session_id}`
- `GET /v1/sessions/{session_id}/events?limit=<n>&offset=<n>`
- `WS /v1/realtime/ws`

## 运行测试

```bash
PYTHONPATH=backend pytest -q backend/tests
```


## 部署与宣发资料
- 部署手册：`docs/deploy/DEPLOYMENT.md`
- 运维 Runbook：`docs/ops/RUNBOOK.md`
- 宣发海报文案：`docs/marketing/poster_copy.md`
- 宣发计划：`docs/marketing/campaign_plan.md`
- 移动端开发说明：`mobile/README.md`
