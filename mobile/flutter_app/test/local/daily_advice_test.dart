import 'package:flutter_test/flutter_test.dart';
import 'package:softerplease/local/daily_advice.dart';
import 'package:softerplease/local/local_session_store.dart';

void main() {
  test('daily advice includes only the selected day and labels speakers', () {
    final request = DailyAdviceRequest.forDay(
      DateTime(2026, 8, 29),
      [
        _summary('2026-08-29T09:00:00.000Z', '妈妈', '我愿意听。'),
        _summary('2026-08-28T09:00:00.000Z', '爸爸', '不应发送。'),
      ],
    );

    expect(request.transcript, contains('妈妈：我愿意听。'));
    expect(request.transcript, isNot(contains('不应发送。')));
    expect(request.messages().first['content'], contains('Markdown'));
  });

  test('advice response extracts OpenAI compatible message content', () {
    expect(
      DailyAdviceResponse.extract({
        'choices': [
          {
            'message': {'content': '先倾听，再表达需要。'},
          },
        ],
      }),
      '先倾听，再表达需要。',
    );
  });

  test('conversation review asks for Markdown risk feedback on one recording',
      () {
    final request = ConversationReviewRequest.forConversation(
      _summary('2026-08-30T09:00:00.000Z', '妈妈', '你根本不在乎我。'),
    );

    expect(request.messages().last['content'], contains('你根本不在乎我。'));
    expect(request.messages().first['content'], contains('Markdown'));
  });

  test('utterance score requires an integer score within the fixed range', () {
    expect(
      UtteranceScoreResponse.parse('{"score":-72,"markdown":"## 依据\\n语气尖锐"}')
          .score,
      -72,
    );
    expect(
      () => UtteranceScoreResponse.parse('{"score":101,"markdown":"x"}'),
      throwsFormatException,
    );
  });

  test('saving settings with a blank key keeps the securely stored key',
      () async {
    final secure = _MemorySecureStorage()
      ..values[AdviceSettingsStore.apiKeyStorageKey] = 'saved-key';
    final store = AdviceSettingsStore(_MemoryStorage(), secure);

    await store.save(const LlmSettings(), '');

    expect(await store.readApiKey(), 'saved-key');
  });
}

LocalSessionSummary _summary(String createdAt, String speaker, String text) =>
    LocalSessionSummary(
      id: createdAt,
      createdAt: createdAt,
      audioPath: '/local/$createdAt.wav',
      durationSeconds: 10,
      transcript: text,
      emotionValue: 0,
      speakerLabel: speaker,
    );

final class _MemoryStorage implements LocalStringStorage {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

final class _MemorySecureStorage implements SecureTextStorage {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
