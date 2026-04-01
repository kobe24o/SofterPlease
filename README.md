# SofterPlease - 家庭情绪语音助手

> 让每一次对话都充满温度

## 项目简介

**SofterPlease** 是一款基于AI语音情绪识别的家庭沟通辅助工具。通过实时分析语音中的情绪特征（语调、语速、音量、用词等），帮助家庭成员在沟通中及时感知情绪变化，获得温和的改善建议，长期建立更和谐的家庭氛围。

### 核心功能

- 🎙️ **实时情绪监测** - 语音流实时分析，秒级情绪识别
- 🧠 **声纹识别** - 自动识别说话人，区分家庭成员
- 💡 **智能反馈** - 根据情绪等级给出个性化建议
- 📊 **数据统计** - 情绪趋势分析，改善进度可视化
- 👨‍👩‍👧‍👦 **家庭共享** - 多人参与，共同见证改变
- 🔒 **隐私保护** - 端到端加密，数据安全保障

## 技术架构

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

## 项目结构

```
SofterPlease/
├── backend/                    # 后端服务
│   ├── app/
│   │   ├── main.py            # FastAPI主入口
│   │   ├── models.py          # SQLAlchemy数据模型
│   │   ├── db.py              # 数据库配置
│   │   └── emotion_engine/    # 情绪识别引擎
│   │       ├── emotion_analyzer.py    # 情绪分析器
│   │       ├── voice_recognition.py   # 声纹识别
│   │       ├── feedback_generator.py  # 反馈生成
│   │       └── audio_processor.py     # 音频处理
│   ├── requirements.txt
│   └── Dockerfile
├── web/                        # Web前端
│   ├── index.html
│   ├── style.css
│   └── main.js
├── mobile/                     # 移动端
│   └── flutter_app/           # Flutter应用
│       ├── lib/
│       │   ├── main.dart
│       │   ├── screens/
│       │   ├── widgets/
│       │   ├── providers/
│       │   ├── services/
│       │   ├── models/
│       │   └── utils/
│       └── pubspec.yaml
├── docs/                       # 文档
│   ├── DEPLOYMENT.md          # 部署手册
│   └── MARKETING.md           # 市场推广方案
└── README.md
```

## 快速开始

### 后端部署

```bash
# 1. 进入后端目录
cd backend

# 2. 创建虚拟环境
python -m venv venv
source venv/bin/activate  # Windows: venv\Scripts\activate

# 3. 安装依赖
pip install -r requirements.txt

# 4. 配置环境变量
cp .env.example .env
# 编辑 .env 文件配置数据库等信息

# 5. 初始化数据库
alembic upgrade head

# 6. 启动服务
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

### Web前端

```bash
cd web
# 直接用浏览器打开 index.html
# 或使用本地服务器
python -m http.server 8080
```

### 移动端

```bash
cd mobile/flutter_app

# 安装依赖
flutter pub get

# 运行
flutter run

# 构建
flutter build apk --release
flutter build ios --release
```

## 情绪识别算法

### 多维度情绪分析

系统从多个维度分析语音情绪：

1. **声学特征**
   - 基频（Pitch）- 音调高低
   - 能量（Energy）- 音量大小
   - 语速（Speaking Rate）- 说话速度
   - 过零率（ZCR）- 声音尖锐度
   - 频谱特征（MFCC）- 音色特征

2. **语义特征**
   - 愤怒关键词识别
   - 不耐烦表达检测
   - 情感词典匹配

3. **情绪维度**
   - 愤怒分数（Anger Score）
   - 情感效价（Valence）
   - 唤醒度（Arousal）
   - 压力指数（Stress）
   - 不耐烦指数（Impatience）

### 情绪等级

| 等级 | 分数范围 | 颜色 | 状态 |
|------|----------|------|------|
| 平静 | 0.0 - 0.3 | 🟢 绿色 | 正常沟通 |
| 轻微 | 0.3 - 0.5 | 🟡 浅绿 | 略有波动 |
| 中等 | 0.5 - 0.7 | 🟠 黄色 | 需要注意 |
| 较高 | 0.7 - 0.85 | 🟠 橙色 | 建议调整 |
| 极高 | 0.85 - 1.0 | 🔴 红色 | 立即干预 |

## API文档

启动后端服务后访问：`http://localhost:8000/docs`

### 主要接口

- `POST /v1/users` - 创建用户
- `POST /v1/auth/login` - 用户登录
- `POST /v1/families` - 创建家庭
- `POST /v1/sessions/start` - 开始会话
- `POST /v1/sessions/{id}/analyze` - 情绪分析
- `GET /v1/reports/daily/{family_id}` - 日报数据
- `WS /v1/realtime/ws` - WebSocket实时通信

## 部署方案

详细部署文档请参考 [DEPLOYMENT.md](docs/DEPLOYMENT.md)

### 服务器配置（100万用户）

| 组件 | 配置 | 数量 |
|------|------|------|
| Web服务器 | 4核8G | 3台 |
| 应用服务器 | 8核16G | 5台 |
| 数据库服务器 | 16核64G | 2台 |
| Redis服务器 | 4核16G | 2台 |

## 市场推广

详细推广方案请参考 [MARKETING.md](docs/MARKETING.md)

### 核心价值

- 🎯 目标用户：25-40岁年轻父母
- 💰 商业模式：免费基础版 + 高级会员
- 📈 增长策略：口碑传播 + KOL合作

### Slogan

> 让家庭沟通更温柔

## 贡献指南

欢迎提交Issue和Pull Request！

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 创建 Pull Request

## 许可证

[MIT License](LICENSE)

## 联系我们

- 官方网站：https://softerplease.com
- 技术支持：support@softerplease.com
- 商务合作：business@softerplease.com

## 致谢

感谢所有为这个项目做出贡献的开发者、设计师和测试人员！

---

**让每一次对话都充满温度** ❤️
