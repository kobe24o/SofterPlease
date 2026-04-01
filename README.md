# SofterPlease (Phase-4 Scaffold)

家庭沟通改善产品的全栈骨架：后端 API + Web Demo + 移动端壳 + 部署与宣发资料。

## 当前能力
- FastAPI 后端（会话、反馈、报表、租户隔离）
- JWT 登录 + Bearer 鉴权（兼容 `x-user-id`）
- WebSocket 实时反馈
- Web 演示页
- 自动化测试与 CI
- 部署与运维文档
- 宣发海报文案与冷启动计划
- Flutter 移动端壳工程

## 快速启动
```bash
python -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements.txt
uvicorn backend.app.main:app --reload --port 8000
```

## 测试
```bash
PYTHONPATH=backend pytest -q backend/tests
```

## 关键接口
- `POST /v1/users`
- `POST /v1/auth/login`
- `POST /v1/families`
- `POST /v1/families/{family_id}/members`
- `POST /v1/sessions/start`
- `POST /v1/sessions/end`
- `POST /v1/feedback/actions`
- `GET /v1/reports/*`
- `WS /v1/realtime/ws`

## 文档
- 部署：`docs/deploy/DEPLOYMENT.md`
- 运维：`docs/ops/RUNBOOK.md`
- 宣发：`docs/marketing/poster_copy.md` / `docs/marketing/campaign_plan.md`
- 阶段进度：`docs/phase1-plan.md`
- 移动端：`mobile/README.md` / `mobile/flutter_app/`


## GitHub Pages 发布
仓库已包含 `.github/workflows/pages.yml`：
- push 到 `main/work` 或手动触发后自动部署 `web/` 到 GitHub Pages

## 移动端构建产物
仓库已包含 `.github/workflows/mobile-build.yml`：
- 自动构建 Flutter Android APK
- 构建产物在 Actions Artifacts 下载
