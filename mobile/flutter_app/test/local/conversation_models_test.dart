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

  test('matching and correcting a speaker updates only local centroid data',
      () {
    final profile = SpeakerProfile(
      id: 'person-1',
      name: '妈妈',
      centroid: Float32List.fromList([1, 0]),
      sampleCount: 1,
      updatedAt: '2026-08-29T00:00:00.000Z',
    );
    final matcher = SpeakerMatcher();

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
