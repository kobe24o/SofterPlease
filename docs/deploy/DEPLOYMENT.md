# SofterPlease 部署手册（阶段化）

## 1. 环境
- Docker 24+
- Kubernetes 1.29+
- PostgreSQL 15+
- Redis 7+

## 2. 本地开发部署
```bash
cd infra
docker compose up
```

## 3. 生产建议
1. 使用 PostgreSQL 替代 SQLite
2. 接入对象存储（S3/MinIO）存放音频片段
3. 接入集中日志与监控（Prometheus/Grafana/Loki）
4. 通过 Nginx Ingress 暴露 API 与 Web

## 4. 发布流程
1. 运行自动化测试
2. 构建镜像并推送仓库
3. kubectl apply `infra/k8s/`
4. 冒烟检查 `/healthz` `/readyz`

## 5. 回滚
- 使用镜像 tag 回滚 Deployment
- 保持数据库 schema 向后兼容
