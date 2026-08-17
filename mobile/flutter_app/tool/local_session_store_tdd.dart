import 'package:softerplease/local/local_session_store.dart';

Future<void> main() async {
  final values = <String, String>{};
  final store = LocalSessionStore(_MapStorage(values));

  await store.save(
    const LocalSessionSummary(
      id: 'session-1',
      createdAt: '2026-08-02T12:00:00Z',
      audioPath: '/private/session-1.wav',
      durationSeconds: 12,
      transcript: '先停一下，我们慢慢说。',
      emotionValue: 0,
      analysisState: 'completed',
      emotionLabel: '平静',
      speakerLabel: '妈妈',
    ),
  );

  final sessions = await store.loadAll();
  if (sessions.length != 1 ||
      sessions.single.transcript != '先停一下，我们慢慢说。' ||
      sessions.single.analysisState != 'completed' ||
      sessions.single.speakerLabel != '妈妈') {
    throw StateError('local session was not persisted');
  }

  await store.save(
    sessions.single.copyWith(
      transcript: '我们换一种说法。',
      emotionLabel: '积极',
      speakerLabel: '检测到 2 位说话人',
    ),
  );
  final updated = await store.loadAll();
  if (updated.single.transcript != '我们换一种说法。' ||
      updated.single.speakerLabel != '检测到 2 位说话人') {
    throw StateError('local session analysis was not updated');
  }
}

final class _MapStorage implements LocalStringStorage {
  _MapStorage(this.values);

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
