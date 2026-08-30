import 'package:flutter_test/flutter_test.dart';
import 'package:softerplease/local/conversation_models.dart';
import 'package:softerplease/local/llm_review_queue.dart';
import 'package:softerplease/local/local_session_store.dart';

void main() {
  test('review queue serializes automatic requests and persists completion',
      () async {
    final conversations = [_conversation('one'), _conversation('two')];
    final started = <String>[];
    var activeRequests = 0;
    var peakActiveRequests = 0;
    final queue = LlmReviewQueue(
      loadAll: () async => conversations,
      save: (updated) async {
        final index = conversations.indexWhere((item) => item.id == updated.id);
        conversations[index] = updated;
      },
      generate: (conversation, utterance) async {
        started.add('${conversation.id}-${utterance.id}');
        activeRequests++;
        peakActiveRequests = peakActiveRequests < activeRequests
            ? activeRequests
            : peakActiveRequests;
        await Future<void>.delayed(Duration.zero);
        activeRequests--;
        return '{"score":-20,"markdown":"## 复核完成"}';
      },
      now: () => DateTime.utc(2026, 8, 30, 10),
      minimumRequestInterval: Duration.zero,
    );

    await Future.wait([
      queue.enqueueUtterances(conversations[0]),
      queue.enqueueUtterances(conversations[1]),
    ]);

    expect(started, ['one-utterance-1', 'two-utterance-1']);
    expect(peakActiveRequests, 1);
    expect(
        conversations.every((item) =>
            item.utterances.single.llmReview?.status ==
            LlmSegmentReview.completed),
        isTrue);
  });

  test('retry policy backs off after a failed automatic review', () {
    expect(ReviewRetryPolicy.delayFor(1), const Duration(seconds: 15));
    expect(ReviewRetryPolicy.delayFor(2), const Duration(minutes: 1));
    expect(ReviewRetryPolicy.delayFor(6), const Duration(hours: 3));
  });

  test('failed review remains persisted until its retry time', () async {
    final conversations = [_conversation('retry')];
    var now = DateTime.utc(2026, 8, 30, 10);
    var calls = 0;
    final queue = LlmReviewQueue(
      loadAll: () async => conversations,
      save: (updated) async {
        conversations[0] = updated;
      },
      generate: (_, __) async {
        calls++;
        if (calls == 1) throw StateError('temporarily unavailable');
        return '{"score":20,"markdown":"## 表达风险\\n低"}';
      },
      now: () => now,
      minimumRequestInterval: Duration.zero,
    );

    await queue.enqueueUtterances(conversations.single);
    expect(conversations.single.utterances.single.llmReview?.status,
        LlmSegmentReview.retryWaiting);
    expect(calls, 1);

    now = now.add(const Duration(seconds: 16));
    await queue.resume();

    expect(calls, 2);
    expect(conversations.single.utterances.single.llmReview?.status,
        LlmSegmentReview.completed);
    queue.dispose();
  });
}

LocalSessionSummary _conversation(String id) => LocalSessionSummary(
      id: id,
      createdAt: '2026-08-30T09:00:00.000Z',
      audioPath: '/local/$id.wav',
      durationSeconds: 12,
      transcript: '我不想再听了。',
      emotionValue: 0,
      utterances: const [
        LocalUtterance(
          id: 'utterance-1',
          startMilliseconds: 0,
          endMilliseconds: 1000,
          transcript: '我不想再听了。',
          rawEmotion: 'NEUTRAL',
          emotionLabel: '中性',
          emotionValue: 0,
        ),
      ],
    );
