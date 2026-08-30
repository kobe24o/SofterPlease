import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:softerplease/local/local_session_store.dart';
import 'package:softerplease/local/conversation_models.dart';
import 'package:softerplease/local/local_speech_analysis.dart';

void main() {
  test('saving a local conversation keeps its utterances for correction',
      () async {
    final storage = _MemoryStorage();
    final store = LocalSessionStore(storage);

    await store.save(const LocalSessionSummary(
      id: 'conversation-1',
      createdAt: '2026-08-29T09:00:00.000Z',
      audioPath: '/local/conversation-1.wav',
      durationSeconds: 12,
      transcript: '我们慢慢说。',
      emotionValue: 0,
      speakerLabel: '未知说话人',
    ));

    final saved = jsonDecode(storage.values['local_session_summaries_v1']!)
        as List<dynamic>;
    expect(saved.single, containsPair('utterances', isA<List<dynamic>>()));
  });

  test('conversation JSON reserves local LLM review state', () async {
    final storage = _MemoryStorage();
    final store = LocalSessionStore(storage);

    await store.save(const LocalSessionSummary(
      id: 'conversation-review',
      createdAt: '2026-08-30T09:00:00.000Z',
      audioPath: '/local/conversation-review.wav',
      durationSeconds: 12,
      transcript: '我不想再听了。',
      emotionValue: 0,
    ));

    final saved = jsonDecode(storage.values['local_session_summaries_v1']!)
        as List<dynamic>;
    expect(saved.single, containsPair('llm_review', isNull));
  });

  test('conversation JSON preserves per-utterance score and recording group',
      () async {
    final storage = _MemoryStorage();
    final store = LocalSessionStore(storage);
    await store.save(const LocalSessionSummary(
      id: 'conversation-score',
      recordingGroupId: 'group-1',
      createdAt: '2026-08-30T10:00:00.000Z',
      audioPath: '/local/conversation-score.wav',
      durationSeconds: 12,
      transcript: '你根本不在乎我。',
      emotionValue: 0,
      utterances: [
        LocalUtterance(
          id: 'utterance-1',
          startMilliseconds: 0,
          endMilliseconds: 1200,
          transcript: '你根本不在乎我。',
          rawEmotion: 'NEUTRAL',
          emotionLabel: '中性',
          emotionValue: 0,
          speakerLabel: '妈妈',
          llmReview: LlmSegmentReview(
            status: LlmSegmentReview.completed,
            attempts: 1,
            updatedAt: '2026-08-30T10:01:00.000Z',
            score: -72,
            markdown: '## 表达风险\n高',
          ),
        ),
      ],
    ));

    final loaded = await store.loadAll();

    expect(loaded.single.recordingGroupId, 'group-1');
    expect(loaded.single.utterances.single.llmReview?.score, -72);
    expect(
        loaded.single.utterances.single.llmReview?.markdown, contains('表达风险'));
  });

  test('deleting selected recordings preserves other local records', () async {
    final storage = _MemoryStorage();
    final store = LocalSessionStore(storage);
    await store.save(const LocalSessionSummary(
      id: 'keep',
      createdAt: '2026-08-30T09:00:00.000Z',
      audioPath: '/local/keep.wav',
      durationSeconds: 12,
      transcript: '保留这一条。',
      emotionValue: 0,
    ));
    await store.save(const LocalSessionSummary(
      id: 'remove',
      createdAt: '2026-08-29T09:00:00.000Z',
      audioPath: '/local/remove.wav',
      durationSeconds: 12,
      transcript: '删除这一条。',
      emotionValue: 0,
    ));

    await store.deleteByIds(['remove']);

    expect((await store.loadAll()).map((item) => item.id), ['keep']);
  });

  test('matching and correcting a speaker updates only local centroid data',
      () {
    final profile = SpeakerProfile(
      id: 'person-1',
      name: '妈妈',
      centroid: Float32List.fromList([1, 0]),
      sampleCount: 1,
      updatedAt: '2026-08-29T00:00:00.000Z',
    );
    const matcher = SpeakerMatcher();

    expect(
        matcher.match(Float32List.fromList([0.9, 0.1]), [profile])?.profile.id,
        'person-1');
    expect(matcher.match(Float32List.fromList([0, 1]), [profile]), isNull);

    final corrected = profile.withSample(
      Float32List.fromList([0.8, 0.2]),
      DateTime.utc(2026, 8, 29),
    );
    expect(corrected.sampleCount, 2);
    expect(corrected.centroid[0], closeTo(0.9, 0.0001));
  });

  test('local analysis retains ordered utterances for speaker correction', () {
    final analysis = LocalSpeechAnalysis.fromRecognitionResults(
      const [
        LocalRecognitionResult(text: '我们慢慢说。', emotion: 'NEUTRAL'),
        LocalRecognitionResult(text: '我愿意听。', emotion: 'HAPPY'),
      ],
      speakerCount: 1,
    );

    expect(_utterancesOf(analysis), hasLength(2));
    expect(_utterancesOf(analysis).last.transcript, '我愿意听。');
  });
}

List<dynamic> _utterancesOf(Object value) {
  try {
    return (value as dynamic).utterances as List<dynamic>;
  } on NoSuchMethodError {
    return const [];
  }
}

final class _MemoryStorage implements LocalStringStorage {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
