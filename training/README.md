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

Windows 上默认使用系统中文 TTS，并通过语速、音量和移调生成 5 种声音变体，同时生成负向、中性、正向三类语料。可显式选择模式：

```bash
python training/prepare_multimodal_corpus.py --mode tts --per-class 30
python training/prepare_multimodal_corpus.py --mode tones --per-class 30
```

`tones` 仅用于声学链路测试，不是真实说话语音；训练实际情绪模型时应使用 `tts` 或真实录音。

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

## 用手机真实录音做三分类校准

SenseVoice 擅长识别显式情绪标签，但日常说话经常会被识别为 `NEUTRAL`。项目会在这种情况下继续融合识别文本、语速、音调、音调波动、音量和停顿比例，并可加载一个针对当前用户场景的 `-1 / 0 / 1` 校准器。

1. 在 App 中录制并分析真实对话。
2. 打开 Web 模型调试页，在“最近客户端上传”中播放录音，并人工标注 `-1 / 0 / 1`。
3. 每类至少标注 3 条，建议每类先收集 30 条以上、覆盖不同说话人和音色。
4. 训练校准器：

```bash
python training/train_debug_emotion_calibrator.py
```

训练结果会写入：

```text
backend/models/debug_emotion_calibrator_v1.json
```

重启后端后，`EmotionAnalyzer` 会自动加载该模型。可通过 `TRICLASS_EMOTION_MODEL_PATH` 指定其他模型文件，通过 `TRICLASS_CALIBRATION_THRESHOLD` 调整采用模型结论所需的最低置信度。

## Web 训练工作台

Web 模型调试页提供完整训练闭环：

- 汇总手机、Web 上传录音和合成语料
- 播放音频并显示 RMS、峰值、时长及近似静音诊断
- 编辑识别文本，标注 `-1 / 0 / 1`
- 勾选需要参与训练的数据
- 自动按类别分层切分训练集和测试集
- 显示训练阶段、进度、日志、准确率和混淆矩阵
- 保存并切换不同模型版本

微调模型版本保存在：

```text
backend/models/versions/*.json
```
