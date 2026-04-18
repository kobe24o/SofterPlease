# Emotion model training

## 目标
训练一个**综合文本特征 + 声学特征**的情绪模型：
- 输入：音频 + transcript
- 输出：`bad_probability`（0-1，越高表示越负面/激动）

## 一键流程
1) 准备多模态语料（生成 wav + manifest）

```bash
python training/prepare_multimodal_corpus.py
```

2) 训练多模态模型并导出

```bash
python training/train_multimodal_emotion_model.py
```

## 输出产物
- 语料清单：`training/data/multimodal_corpus/manifest.csv`
- 合成音频：`training/data/multimodal_corpus/wav/*.wav`
- 模型文件：`backend/models/multimodal_emotion_v1.json`

## 接入
`EmotionAnalyzer` 会自动尝试加载：
- `MULTIMODAL_EMOTION_MODEL_PATH`（默认 `models/multimodal_emotion_v1.json`）

在线推理时采用：
- `final_score = 0.8 * multimodal_model + 0.2 * rule_engine`

加载失败自动回退到原规则链路。
