import 'dart:convert';

import 'conversation_models.dart';
import 'local_session_store.dart';

final class ConversationContextBlock {
  const ConversationContextBlock({
    required this.id,
    required this.recordingGroupId,
    required this.utteranceRefs,
    required this.isClosed,
    this.startMilliseconds = 0,
    this.endMilliseconds = 0,
    this.state = 'awaiting_confirmation',
    this.review,
  });

  final String id;
  final String? recordingGroupId;
  final List<ContextUtteranceRef> utteranceRefs;
  final bool isClosed;
  final int startMilliseconds;
  final int endMilliseconds;
  final String state;
  final LlmReview? review;

  List<String> get utteranceIds =>
      utteranceRefs.map((ref) => ref.utteranceId).toList(growable: false);

  Map<String, Object?> toJson() => {
        'id': id,
        'recording_group_id': recordingGroupId,
        'utterance_refs':
            utteranceRefs.map((ref) => ref.toJson()).toList(growable: false),
        'is_closed': isClosed,
        'start_milliseconds': startMilliseconds,
        'end_milliseconds': endMilliseconds,
        'state': state,
        'review': review?.toJson(),
      };

  factory ConversationContextBlock.fromJson(Map<String, dynamic> json) =>
      ConversationContextBlock(
        id: json['id']?.toString() ?? '',
        recordingGroupId: json['recording_group_id']?.toString(),
        utteranceRefs: (json['utterance_refs'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((item) =>
                ContextUtteranceRef.fromJson(Map<String, dynamic>.from(item)))
            .toList(growable: false),
        isClosed: json['is_closed'] == true,
        startMilliseconds: (json['start_milliseconds'] as num?)?.toInt() ?? 0,
        endMilliseconds: (json['end_milliseconds'] as num?)?.toInt() ?? 0,
        state: json['state']?.toString() ?? 'awaiting_confirmation',
        review: json['review'] is Map
            ? LlmReview.fromJson(
                Map<String, dynamic>.from(json['review'] as Map))
            : null,
      );
}

final class ContextUtteranceRef {
  const ContextUtteranceRef(
      {required this.sessionId, required this.utteranceId});
  final String sessionId;
  final String utteranceId;

  Map<String, String> toJson() => {
        'session_id': sessionId,
        'utterance_id': utteranceId,
      };

  factory ContextUtteranceRef.fromJson(Map<String, dynamic> json) =>
      ContextUtteranceRef(
        sessionId: json['session_id']?.toString() ?? '',
        utteranceId: json['utterance_id']?.toString() ?? '',
      );
}

final class ContextBlockBuilder {
  static final _sentenceEnd = RegExp(r'[。！？…][”』]?$');

  static List<ConversationContextBlock> build(
    Iterable<LocalSessionSummary> sessions, {
    required bool recordingStopped,
  }) {
    final sorted = sessions.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final blocks = <ConversationContextBlock>[];
    final refs = <ContextUtteranceRef>[];
    DateTime? blockStart;
    DateTime? previousEnd;
    String? group;
    var lastText = '';
    void close() {
      if (refs.isEmpty) return;
      blocks.add(ConversationContextBlock(
        id: 'block-${refs.first.sessionId}-${refs.first.utteranceId}',
        recordingGroupId: group,
        utteranceRefs: List.unmodifiable(refs),
        isClosed: recordingStopped || _sentenceEnd.hasMatch(lastText.trim()),
        startMilliseconds: blockStart?.millisecondsSinceEpoch ?? 0,
        endMilliseconds: previousEnd?.millisecondsSinceEpoch ?? 0,
        state: recordingStopped || _sentenceEnd.hasMatch(lastText.trim())
            ? 'awaiting_confirmation'
            : 'awaiting_continuation',
      ));
      refs.clear();
      blockStart = null;
    }

    for (final session in sorted) {
      final created = DateTime.tryParse(session.createdAt)?.toLocal();
      if (created == null) continue;
      for (final utterance in session.utterances) {
        if (utterance.transcript.trim().isEmpty) continue;
        final start =
            created.add(Duration(milliseconds: utterance.startMilliseconds));
        final previousEndValue = previousEnd;
        final gap = previousEndValue == null
            ? 0
            : start.difference(previousEndValue).inMilliseconds;
        final blockStartValue = blockStart;
        final exceedsDuration = blockStartValue != null &&
            start.difference(blockStartValue).inMilliseconds > 45000;
        final exceedsText = refs.isNotEmpty &&
            _blockTextLength(sorted, refs) +
                    utterance.transcript.trim().length >
                180;
        if (refs.isNotEmpty &&
            (session.recordingGroupId != group ||
                gap > 3000 ||
                exceedsDuration ||
                exceedsText)) {
          close();
        }
        group = session.recordingGroupId;
        blockStart ??= start;
        refs.add(ContextUtteranceRef(
            sessionId: session.id, utteranceId: utterance.id));
        lastText = utterance.transcript;
        previousEnd =
            created.add(Duration(milliseconds: utterance.endMilliseconds));
      }
    }
    close();
    return blocks;
  }

  static int _blockTextLength(
    Iterable<LocalSessionSummary> sessions,
    Iterable<ContextUtteranceRef> utteranceRefs,
  ) {
    final keys = utteranceRefs
        .map((ref) => '${ref.sessionId}/${ref.utteranceId}')
        .toSet();
    return sessions.fold(
        0,
        (total, session) =>
            total +
            session.utterances
                .where((utterance) =>
                    keys.contains('${session.id}/${utterance.id}'))
                .fold(
                    0,
                    (sum, utterance) =>
                        sum + utterance.transcript.trim().length));
  }
}

final class ContextBlockStore {
  ContextBlockStore(this._storage);

  static const _key = 'local_context_blocks_v1';
  final LocalStringStorage _storage;

  Future<List<ConversationContextBlock>> loadAll() async {
    final raw = await _storage.read(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((item) => ConversationContextBlock.fromJson(
              Map<String, dynamic>.from(item)))
          .where((item) => item.id.isNotEmpty && item.utteranceRefs.isNotEmpty)
          .toList(growable: false);
    } on FormatException {
      return const [];
    }
  }

  Future<void> saveAll(Iterable<ConversationContextBlock> blocks) =>
      _storage.write(
        _key,
        jsonEncode(blocks.map((item) => item.toJson()).toList(growable: false)),
      );
}
