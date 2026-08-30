import 'package:flutter_test/flutter_test.dart';
import 'package:softerplease/local/context_blocks.dart';
import 'package:softerplease/local/conversation_models.dart';
import 'package:softerplease/local/local_session_store.dart';

void main() {
  test('joins a trailing sentence across WAV segments in one recording group',
      () {
    final blocks = ContextBlockBuilder.build([
      _session('a', 0, [_utterance('u1', 0, 1000, '我觉得这件事')]),
      _session('b', 1000, [_utterance('u2', 0, 1200, '我们可以慢慢谈。')]),
    ], recordingStopped: false);

    expect(blocks, hasLength(1));
    expect(blocks.single.utteranceRefs.map((item) => item.utteranceId),
        ['u1', 'u2']);
    expect(blocks.single.isClosed, isTrue);
  });

  test('splits a context block after a gap longer than three seconds', () {
    final blocks = ContextBlockBuilder.build([
      _session('a', 0, [_utterance('u1', 0, 1000, '第一句。')]),
      _session('b', 5000, [_utterance('u2', 0, 1000, '第二句。')]),
    ], recordingStopped: false);

    expect(blocks, hasLength(2));
  });

  test('persists block references and state as local JSON', () async {
    final storage = _MemoryStorage();
    final block = ContextBlockBuilder.build([
      _session('a', 0, [_utterance('u1', 0, 1000, '完成。')]),
    ], recordingStopped: true)
        .single;
    final store = ContextBlockStore(storage);
    await store.saveAll([block]);
    final restored = await store.loadAll();
    expect(restored.single.id, block.id);
    expect(restored.single.utteranceRefs.single.utteranceId, 'u1');
    expect(restored.single.state, 'awaiting_confirmation');
  });
}

final class _MemoryStorage implements LocalStringStorage {
  String? value;
  @override
  Future<String?> read(String key) async => value;
  @override
  Future<void> write(String key, String next) async => value = next;
}

LocalSessionSummary _session(
        String id, int millis, List<LocalUtterance> items) =>
    LocalSessionSummary(
        id: id,
        createdAt: DateTime(2026, 8, 30)
            .add(Duration(milliseconds: millis))
            .toIso8601String(),
        audioPath: '$id.wav',
        durationSeconds: 2,
        transcript: '',
        emotionValue: 0,
        recordingGroupId: 'group',
        utterances: items);

LocalUtterance _utterance(String id, int start, int end, String text) =>
    LocalUtterance(
        id: id,
        startMilliseconds: start,
        endMilliseconds: end,
        transcript: text,
        rawEmotion: '',
        emotionLabel: '',
        emotionValue: 0);
