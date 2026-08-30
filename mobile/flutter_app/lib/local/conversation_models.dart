import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

final class LlmReview {
  const LlmReview({
    required this.status,
    required this.attempts,
    required this.updatedAt,
    this.content,
    this.nextRetryAt,
    this.lastError,
  });

  static const queued = 'queued';
  static const retryWaiting = 'retry_waiting';
  static const completed = 'completed';
  static const unscored = 'unscored';

  final String status;
  final int attempts;
  final String updatedAt;
  final String? content;
  final String? nextRetryAt;
  final String? lastError;

  bool get isPending => status == queued || status == retryWaiting;

  Map<String, Object?> toJson() => {
        'status': status,
        'attempts': attempts,
        'updated_at': updatedAt,
        'content': content,
        'next_retry_at': nextRetryAt,
        'last_error': lastError,
      };

  factory LlmReview.fromJson(Map<String, dynamic> json) => LlmReview(
        status: json['status']?.toString() ?? queued,
        attempts: (json['attempts'] as num?)?.toInt() ?? 0,
        updatedAt: json['updated_at']?.toString() ?? '',
        content: json['content']?.toString(),
        nextRetryAt: json['next_retry_at']?.toString(),
        lastError: json['last_error']?.toString(),
      );
}

final class LlmSegmentReview {
  const LlmSegmentReview({
    required this.status,
    required this.attempts,
    required this.updatedAt,
    this.score,
    this.markdown,
    this.nextRetryAt,
    this.lastError,
  });

  static const queued = 'queued';
  static const retryWaiting = 'retry_waiting';
  static const completed = 'completed';
  static const unscored = 'unscored';

  final String status;
  final int attempts;
  final String updatedAt;
  final int? score;
  final String? markdown;
  final String? nextRetryAt;
  final String? lastError;

  Map<String, Object?> toJson() => {
        'status': status,
        'attempts': attempts,
        'updated_at': updatedAt,
        'score': score,
        'markdown': markdown,
        'next_retry_at': nextRetryAt,
        'last_error': lastError,
      };

  factory LlmSegmentReview.fromJson(Map<String, dynamic> json) =>
      LlmSegmentReview(
        status: json['status']?.toString() ?? queued,
        attempts: (json['attempts'] as num?)?.toInt() ?? 0,
        updatedAt: json['updated_at']?.toString() ?? '',
        score: (json['score'] as num?)?.toInt(),
        markdown: json['markdown']?.toString(),
        nextRetryAt: json['next_retry_at']?.toString(),
        lastError: json['last_error']?.toString(),
      );
}

final class LocalUtterance {
  const LocalUtterance({
    required this.id,
    required this.startMilliseconds,
    required this.endMilliseconds,
    required this.transcript,
    required this.rawEmotion,
    required this.emotionLabel,
    required this.emotionValue,
    this.speakerId,
    this.speakerLabel = '未知说话人',
    this.sessionCluster = 0,
    this.embedding,
    this.llmReview,
  });

  final String id;
  final int startMilliseconds;
  final int endMilliseconds;
  final String transcript;
  final String rawEmotion;
  final String emotionLabel;
  final int emotionValue;
  final String? speakerId;
  final String speakerLabel;
  final int sessionCluster;
  final Float32List? embedding;
  final LlmSegmentReview? llmReview;

  LocalUtterance copyWith({
    String? speakerId,
    String? speakerLabel,
    LlmSegmentReview? llmReview,
    bool clearLlmReview = false,
  }) =>
      LocalUtterance(
        id: id,
        startMilliseconds: startMilliseconds,
        endMilliseconds: endMilliseconds,
        transcript: transcript,
        rawEmotion: rawEmotion,
        emotionLabel: emotionLabel,
        emotionValue: emotionValue,
        speakerId: speakerId ?? this.speakerId,
        speakerLabel: speakerLabel ?? this.speakerLabel,
        sessionCluster: sessionCluster,
        embedding: embedding == null ? null : Float32List.fromList(embedding!),
        llmReview: clearLlmReview ? null : llmReview ?? this.llmReview,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'start_milliseconds': startMilliseconds,
        'end_milliseconds': endMilliseconds,
        'transcript': transcript,
        'raw_emotion': rawEmotion,
        'emotion_label': emotionLabel,
        'emotion_value': emotionValue,
        'speaker_id': speakerId,
        'speaker_label': speakerLabel,
        'session_cluster': sessionCluster,
        'embedding': embedding == null ? null : _encodeEmbedding(embedding!),
        'llm_review': llmReview?.toJson(),
      };

  factory LocalUtterance.fromJson(Map<String, dynamic> json) => LocalUtterance(
        id: json['id']?.toString() ?? '',
        startMilliseconds: (json['start_milliseconds'] as num?)?.toInt() ?? 0,
        endMilliseconds: (json['end_milliseconds'] as num?)?.toInt() ?? 0,
        transcript: json['transcript']?.toString() ?? '',
        rawEmotion: json['raw_emotion']?.toString() ?? '',
        emotionLabel: json['emotion_label']?.toString() ?? '中性',
        emotionValue: (json['emotion_value'] as num?)?.toInt() ?? 0,
        speakerId: json['speaker_id']?.toString(),
        speakerLabel: json['speaker_label']?.toString() ?? '未知说话人',
        sessionCluster: (json['session_cluster'] as num?)?.toInt() ?? 0,
        embedding: _decodeEmbedding(json['embedding']?.toString()),
        llmReview: json['llm_review'] is Map
            ? LlmSegmentReview.fromJson(
                Map<String, dynamic>.from(json['llm_review'] as Map))
            : null,
      );
}

final class SpeakerProfile {
  const SpeakerProfile({
    required this.id,
    required this.name,
    required this.centroid,
    required this.sampleCount,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final Float32List centroid;
  final int sampleCount;
  final String updatedAt;

  SpeakerProfile withSample(Float32List sample, DateTime now) => SpeakerProfile(
        id: id,
        name: name,
        centroid:
            SpeakerMatcher.weightedCentroid(centroid, sample, sampleCount),
        sampleCount: sampleCount + 1,
        updatedAt: now.toUtc().toIso8601String(),
      );

  SpeakerProfile rename(String value) => SpeakerProfile(
        id: id,
        name: value,
        centroid: Float32List.fromList(centroid),
        sampleCount: sampleCount,
        updatedAt: updatedAt,
      );

  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'centroid': _encodeEmbedding(centroid),
        'sample_count': sampleCount,
        'updated_at': updatedAt,
      };

  factory SpeakerProfile.fromJson(Map<String, dynamic> json) => SpeakerProfile(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '未命名成员',
        centroid:
            _decodeEmbedding(json['centroid']?.toString()) ?? Float32List(0),
        sampleCount: (json['sample_count'] as num?)?.toInt() ?? 0,
        updatedAt: json['updated_at']?.toString() ?? '',
      );
}

final class SpeakerMatch {
  const SpeakerMatch(this.profile, this.score);

  final SpeakerProfile profile;
  final double score;
}

final class SpeakerMatcher {
  const SpeakerMatcher({this.threshold = 0.60});

  final double threshold;

  SpeakerMatch? match(
      Float32List? embedding, Iterable<SpeakerProfile> profiles) {
    if (embedding == null || embedding.isEmpty) return null;
    SpeakerMatch? nearest;
    for (final profile in profiles) {
      final score = cosineSimilarity(profile.centroid, embedding);
      if (score < threshold || (nearest != null && score <= nearest.score)) {
        continue;
      }
      nearest = SpeakerMatch(profile, score);
    }
    return nearest;
  }

  static Float32List weightedCentroid(
    Float32List current,
    Float32List sample,
    int sampleCount,
  ) {
    if (current.length != sample.length || sample.isEmpty) {
      return Float32List.fromList(sample);
    }
    final next = Float32List(sample.length);
    for (var index = 0; index < next.length; index++) {
      next[index] =
          (current[index] * sampleCount + sample[index]) / (sampleCount + 1);
    }
    return next;
  }

  static double cosineSimilarity(Float32List left, Float32List right) {
    if (left.length != right.length || left.isEmpty) return -1;
    var dot = 0.0;
    var leftNorm = 0.0;
    var rightNorm = 0.0;
    for (var index = 0; index < left.length; index++) {
      dot += left[index] * right[index];
      leftNorm += left[index] * left[index];
      rightNorm += right[index] * right[index];
    }
    if (leftNorm == 0 || rightNorm == 0) return -1;
    return dot / (sqrt(leftNorm) * sqrt(rightNorm));
  }
}

String _encodeEmbedding(Float32List values) => base64Encode(
    values.buffer.asUint8List(values.offsetInBytes, values.lengthInBytes));

Float32List? _decodeEmbedding(String? encoded) {
  if (encoded == null || encoded.isEmpty) return null;
  try {
    final bytes = base64Decode(encoded);
    if (bytes.lengthInBytes % Float32List.bytesPerElement != 0) return null;
    return Float32List.view(bytes.buffer, bytes.offsetInBytes);
  } on FormatException {
    return null;
  }
}
