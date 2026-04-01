# 运维 Runbook

## 可观测性检查
- API 存活: `/healthz`
- API 就绪: `/readyz`
- 系统信息: `/v1/system/info`

## 常见故障
1. 401 大量出现：检查 `x-user-id` 是否携带
2. 403 大量出现：检查用户是否加入 family
3. WebSocket error: session not found：检查 session 生命周期

## 告警建议
- 5xx 比例 > 2%
- WebSocket 错误率 > 5%
- 报表接口 p95 > 800ms
