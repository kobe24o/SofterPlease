import '../lib/local/local_session_store.dart';

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
    ),
  );

  final sessions = await store.loadAll();
  if (sessions.length != 1 || sessions.single.transcript != '先停一下，我们慢慢说。') {
    throw StateError('local session was not persisted');
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
