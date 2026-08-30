import 'package:flutter_test/flutter_test.dart';
import 'package:softerplease/local/conversation_models.dart';
import 'package:softerplease/local/local_session_store.dart';
import 'package:softerplease/local/score_trends.dart';

void main() {
  test('aggregates every scored utterance for one role into a daily bucket',
      () {
    final conversation = LocalSessionSummary(
      id: 'local-1',
      createdAt: '2026-08-30T01:00:00.000Z',
      audioPath: 'a.wav',
      durationSeconds: 12,
      transcript: 'x',
      emotionValue: 0,
      utterances: [
        _utterance('u1', '妈妈', -60),
        _utterance('u2', '妈妈', 20),
        _utterance('u3', '爸爸', 100),
      ],
    );

    final series = ScoreTrendBuilder.build(
      period: ScorePeriod.week,
      role: '妈妈',
      now: DateTime(2026, 8, 30, 10),
      conversations: [conversation],
    );

    expect(series.sampleCount, 2);
    expect(series.points.last.average, -20);
  });
}

LocalUtterance _utterance(String id, String role, int score) => LocalUtterance(
      id: id,
      startMilliseconds: 0,
      endMilliseconds: 1000,
      transcript: '测试',
      rawEmotion: '',
      emotionLabel: '',
      emotionValue: 0,
      speakerLabel: role,
      llmReview: LlmSegmentReview(
        status: LlmSegmentReview.completed,
        attempts: 1,
        updatedAt: '2026-08-30T01:00:00.000Z',
        score: score,
        markdown: '说明',
      ),
    );
