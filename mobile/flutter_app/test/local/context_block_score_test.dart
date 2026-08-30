import 'package:flutter_test/flutter_test.dart';
import 'package:softerplease/local/daily_advice.dart';
import 'package:softerplease/local/llm_review_queue.dart';
import 'package:softerplease/local/conversation_models.dart';
import 'package:softerplease/local/local_session_store.dart';

void main() {
  test('context request parses one response into per-utterance scores', () {
    final response = ContextBlockScoreResponse.parse('''
      {"markdown":"## 建议\\n先倾听", "scores": {
        "s1/u1":{"score":-80,"markdown":"语气较冲"},
        "s1/u2":{"score":40,"markdown":"有回应"}
      }}
    ''');
    expect(response.markdown, contains('先倾听'));
    expect(response.scores['s1/u1']?.score, -80);
    expect(response.scores['s1/u2']?.score, 40);
  });

  test('context queue sends one request for a confirmed context block',
      () async {
    var conversation = _conversation(confirmed: true);
    var calls = 0;
    final queue = LlmContextBlockQueue(
      loadAll: () async => [conversation],
      save: (updated) async => conversation = updated,
      generate: (block, conversations) async {
        calls++;
        expect(block.utteranceRefs, hasLength(3));
        expect(conversations.single.id, 's1');
        return '{"markdown":"## 总结", "scores": {'
            '"s1/u1":{"score":-20,"markdown":"较硬"},'
            '"s1/u2":{"score":10,"markdown":"平和"},'
            '"s1/u3":{"score":60,"markdown":"支持"}}}';
      },
      minimumRequestInterval: Duration.zero,
    );
    await queue.enqueueAvailable(recordingStopped: true);
    expect(calls, 1);
    expect(conversation.utterances.map((item) => item.llmReview?.score),
        [-20, 10, 60]);
    queue.dispose();
  });

  test('context queue waits until every utterance has a speaker', () async {
    var conversation = _conversation(confirmed: false);
    var calls = 0;
    final queue = LlmContextBlockQueue(
      loadAll: () async => [conversation],
      save: (updated) async => conversation = updated,
      generate: (_, __) async {
        calls++;
        return '{"markdown":"ok", "scores": {}}';
      },
      minimumRequestInterval: Duration.zero,
    );
    await queue.enqueueAvailable(recordingStopped: true);
    expect(calls, 0);
    expect(conversation.utterances.every((item) => item.llmReview == null),
        isTrue);
    queue.dispose();
  });
}

LocalSessionSummary _conversation({required bool confirmed}) =>
    LocalSessionSummary(
      id: 's1',
      createdAt: '2026-08-30T09:00:00.000Z',
      audioPath: '/local/s1.wav',
      durationSeconds: 12,
      transcript: '我听见了。',
      emotionValue: 0,
      recordingGroupId: 'group-1',
      utterances: [
        _utterance('u1', '你怎么又这样', 0, confirmed),
        _utterance('u2', '我们先停一下', 1200, confirmed),
        _utterance('u3', '我愿意听你说。', 2500, confirmed),
      ],
    );

LocalUtterance _utterance(String id, String text, int start, bool confirmed) =>
    LocalUtterance(
      id: id,
      startMilliseconds: start,
      endMilliseconds: start + 800,
      transcript: text,
      rawEmotion: 'NEUTRAL',
      emotionLabel: '中性',
      emotionValue: 0,
      speakerId: confirmed ? 'speaker-a' : (id == 'u1' ? null : 'speaker-a'),
      speakerLabel: confirmed ? '家人A' : '未知说话人',
    );
