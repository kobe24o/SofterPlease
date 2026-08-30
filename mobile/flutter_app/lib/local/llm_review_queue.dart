import 'dart:async';

import 'conversation_models.dart';
import 'context_blocks.dart';
import 'daily_advice.dart';
import 'local_session_store.dart';

typedef LoadConversations = Future<List<LocalSessionSummary>> Function();
typedef SaveConversation = Future<void> Function(LocalSessionSummary value);
typedef GenerateUtteranceScore = Future<String> Function(
  LocalSessionSummary conversation,
  LocalUtterance utterance,
);
typedef GenerateContextBlockScore = Future<String> Function(
  ConversationContextBlock block,
  List<LocalSessionSummary> conversations,
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
            utterance.llmReview != null) {
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

/// Serializes context-block requests. A block is sent only after every
/// non-empty utterance has a confirmed speaker, so a short VAD fragment never
/// becomes an isolated model request.
final class LlmContextBlockQueue {
  LlmContextBlockQueue({
    required LoadConversations loadAll,
    required SaveConversation save,
    required GenerateContextBlockScore generate,
    DateTime Function()? now,
    this.minimumRequestInterval = const Duration(seconds: 3),
  })  : _loadAll = loadAll,
        _save = save,
        _generate = generate,
        _now = now ?? DateTime.now;

  final LoadConversations _loadAll;
  final SaveConversation _save;
  final GenerateContextBlockScore _generate;
  final DateTime Function() _now;
  final Duration minimumRequestInterval;
  Future<void>? _running;
  Timer? _retryTimer;
  DateTime? _lastRequestStartedAt;

  Future<void> enqueueAvailable({bool recordingStopped = false}) =>
      _run(recordingStopped: recordingStopped);

  Future<void> resume() => _run(recordingStopped: true);

  Future<void> _run({required bool recordingStopped}) {
    final running = _running;
    if (running != null)
      return running.then((_) => _run(recordingStopped: recordingStopped));
    final task = _drain(recordingStopped: recordingStopped);
    _running = task.whenComplete(() => _running = null);
    return _running!;
  }

  void dispose() => _retryTimer?.cancel();

  Future<void> _drain({required bool recordingStopped}) async {
    while (true) {
      final conversations = await _loadAll();
      final blocks = ContextBlockBuilder.build(
        conversations,
        recordingStopped: recordingStopped,
      );
      final block = _nextReady(blocks, conversations);
      if (block == null) {
        _scheduleNextRetry(conversations);
        return;
      }
      await _process(block, conversations);
    }
  }

  ConversationContextBlock? _nextReady(
    List<ConversationContextBlock> blocks,
    List<LocalSessionSummary> conversations,
  ) {
    final byKey = <String, LocalUtterance>{};
    for (final conversation in conversations) {
      for (final utterance in conversation.utterances) {
        byKey['${conversation.id}/${utterance.id}'] = utterance;
      }
    }
    final now = _now();
    for (final block in blocks) {
      if (!block.isClosed || block.utteranceRefs.isEmpty) continue;
      final utterances = block.utteranceRefs
          .map((ref) => byKey['${ref.sessionId}/${ref.utteranceId}'])
          .whereType<LocalUtterance>()
          .where((item) => item.transcript.trim().isNotEmpty)
          .toList(growable: false);
      if (utterances.isEmpty ||
          utterances.any(
              (item) => item.speakerId == null || item.speakerId!.isEmpty)) {
        continue;
      }
      if (utterances.any((item) =>
          item.llmReview?.status == LlmSegmentReview.completed ||
          item.llmReview?.status == LlmSegmentReview.unscored)) {
        continue;
      }
      final retryTimes = utterances
          .map((item) => DateTime.tryParse(item.llmReview?.nextRetryAt ?? ''))
          .whereType<DateTime>()
          .toList(growable: false);
      if (retryTimes.any((time) => time.isAfter(now))) {
        continue;
      }
      return block;
    }
    return null;
  }

  Future<void> _process(
    ConversationContextBlock block,
    List<LocalSessionSummary> conversations,
  ) async {
    final refs = block.utteranceRefs;
    final bySession = <String, LocalSessionSummary>{
      for (final conversation in conversations) conversation.id: conversation,
    };
    final attempts = refs
            .map((ref) =>
                bySession[ref.sessionId]
                    ?.utterances
                    .firstWhere((item) => item.id == ref.utteranceId,
                        orElse: () => const LocalUtterance(
                            id: '',
                            startMilliseconds: 0,
                            endMilliseconds: 0,
                            transcript: '',
                            rawEmotion: '',
                            emotionLabel: '',
                            emotionValue: 0))
                    .llmReview
                    ?.attempts ??
                0)
            .fold<int>(0, (max, value) => value > max ? value : max) +
        1;
    await _markAll(
        block,
        bySession,
        (sessionId, item) => item.copyWith(
              llmReview: LlmSegmentReview(
                  status: LlmSegmentReview.queued,
                  attempts: attempts,
                  updatedAt: _now().toUtc().toIso8601String()),
            ));
    await _respectMinimumInterval();
    _lastRequestStartedAt = _now();
    try {
      final response = ContextBlockScoreResponse.parse(
          await _generate(block, conversations));
      await _markAll(block, bySession, (sessionId, item) {
        final key = '$sessionId/${item.id}';
        final score = response.scores[key];
        final isFirst = block.utteranceRefs.first.sessionId == sessionId &&
            block.utteranceRefs.first.utteranceId == item.id;
        return item.copyWith(
          llmReview: score == null
              ? LlmSegmentReview(
                  status: LlmSegmentReview.unscored,
                  attempts: attempts,
                  updatedAt: _now().toUtc().toIso8601String())
              : LlmSegmentReview(
                  status: LlmSegmentReview.completed,
                  attempts: attempts,
                  updatedAt: _now().toUtc().toIso8601String(),
                  score: score.score,
                  markdown: isFirst
                      ? '${response.markdown}\n\n${score.markdown}'
                      : score.markdown),
        );
      });
    } catch (error) {
      final retryAt = _now().add(ReviewRetryPolicy.delayFor(attempts));
      await _markAll(
          block,
          bySession,
          (sessionId, item) => item.copyWith(
                llmReview: LlmSegmentReview(
                    status: LlmSegmentReview.retryWaiting,
                    attempts: attempts,
                    updatedAt: _now().toUtc().toIso8601String(),
                    nextRetryAt: retryAt.toUtc().toIso8601String(),
                    lastError: error.toString()),
              ));
    }
  }

  Future<void> _markAll(
    ConversationContextBlock block,
    Map<String, LocalSessionSummary> bySession,
    LocalUtterance Function(String sessionId, LocalUtterance item) update,
  ) async {
    for (final conversation in bySession.values) {
      if (!block.utteranceRefs.any((ref) => ref.sessionId == conversation.id))
        continue;
      await _save(conversation.copyWith(
        utterances: conversation.utterances
            .map((item) => block.utteranceRefs.any((ref) =>
                    ref.sessionId == conversation.id &&
                    ref.utteranceId == item.id)
                ? update(conversation.id, item)
                : item)
            .toList(growable: false),
      ));
    }
  }

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
          Timer(earliest.difference(_now()), () => unawaited(resume()));
    }
  }
}
