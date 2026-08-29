import 'dart:convert';

import 'conversation_models.dart';

abstract interface class LocalStringStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

final class LocalSessionSummary {
  const LocalSessionSummary({
    required this.id,
    required this.createdAt,
    required this.audioPath,
    required this.durationSeconds,
    required this.transcript,
    required this.emotionValue,
    this.analysisState = 'awaiting_model',
    this.emotionLabel = '',
    this.speakerLabel = '',
    this.utterances = const [],
  });

  final String id;
  final String createdAt;
  final String audioPath;
  final int durationSeconds;
  final String transcript;
  final int emotionValue;
  final String analysisState;
  final String emotionLabel;
  final String speakerLabel;
  final List<LocalUtterance> utterances;

  LocalSessionSummary copyWith({
    String? transcript,
    int? emotionValue,
    String? analysisState,
    String? emotionLabel,
    String? speakerLabel,
    List<LocalUtterance>? utterances,
  }) {
    return LocalSessionSummary(
      id: id,
      createdAt: createdAt,
      audioPath: audioPath,
      durationSeconds: durationSeconds,
      transcript: transcript ?? this.transcript,
      emotionValue: emotionValue ?? this.emotionValue,
      analysisState: analysisState ?? this.analysisState,
      emotionLabel: emotionLabel ?? this.emotionLabel,
      speakerLabel: speakerLabel ?? this.speakerLabel,
      utterances: utterances ?? this.utterances,
    );
  }

  Map<String, Object> toJson() => {
        'id': id,
        'created_at': createdAt,
        'audio_path': audioPath,
        'duration_seconds': durationSeconds,
        'transcript': transcript,
        'emotion_value': emotionValue,
        'analysis_state': analysisState,
        'emotion_label': emotionLabel,
        'speaker_label': speakerLabel,
        'utterances': utterances.map((item) => item.toJson()).toList(),
      };

  factory LocalSessionSummary.fromJson(Map<String, dynamic> json) {
    return LocalSessionSummary(
      id: json['id']?.toString() ?? '',
      createdAt: json['created_at']?.toString() ?? '',
      audioPath: json['audio_path']?.toString() ?? '',
      durationSeconds: (json['duration_seconds'] as num?)?.toInt() ?? 0,
      transcript: json['transcript']?.toString() ?? '',
      emotionValue: (json['emotion_value'] as num?)?.toInt() ?? 0,
      analysisState: json['analysis_state']?.toString() ?? 'awaiting_model',
      emotionLabel: json['emotion_label']?.toString() ?? '',
      speakerLabel: json['speaker_label']?.toString() ?? '',
      utterances: (json['utterances'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) =>
              LocalUtterance.fromJson(Map<String, dynamic>.from(item)))
          .where((item) => item.id.isNotEmpty)
          .toList(growable: false),
    );
  }
}

final class LocalSpeakerStore {
  LocalSpeakerStore(this._storage);

  static const _key = 'local_speaker_profiles_v1';
  final LocalStringStorage _storage;

  Future<List<SpeakerProfile>> loadAll() async {
    final raw = await _storage.read(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((item) =>
              SpeakerProfile.fromJson(Map<String, dynamic>.from(item)))
          .where((item) => item.id.isNotEmpty && item.centroid.isNotEmpty)
          .toList(growable: false);
    } on FormatException {
      return const [];
    }
  }

  Future<void> save(SpeakerProfile profile) async {
    final profiles = await loadAll();
    final next = [
      profile,
      ...profiles.where((item) => item.id != profile.id),
    ];
    await _storage.write(
      _key,
      jsonEncode(next.map((item) => item.toJson()).toList(growable: false)),
    );
  }
}

final class LocalSessionStore {
  LocalSessionStore(this._storage);

  static const _key = 'local_session_summaries_v1';

  final LocalStringStorage _storage;

  Future<void> save(LocalSessionSummary summary) async {
    final existing = await loadAll();
    final next = [
      summary,
      ...existing.where((item) => item.id != summary.id),
    ].take(100).toList(growable: false);
    await _storage.write(
      _key,
      jsonEncode(next.map((item) => item.toJson()).toList(growable: false)),
    );
  }

  Future<List<LocalSessionSummary>> loadAll() async {
    final raw = await _storage.read(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((item) =>
              LocalSessionSummary.fromJson(Map<String, dynamic>.from(item)))
          .where((item) => item.id.isNotEmpty && item.audioPath.isNotEmpty)
          .toList(growable: false);
    } on FormatException {
      return const [];
    }
  }
}
