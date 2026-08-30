import 'dart:async';

import 'conversation_models.dart';
import 'local_session_store.dart';

typedef LoadConversations = Future<List<LocalSessionSummary>> Function();
typedef SaveConversation = Future<void> Function(LocalSessionSummary value);
typedef GenerateConversationReview = Future<String> Function(
  LocalSessionSummary conversation,
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
    required GenerateConversationReview generate,
    DateTime Function()? now,
    this.minimumRequestInterval = const Duration(seconds: 3),
  })  : _loadAll = loadAll,
        _save = save,
        _generate = generate,
        _now = now ?? DateTime.now;

  final LoadConversations _loadAll;
  final SaveConversation _save;
  final GenerateConversationReview _generate;
  final DateTime Function() _now;
  final Duration minimumRequestInterval;
  Future<void>? _running;
  Timer? _retryTimer;
  DateTime? _lastRequestStartedAt;

  Future<void> enqueue(LocalSessionSummary conversation) async {
    if (conversation.transcript.trim().isEmpty) return;
    final now = _now().toUtc().toIso8601String();
    await _save(conversation.copyWith(
      llmReview: LlmReview(
        status: LlmReview.queued,
        attempts: 0,
        updatedAt: now,
      ),
    ));
    await runReady();
  }

  Future<void> resume() => runReady();

  Future<void> runReady() {
    final running = _running;
    if (running != null) {
      return running.then((_) => runReady());
    }
    final task = _drain();
    _running = task.whenComplete(() => _running = null);
    return _running!;
  }

  void dispose() => _retryTimer?.cancel();

  Future<void> _drain() async {
    while (true) {
      final conversations = await _loadAll();
      final next = _nextReady(conversations);
      if (next == null) {
        _scheduleNextRetry(conversations);
        return;
      }
      await _process(next);
    }
  }

  LocalSessionSummary? _nextReady(List<LocalSessionSummary> conversations) {
    final now = _now();
    final candidates = conversations.where((conversation) {
      final review = conversation.llmReview;
      if (review == null || conversation.transcript.trim().isEmpty) {
        return false;
      }
      if (review.status == LlmReview.completed) {
        return false;
      }
      final retryAt = DateTime.tryParse(review.nextRetryAt ?? '');
      return retryAt == null || !retryAt.isAfter(now);
    }).toList(growable: false)
      ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    return candidates.isEmpty ? null : candidates.first;
  }

  Future<void> _process(LocalSessionSummary conversation) async {
    final previous = conversation.llmReview!;
    final attempts = previous.attempts + 1;
    await _save(conversation.copyWith(
      llmReview: LlmReview(
        status: LlmReview.queued,
        attempts: attempts,
        updatedAt: _now().toUtc().toIso8601String(),
      ),
    ));
    await _respectMinimumInterval();
    _lastRequestStartedAt = _now();
    try {
      final content = await _generate(conversation);
      await _save(conversation.copyWith(
        llmReview: LlmReview(
          status: LlmReview.completed,
          attempts: attempts,
          updatedAt: _now().toUtc().toIso8601String(),
          content: content,
        ),
      ));
    } catch (error) {
      final retryAt = _now().add(ReviewRetryPolicy.delayFor(attempts));
      await _save(conversation.copyWith(
        llmReview: LlmReview(
          status: LlmReview.retryWaiting,
          attempts: attempts,
          updatedAt: _now().toUtc().toIso8601String(),
          nextRetryAt: retryAt.toUtc().toIso8601String(),
          lastError: error.toString(),
        ),
      ));
    }
  }

  Future<void> _respectMinimumInterval() async {
    final lastStarted = _lastRequestStartedAt;
    if (lastStarted == null || minimumRequestInterval == Duration.zero) return;
    final remaining = minimumRequestInterval - _now().difference(lastStarted);
    if (remaining > Duration.zero) await Future<void>.delayed(remaining);
  }

  void _scheduleNextRetry(List<LocalSessionSummary> conversations) {
    _retryTimer?.cancel();
    final nextRetry = conversations
        .map((item) => DateTime.tryParse(item.llmReview?.nextRetryAt ?? ''))
        .whereType<DateTime>()
        .where((value) => value.isAfter(_now()))
        .fold<DateTime?>(
            null,
            (earliest, value) => earliest == null || value.isBefore(earliest)
                ? value
                : earliest);
    if (nextRetry == null) {
      return;
    }
    _retryTimer = Timer(nextRetry.difference(_now()), () {
      unawaited(runReady());
    });
  }
}
