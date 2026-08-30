# 流式片段评分与家庭趋势 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将连续 Android 录音按 VAD 边界切成约 60 秒 WAV 片段，对每条说话片段打 -100 至 100 的沟通分，并展示每个角色的日、周、月、年趋势。

**Architecture:** 纯 Dart PCM 分段器选择 VAD 静音边界并保证字节连续；流式录音和本地分析作为外层适配。逐句评分持久化进 `LocalUtterance`，全局队列按 `(conversationId, utteranceId)` 串行处理。趋势聚合和图表分离，前者纯 Dart 可测，后者仅渲染。

**Tech Stack:** Flutter/Dart、record `startStream`、sherpa_onnx、SharedPreferences、Dio、flutter_markdown_plus、CustomPainter、flutter_test。

**Spec:** `docs/superpowers/specs/2026-08-30-segment-score-trends-design.md`

## Global Constraints

- Android 音频为 16 kHz、单声道、16-bit PCM；仅转写文本发送给用户配置的大模型。
- 目标切段 60 秒，最后 12 秒优先 VAD 静音边界，最多延后至 66 秒；PCM 不得丢失或重复。
- 请求全局串行、最短间隔 3 秒，失败退避为 15 秒、1 分钟、5 分钟、20 分钟、1 小时、3 小时。
- 分数必须为 -100 至 100 整数；负数红色，正数绿色，0 灰色，主列表移除声学情绪标签。
- 趋势按角色、已完成评分等权平均：日按小时，周/月按天，年按月；空桶不补 0。
- 旧会话 JSON 必须可读；未配置 Key 时本地录音、切段、转写和声纹仍继续。

---

### Task 1: 持久化逐句评分模型

**Files:**
- Modify: `mobile/flutter_app/lib/local/conversation_models.dart`
- Modify: `mobile/flutter_app/lib/local/local_session_store.dart`
- Test: `mobile/flutter_app/test/local/conversation_models_test.dart`

**Interfaces:** Produces `LlmSegmentReview`、`LocalUtterance.llmReview`、`LocalSessionSummary.recordingGroupId`；保留旧 `LlmReview` 可读。

- [ ] **Step 1: 写入失败 JSON 往返测试**

```dart
const review = LlmSegmentReview(status: LlmSegmentReview.completed,
  attempts: 1, updatedAt: '2026-08-30T10:00:00.000Z',
  score: -72, markdown: '## 表达风险\n高');
expect(loaded.recordingGroupId, 'group-1');
expect(loaded.utterances.single.llmReview?.score, -72);
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test --no-pub test/local/conversation_models_test.dart`

Expected: FAIL，缺少片段评分字段。

- [ ] **Step 3: 实现最小模型和 JSON 字段**

```dart
final class LlmSegmentReview {
  const LlmSegmentReview({required this.status, required this.attempts,
    required this.updatedAt, this.score, this.markdown, this.nextRetryAt,
    this.lastError});
  final String status; final int attempts; final String updatedAt;
  final int? score; final String? markdown;
  final String? nextRetryAt; final String? lastError;
}
```

给 `LocalUtterance.copyWith` 增加评分字段，旧 JSON 缺字段时返回 null。

- [ ] **Step 4: 验证并提交**

Run: `flutter test --no-pub test/local/conversation_models_test.dart`

Expected: PASS，旧记录和评分记录都可读取。

Commit: `git add mobile/flutter_app/lib/local/conversation_models.dart mobile/flutter_app/lib/local/local_session_store.dart mobile/flutter_app/test/local/conversation_models_test.dart; git commit -m "feat: persist per-utterance communication scores"`

### Task 2: PCM VAD 切段器与 WAV 写入

**Files:**
- Create: `mobile/flutter_app/lib/local/recording_segmenter.dart`
- Test: `mobile/flutter_app/test/local/recording_segmenter_test.dart`

**Interfaces:** Produces `PcmFrame(bytes, endsInSilence)`、`PcmSegmenter.push(frame)`、`PcmSegmenter.finish()`、`PcmWavWriter.write(...)`；消费 32 ms PCM/VAD 帧。

- [ ] **Step 1: 写入失败的边界和连续性测试**

```dart
final segmenter = PcmSegmenter(sampleRate: 10, targetSeconds: 6,
  maxSeconds: 7, boundaryLookbackSeconds: 2);
for (final frame in frames) output.addAll(segmenter.push(frame));
output.addAll(segmenter.finish());
expect(output.first.durationSamples, 58);
expect(output.expand((item) => item.bytes), originalBytes);
```

覆盖目标前静音、无静音到最大长度、停止尾段和无字节丢失/重复。

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test --no-pub test/local/recording_segmenter_test.dart`

Expected: FAIL，分段器尚不存在。

- [ ] **Step 3: 实现保留尾部的分段器**

最后 12 秒窗口选取最近静音帧；输出边界前字节后保留其余字节为下一段开头。66 秒无边界时输出 `maxSamples` 字节。`PcmWavWriter` 写标准 44 字节 PCM WAV 头。

- [ ] **Step 4: 验证并提交**

Run: `flutter test --no-pub test/local/recording_segmenter_test.dart`

Expected: PASS，全部边界与连续性断言通过。

Commit: `git add mobile/flutter_app/lib/local/recording_segmenter.dart mobile/flutter_app/test/local/recording_segmenter_test.dart; git commit -m "feat: segment streaming pcm recordings"`

### Task 3: 逐句评分 JSON 协议与串行队列

**Files:**
- Modify: `mobile/flutter_app/lib/local/daily_advice.dart`
- Modify: `mobile/flutter_app/lib/local/llm_review_queue.dart`
- Test: `mobile/flutter_app/test/local/daily_advice_test.dart`
- Test: `mobile/flutter_app/test/local/llm_review_queue_test.dart`

**Interfaces:** Produces `UtteranceScoreRequest.forUtterance(...)`、`UtteranceScoreResponse.parse(...)`、`LlmReviewQueue.enqueueUtterances(...)`；消费 `LocalUtterance.llmReview`。

- [ ] **Step 1: 写入失败的协议和顺序测试**

```dart
expect(UtteranceScoreResponse.parse('{"score":-72,"markdown":"## 依据"}').score, -72);
expect(() => UtteranceScoreResponse.parse('{"score":101,"markdown":"x"}'), throwsFormatException);
expect(started, ['a-1', 'a-2', 'b-1']);
expect(peakActiveRequests, 1);
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test --no-pub test/local/daily_advice_test.dart test/local/llm_review_queue_test.dart`

Expected: FAIL，逐句请求和 JSON 解析尚不存在。

- [ ] **Step 3: 实现协议与任务选择**

提示词只接受 `{"score":整数,"markdown":"Markdown"}`。解析拒绝非 JSON、非整数和超出 -100/100。队列按会话创建时间和句子起始毫秒选取最早任务，保存时仅替换目标 utterance，保留 3 秒间隔和持久化退避。

- [ ] **Step 4: 验证并提交**

Run: `flutter test --no-pub test/local/daily_advice_test.dart test/local/llm_review_queue_test.dart`

Expected: PASS，非法响应转为 `retry_waiting`，合法响应保存 score/Markdown。

Commit: `git add mobile/flutter_app/lib/local/daily_advice.dart mobile/flutter_app/lib/local/llm_review_queue.dart mobile/flutter_app/test/local/daily_advice_test.dart mobile/flutter_app/test/local/llm_review_queue_test.dart; git commit -m "feat: score utterances through serialized llm queue"`

### Task 4: 角色趋势时间桶

**Files:**
- Create: `mobile/flutter_app/lib/local/score_trends.dart`
- Test: `mobile/flutter_app/test/local/score_trends_test.dart`

**Interfaces:** Produces `ScorePeriod`、`ScoreTrendPoint`、`RoleScoreSeries`、`ScoreTrendBuilder.build(...)`；消费已完成的 `LlmSegmentReview` 与 `speakerLabel`。

- [ ] **Step 1: 写入失败的四周期聚合测试**

```dart
final series = ScoreTrendBuilder.build(period: ScorePeriod.week,
  role: '妈妈', now: DateTime(2026, 8, 30, 12), conversations: conversations);
expect(series.points.length, 7);
expect(series.points.last.average, -35);
expect(series.points.first.average, isNull);
```

断言同桶 `-70`、`30` 的均值为 `-20`，另一角色不混入，日/周/月/年为小时/日/日/月。

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test --no-pub test/local/score_trends_test.dart`

Expected: FAIL，趋势构建器尚不存在。

- [ ] **Step 3: 实现固定轴的纯 Dart 聚合**

生成完整时间桶，缺数据使用 `average: null`；仅纳入 `completed` 且有 score 的片段，周期样本数为角色已评分片段总数。

- [ ] **Step 4: 验证并提交**

Run: `flutter test --no-pub test/local/score_trends_test.dart`

Expected: PASS，四周期、空桶、均值和角色隔离均正确。

Commit: `git add mobile/flutter_app/lib/local/score_trends.dart mobile/flutter_app/test/local/score_trends_test.dart; git commit -m "feat: aggregate role communication score trends"`

### Task 5: PCM 流录音与后台本地分析

**Files:**
- Modify: `mobile/flutter_app/lib/main.dart`
- Modify: `mobile/flutter_app/lib/local/local_speech_analysis.dart`
- Test: `mobile/flutter_app/test/local/recording_segmenter_test.dart`

**Interfaces:** 消费 `AudioRecorder.startStream(const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1))` 与 `PcmSegmenter`；每个完成片段产生同组 `LocalSessionSummary` 并调用 `enqueueUtterances`。

- [ ] **Step 1: 写入失败的协调器测试**

```dart
final coordinator = RecordingSegmentCoordinator(
  segmenter: segmenter, detectSilence: (bytes) async => bytes == silenceFrame,
  onSegment: completed.add);
await coordinator.accept(speechFrame);
await coordinator.accept(silenceFrame);
expect(completed, hasLength(1));
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test --no-pub test/local/recording_segmenter_test.dart`

Expected: FAIL，协调器不存在。

- [ ] **Step 3: 接入 Android 音频流**

保存 `StreamSubscription<Uint8List>`。每 32 ms PCM 帧本机 VAD 后传入协调器；每段立即写 WAV、保存会话、进入串行 ASR/声纹队列。停止时先 `await _recorder.stop()`，等待流 `onDone`，再 `await coordinator.finish()`。

- [ ] **Step 4: 验证并提交**

Run: `flutter test --no-pub test/local/recording_segmenter_test.dart test/local/conversation_models_test.dart`

Expected: PASS，VAD 边界、流尾段和旧数据行为无回归。

Commit: `git add mobile/flutter_app/lib/main.dart mobile/flutter_app/lib/local/local_speech_analysis.dart mobile/flutter_app/lib/local/recording_segmenter.dart mobile/flutter_app/test/local/recording_segmenter_test.dart; git commit -m "feat: process long recordings as streaming segments"`

### Task 6: 对话分数 UI 与家庭角色曲线

**Files:**
- Create: `mobile/flutter_app/lib/widgets/role_score_trend_chart.dart`
- Modify: `mobile/flutter_app/lib/main.dart`
- Test: `mobile/flutter_app/test/widget_test.dart`

**Interfaces:** Consumes `LlmSegmentReview`、`RoleScoreSeries`、`ScorePeriod`; produces `_ScoreChip`、`_ConversationScoreSummary`、`RoleScoreTrendChart`。

- [ ] **Step 1: 写入失败 widget 测试**

```dart
expect(find.text('妈妈 -72'), findsOneWidget);
expect(find.text('爸爸 +48'), findsOneWidget);
expect(find.text('中性'), findsNothing);
expect(find.text('妈妈的沟通评分趋势'), findsOneWidget);
expect(find.text('日'), findsOneWidget);
expect(find.text('周'), findsOneWidget);
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test --no-pub test/widget_test.dart`

Expected: FAIL，评分徽章和趋势卡片尚不存在。

- [ ] **Step 3: 实现评分优先 UI**

对话卡片按角色归集完成分数并显示平均值；负分 error 红、正分绿色、0 灰色、未完成显示“评分中”。详情逐句显示 score 和 `MarkdownBody`。家庭页每个已命名角色一张卡，日/周/月/年按钮切换 `ScorePeriod`；`CustomPainter` 固定 -100/0/100 网格且在空桶断线。

- [ ] **Step 4: 验证并提交**

Run: `flutter test --no-pub test/widget_test.dart`

Expected: PASS，正负分、多角色、评分中和四周期卡片均可见。

Commit: `git add mobile/flutter_app/lib/widgets/role_score_trend_chart.dart mobile/flutter_app/lib/main.dart mobile/flutter_app/test/widget_test.dart; git commit -m "feat: display role communication score trends"`

### Task 7: 全量验证与安全审计

**Files:**
- Test: `mobile/flutter_app/test/`

**Interfaces:** Consumes Tasks 1–6 and produces a verified implementation.

- [ ] **Step 1: 运行全量测试**

Run: `flutter test --no-pub -r expanded`

Expected: PASS，包含更新、录音、角色纠正、片段评分、趋势和 UI。

- [ ] **Step 2: 格式与静态检查**

Run: `dart format --output=none --set-exit-if-changed lib test` and `dart analyze lib test`

Expected: 成功且分析器无 issue。

- [ ] **Step 3: 检查敏感信息与工作区**

Run: `rg -n "sk-[A-Za-z0-9]|UPDATE_MANIFEST_PRIVATE|ANDROID_KEYSTORE" mobile/flutter_app .github` and `git diff --check`

Expected: 没有 API Key、私钥或 keystore 内容，且无空白错误。

- [ ] **Step 4: 提交验证收尾**

Run: `git status --short`

Expected: 所有实现已在前述任务提交；仅在用户明确要求“发版”后发布 Android APK。
