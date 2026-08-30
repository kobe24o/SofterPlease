import 'dart:async';

import 'conversation_models.dart';
import 'daily_advice.dart';
import 'local_session_store.dart';

typedef LoadConversations = Future<List<LocalSessionSummary>> Function();
typedef SaveConversation = Future<void> Function(LocalSessionSummary value);
typedef GenerateUtteranceScore = Future<String> Function(
  LocalSessionSummary conversation,
  LocalUtterance utterance,
);

final class ReviewRetryPolicy {
  static Duration delayFor(int attempts) => switch (attempts) {
        <= 1 => const Duration(seconds: 15),
        2 => const Duration(minutes: 1),
        3 => const Duration(minutes: 5),
        4 => const Duration(minutes: 20),
        5 => const Duration(hours: 1),
        _ => const Duration(hours: 3),
      };
}

final class LlmReviewQueue {
  LlmReviewQueue({
    required LoadConversations loadAll,
    required SaveConversation save,
    required GenerateUtteranceScore generate,
    DateTime Function()? now,
    this.minimumRequestInterval = const Duration(seconds: 3),
  })  : _loadAll = loadAll,
        _save = save,
        _generate = generate,
        _now = now ?? DateTime.now;

  final LoadConversations _loadAll;
  final SaveConversation _save;
  final GenerateUtteranceScore _generate;
  final DateTime Function() _now;
  final Duration minimumRequestInterval;
  Future<void>? _running;
  Timer? _retryTimer;
  DateTime? _lastRequestStartedAt;

  Future<void> enqueueUtterances(LocalSessionSummary conversation) async {
    final now = _now().toUtc().toIso8601String();
    await _save(conversation.copyWith(
      utterances: conversation.utterances.map((utterance) {
        if (utterance.transcript.trim().isEmpty ||
            utterance.llmReview?.status == LlmSegmentReview.completed) {
          return utterance;
        }
        return utterance.copyWith(
            llmReview: LlmSegmentReview(
          status: LlmSegmentReview.queued,
          attempts: 0,
          updatedAt: now,
        ));
      }).toList(growable: false),
    ));
    await runReady();
  }

  Future<void> resume() => runReady();

  Future<void> runReady() {
    final running = _running;
    if (running != null) return running.then((_) => runReady());
    final task = _drain();
    _running = task.whenComplete(() => _running = null);
    return _running!;
  }

  void dispose() => _retryTimer?.cancel();

  Future<void> _drain() async {
    while (true) {
      final conversations = await _loadAll();
      final task = _nextReady(conversations);
      if (task == null) {
        _scheduleNextRetry(conversations);
        return;
      }
      await _process(task.$1, task.$2);
    }
  }

  (LocalSessionSummary, LocalUtterance)? _nextReady(
    List<LocalSessionSummary> conversations,
  ) {
    final now = _now();
    final candidates = <(LocalSessionSummary, LocalUtterance)>[];
    for (final conversation in conversations) {
      for (final utterance in conversation.utterances) {
        final review = utterance.llmReview;
        final retryAt = DateTime.tryParse(review?.nextRetryAt ?? '');
        if (review != null &&
            utterance.transcript.trim().isNotEmpty &&
            review.status != LlmSegmentReview.completed &&
            (retryAt == null || !retryAt.isAfter(now))) {
          candidates.add((conversation, utterance));
        }
      }
    }
    candidates.sort((left, right) {
      final result = left.$1.createdAt.compareTo(right.$1.createdAt);
      return result == 0
          ? left.$2.startMilliseconds.compareTo(right.$2.startMilliseconds)
          : result;
    });
    return candidates.isEmpty ? null : candidates.first;
  }

  Future<void> _process(
    LocalSessionSummary conversation,
    LocalUtterance utterance,
  ) async {
    final attempts = utterance.llmReview!.attempts + 1;
    await _saveReview(
        conversation,
        utterance.id,
        LlmSegmentReview(
          status: LlmSegmentReview.queued,
          attempts: attempts,
          updatedAt: _now().toUtc().toIso8601String(),
        ));
    await _respectMinimumInterval();
    _lastRequestStartedAt = _now();
    try {
      final response = UtteranceScoreResponse.parse(
        await _generate(conversation, utterance),
      );
      await _saveReview(
          conversation,
          utterance.id,
          LlmSegmentReview(
            status: LlmSegmentReview.completed,
            attempts: attempts,
            updatedAt: _now().toUtc().toIso8601String(),
            score: response.score,
            markdown: response.markdown,
          ));
    } catch (error) {
      final retryAt = _now().add(ReviewRetryPolicy.delayFor(attempts));
      await _saveReview(
          conversation,
          utterance.id,
          LlmSegmentReview(
            status: LlmSegmentReview.retryWaiting,
            attempts: attempts,
            updatedAt: _now().toUtc().toIso8601String(),
            nextRetryAt: retryAt.toUtc().toIso8601String(),
            lastError: error.toString(),
          ));
    }
  }

  Future<void> _saveReview(
    LocalSessionSummary conversation,
    String utteranceId,
    LlmSegmentReview review,
  ) =>
      _save(conversation.copyWith(
        utterances: conversation.utterances
            .map((utterance) => utterance.id == utteranceId
                ? utterance.copyWith(llmReview: review)
                : utterance)
            .toList(growable: false),
      ));

  Future<void> _respectMinimumInterval() async {
    final last = _lastRequestStartedAt;
    if (last == null || minimumRequestInterval == Duration.zero) return;
    final remaining = minimumRequestInterval - _now().difference(last);
    if (remaining > Duration.zero) await Future<void>.delayed(remaining);
  }

  void _scheduleNextRetry(List<LocalSessionSummary> conversations) {
    _retryTimer?.cancel();
    DateTime? earliest;
    for (final utterance in conversations.expand((item) => item.utterances)) {
      final retryAt = DateTime.tryParse(utterance.llmReview?.nextRetryAt ?? '');
      if (retryAt != null &&
          retryAt.isAfter(_now()) &&
          (earliest == null || retryAt.isBefore(earliest))) {
        earliest = retryAt;
      }
    }
    if (earliest != null) {
      _retryTimer =
          Timer(earliest.difference(_now()), () => unawaited(runReady()));
    }
  }
}
