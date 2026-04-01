# SofterPlease 部署手册

## 系统架构

```
┌─────────────────────────────────────────────────────────────┐
│                        客户端层                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │   Web App   │  │  iOS App    │  │    Android App      │ │
│  │   (Vue3)    │  │  (Flutter)  │  │     (Flutter)       │ │
│  └─────────────┘  └─────────────┘  └─────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                        接入层                                │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Nginx / AWS ALB / 阿里云 SLB            │   │
│  │              SSL终止 / 负载均衡 / 静态资源            │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                        应用层                                │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              FastAPI (Python)                        │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐            │   │
│  │  │  API服务  │ │  WebSocket │ │  定时任务  │            │   │
│  │  └──────────┘ └──────────┘ └──────────┘            │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                        数据层                                │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │  PostgreSQL │  │    Redis    │  │   对象存储 (S3/OSS)  │ │
│  │  (主数据库)  │  │  (缓存/队列) │  │   (音频文件)        │ │
│  └─────────────┘  └─────────────┘  └─────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## 环境要求

### 服务器配置（支持100万用户）

| 组件 | 配置 | 数量 | 说明 |
|------|------|------|------|
| Web服务器 | 4核8G | 3台 | Nginx负载均衡 |
| 应用服务器 | 8核16G | 5台 | FastAPI应用 |
| 数据库服务器 | 16核64G | 2台 | PostgreSQL主从 |
| Redis服务器 | 4核16G | 2台 | 主从模式 |
| 对象存储 | - | - | AWS S3/阿里云OSS |

### 软件版本

- Python 3.11+
- PostgreSQL 15+
- Redis 7+
- Nginx 1.24+
- Docker 24+
- Kubernetes 1.28+ (可选)

## 部署步骤

### 1. 数据库部署

```bash
# 安装PostgreSQL
sudo apt update
sudo apt install postgresql-15 postgresql-contrib

# 创建数据库
sudo -u postgres psql -c "CREATE DATABASE softerplease;"
sudo -u postgres psql -c "CREATE USER spuser WITH PASSWORD 'your_secure_password';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE softerplease TO spuser;"

# 配置主从复制（生产环境）
# 编辑 postgresql.conf
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10

# 编辑 pg_hba.conf
host replication replicator 0.0.0.0/0 md5
```

### 2. Redis部署

```bash
# 安装Redis
sudo apt install redis-server

# 配置Redis
sudo nano /etc/redis/redis.conf

# 启用持久化
save 900 1
save 300 10
save 60 10000

# 配置主从
replicaof master_ip 6379

# 重启
sudo systemctl restart redis
```

### 3. 后端部署

```bash
# 克隆代码
git clone https://github.com/yourorg/softerplease.git
cd softerplease/backend

# 创建虚拟环境
python -m venv venv
source venv/bin/activate

# 安装依赖
pip install -r requirements.txt

# 配置环境变量
cp .env.example .env

# 编辑 .env
DATABASE_URL=postgresql://spuser:password@localhost/softerplease
REDIS_URL=redis://localhost:6379/0
JWT_SECRET=your_super_secret_key
API_BASE_URL=https://api.softerplease.com

# 初始化数据库
alembic upgrade head

# 启动应用
# 开发模式
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

# 生产模式 (使用Gunicorn)
gunicorn app.main:app -w 4 -k uvicorn.workers.UvicornWorker --bind 0.0.0.0:8000
```

### 4. Docker部署

```bash
# 构建镜像
docker build -t softerplease-backend:latest .

# 运行容器
docker run -d \
  --name softerplease-api \
  -p 8000:8000 \
  -e DATABASE_URL=postgresql://... \
  -e REDIS_URL=redis://... \
  softerplease-backend:latest

# Docker Compose
docker-compose up -d
```

### 5. Nginx配置

```nginx
# /etc/nginx/sites-available/softerplease
upstream backend {
    least_conn;
    server 10.0.1.10:8000 weight=5;
    server 10.0.1.11:8000 weight=5;
    server 10.0.1.12:8000 weight=5;
    keepalive 32;
}

server {
    listen 80;
    server_name api.softerplease.com;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name api.softerplease.com;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    # WebSocket支持
    location /v1/realtime/ws {
        proxy_pass http://backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400;
    }

    # API请求
    location / {
        proxy_pass http://backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # 超时设置
        proxy_connect_timeout 30s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
    }

    # 静态文件
    location /static {
        alias /var/www/softerplease/static;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
```

### 6. Kubernetes部署

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: softerplease-api
spec:
  replicas: 5
  selector:
    matchLabels:
      app: softerplease-api
  template:
    metadata:
      labels:
        app: softerplease-api
    spec:
      containers:
      - name: api
        image: softerplease-backend:latest
        ports:
        - containerPort: 8000
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: db-secret
              key: url
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "2Gi"
            cpu: "2000m"
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: softerplease-api
spec:
  selector:
    app: softerplease-api
  ports:
  - port: 80
    targetPort: 8000
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: softerplease-ingress
  annotations:
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: letsencrypt
    nginx.ingress.kubernetes.io/websocket-services: "softerplease-api"
spec:
  tls:
  - hosts:
    - api.softerplease.com
    secretName: softerplease-tls
  rules:
  - host: api.softerplease.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: softerplease-api
            port:
              number: 80
```

### 7. 前端部署

```bash
# Web端
cd web
npm install
npm run build

# 部署到CDN/对象存储
aws s3 sync dist/ s3://softerplease-web/ --delete

# 配置CloudFront/阿里云CDN
# ...

# 移动端
cd mobile/flutter_app
flutter build apk --release
flutter build ios --release

# 上传应用到应用商店
# ...
```

## 监控与日志

### 1. Prometheus + Grafana

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'softerplease-api'
    static_configs:
      - targets: ['api.softerplease.com:8000']
    metrics_path: /metrics
```

### 2. ELK Stack

```bash
# Filebeat配置
filebeat.inputs:
- type: log
  enabled: true
  paths:
    - /var/log/softerplease/*.log

output.elasticsearch:
  hosts: ["elasticsearch:9200"]
```

### 3. 关键监控指标

| 指标 | 告警阈值 | 说明 |
|------|----------|------|
| API响应时间 | > 500ms | P95响应时间 |
| 错误率 | > 1% | 5xx错误比例 |
| CPU使用率 | > 80% | 应用服务器 |
| 内存使用率 | > 85% | 应用服务器 |
| 数据库连接数 | > 80% | 连接池使用率 |
| WebSocket连接数 | > 10000 | 并发连接 |

## 备份策略

### 数据库备份

```bash
# 每日全量备份
0 2 * * * pg_dump softerplease | gzip > /backup/db/softerplease_$(date +\%Y\%m\%d).sql.gz

# 每小时增量备份 (WAL归档)
# 配置postgresql.conf
archive_mode = on
archive_command = 'cp %p /backup/wal/%f'

# 保留30天
find /backup/db -name "*.sql.gz" -mtime +30 -delete
```

### 对象存储备份

```bash
# 跨地域复制
aws s3 sync s3://softerplease-audio s3://softerplease-audio-backup --region ap-southeast-1
```

## 扩容方案

### 水平扩容

```bash
# 增加应用服务器
kubectl scale deployment softerplease-api --replicas=10

# 增加数据库只读副本
# AWS RDS / 阿里云RDS 控制台操作
```

### 数据库分片

```sql
-- 按家庭ID分片
CREATE TABLE emotion_events_2024_q1 PARTITION OF emotion_events
    FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');
```

## 安全加固

### 1. 网络安全

```bash
# 配置防火墙
ufw default deny incoming
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw enable

# 配置Fail2ban
apt install fail2ban
```

### 2. 应用安全

```python
# 启用安全头
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.middleware.httpsredirect import HTTPSRedirectMiddleware

app.add_middleware(HTTPSRedirectMiddleware)
app.add_middleware(
    TrustedHostMiddleware, 
    allowed_hosts=["api.softerplease.com"]
)
```

### 3. 数据加密

```bash
# 数据库TDE
# 启用SSL连接
# 敏感字段加密
```

## 故障处理

### 常见问题

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| WebSocket断开 | 网络超时 | 增加心跳间隔，自动重连 |
| 数据库连接池耗尽 | 连接泄漏 | 检查连接释放，增加连接池大小 |
| 内存泄漏 | 未释放资源 | 检查大对象，启用GC日志 |
| 响应慢 | 慢查询 | 优化SQL，添加索引 |

### 紧急回滚

```bash
# 回滚到上一个版本
kubectl rollout undo deployment/softerplease-api

# 数据库回滚
pg_restore -d softerplease backup.sql
```

## 性能优化

### 1. 数据库优化

```sql
-- 添加索引
CREATE INDEX CONCURRENTLY idx_emotion_events_family_ts 
    ON emotion_events(family_id, ts DESC);

CREATE INDEX CONCURRENTLY idx_emotion_events_session_ts 
    ON emotion_events(session_id, ts DESC);

-- 分区表
CREATE TABLE emotion_events (
    id BIGSERIAL,
    session_id VARCHAR(64),
    family_id VARCHAR(64),
    ts TIMESTAMP WITH TIME ZONE,
    anger_score FLOAT,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
```

### 2. 缓存策略

```python
# Redis缓存
from functools import wraps
import redis

cache = redis.Redis()

def cache_result(expire=300):
    def decorator(func):
        @wraps(func)
        async def wrapper(*args, **kwargs):
            key = f"cache:{func.__name__}:{hash(str(args))}"
            result = cache.get(key)
            if result:
                return json.loads(result)
            result = await func(*args, **kwargs)
            cache.setex(key, expire, json.dumps(result))
            return result
        return wrapper
    return decorator
```

### 3. CDN配置

```nginx
# 静态资源缓存
location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
    expires 1y;
    add_header Cache-Control "public, immutable";
    add_header Vary "Accept-Encoding";
}
```

## 联系方式

- 技术支持: support@softerplease.com
- 紧急联系: +86-xxx-xxxx-xxxx
- 文档地址: https://docs.softerplease.com
