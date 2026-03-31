# SofterPlease Phase-2 开发说明

## 已完成（第二阶段）
- FastAPI 后端：用户、家庭、成员、会话管理。
- WebSocket 实时反馈：按 anger_score 分级返回建议。
- SQLite 持久化：会话、情绪事件、反馈事件可回溯。
- 报表：日报、说话人维度、家庭日报、家庭时间范围报告、分钟级曲线、反馈接受率。
- 租户隔离：基于 `x-user-id` 的成员权限控制（401/403）。
- 自动化测试：覆盖主流程、权限隔离、参数校验和 WebSocket 错误路径。

## 下一阶段建议
1. 引入 JWT/OAuth2（替代当前简化版 `x-user-id`）。
2. 数据库迁移到 PostgreSQL + Alembic。
3. 增加审计日志与埋点事件出口（Kafka/ClickHouse）。
4. 模型服务接入：ASR/声纹/情绪融合推理链路。
