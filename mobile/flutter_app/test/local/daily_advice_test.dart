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
