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
      generate: (conversation) async {
        started.add(conversation.id);
        activeRequests++;
        peakActiveRequests = peakActiveRequests < activeRequests
            ? activeRequests
            : peakActiveRequests;
        await Future<void>.delayed(Duration.zero);
        activeRequests--;
        return '# 复核完成\n- 请暂停后再表达。';
      },
      now: () => DateTime.utc(2026, 8, 30, 10),
      minimumRequestInterval: Duration.zero,
    );

    await Future.wait([
      queue.enqueue(conversations[0]),
      queue.enqueue(conversations[1]),
    ]);

    expect(started, ['one', 'two']);
    expect(peakActiveRequests, 1);
    expect(conversations.every((item) => item.llmReview?.status == 'completed'),
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
      generate: (_) async {
        calls++;
        if (calls == 1) throw StateError('temporarily unavailable');
        return '## 表达风险\n低';
      },
      now: () => now,
      minimumRequestInterval: Duration.zero,
    );

    await queue.enqueue(conversations.single);
    expect(conversations.single.llmReview?.status, LlmReview.retryWaiting);
    expect(calls, 1);

    now = now.add(const Duration(seconds: 16));
    await queue.resume();

    expect(calls, 2);
    expect(conversations.single.llmReview?.status, LlmReview.completed);
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
    );
