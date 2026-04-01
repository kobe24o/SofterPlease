# SofterPlease 全阶段交付进度（截至 2026-04-01）

## Phase-1
- 基础后端、WebSocket、Web Demo、报表、测试。

## Phase-2
- 家庭租户隔离与权限控制。

## Phase-3
- 运维健康接口、部署手册、K8s 清单、宣发素材。

## Phase-4（本次新增）
- JWT 登录接口：`POST /v1/auth/login`
- Bearer Token 鉴权路径（兼容旧 `x-user-id`）
- Alembic 基础目录与初始迁移模板
- GitHub Actions CI（安装依赖 + 自动测试）
- Flutter 移动端壳工程

## 下一步
1. 完整迁移到 PostgreSQL 并补齐所有表迁移脚本。
2. 移动端接入真实 API 与实时反馈链路。
3. 加入模型服务（ASR/声纹/情绪）并做压测。
