class EmotionAnalysisResult {
  final double angerScore;
  final String emotionLevel;
  final EmotionDimensions emotionDimensions;
  final Map<String, dynamic> acousticFeatures;
  final double confidence;
  final String speakerId;
  final double speakerConfidence;

  EmotionAnalysisResult({
    required this.angerScore,
    required this.emotionLevel,
    required this.emotionDimensions,
    required this.acousticFeatures,
    required this.confidence,
    required this.speakerId,
    required this.speakerConfidence,
  });

  factory EmotionAnalysisResult.fromJson(Map<String, dynamic> json) {
    return EmotionAnalysisResult(
      angerScore: (json['anger_score'] as num).toDouble(),
      emotionLevel: json['emotion_level'] as String,
      emotionDimensions: EmotionDimensions.fromJson(
        json['emotion_dimensions'] as Map<String, dynamic>,
      ),
      acousticFeatures: json['acoustic_features'] as Map<String, dynamic>,
      confidence: (json['confidence'] as num).toDouble(),
      speakerId: json['speaker_id'] as String,
      speakerConfidence: (json['speaker_confidence'] as num).toDouble(),
    );
  }
}

class EmotionDimensions {
  final double valence;
  final double arousal;
  final double dominance;
  final double stress;
  final double impatience;

  EmotionDimensions({
    required this.valence,
    required this.arousal,
    required this.dominance,
    required this.stress,
    required this.impatience,
  });

  factory EmotionDimensions.fromJson(Map<String, dynamic> json) {
    return EmotionDimensions(
      valence: (json['valence'] as num).toDouble(),
      arousal: (json['arousal'] as num).toDouble(),
      dominance: (json['dominance'] as num).toDouble(),
      stress: (json['stress'] as num).toDouble(),
      impatience: (json['impatience'] as num).toDouble(),
    );
  }
}

class DailyReport {
  final String date;
  final int sessionCount;
  final int totalDurationSeconds;
  final int emotionEventCount;
  final Map<String, int> emotionEventsByLevel;
  final double avgAngerScore;
  final double maxAngerScore;
  final int feedbackShownCount;
  final int feedbackAcceptedCount;
  final double feedbackAcceptedRate;
  final double improvementScore;
  final String trendDirection;

  DailyReport({
    required this.date,
    required this.sessionCount,
    required this.totalDurationSeconds,
    required this.emotionEventCount,
    required this.emotionEventsByLevel,
    required this.avgAngerScore,
    required this.maxAngerScore,
    required this.feedbackShownCount,
    required this.feedbackAcceptedCount,
    required this.feedbackAcceptedRate,
    required this.improvementScore,
    required this.trendDirection,
  });

  factory DailyReport.fromJson(Map<String, dynamic> json) {
    return DailyReport(
      date: json['date'] as String,
      sessionCount: json['session_count'] as int,
      totalDurationSeconds: json['total_duration_seconds'] as int,
      emotionEventCount: json['emotion_event_count'] as int,
      emotionEventsByLevel: (json['emotion_events_by_level'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as int)) ??
          {},
      avgAngerScore: (json['avg_anger_score'] as num).toDouble(),
      maxAngerScore: (json['max_anger_score'] as num).toDouble(),
      feedbackShownCount: json['feedback_shown_count'] as int,
      feedbackAcceptedCount: json['feedback_accepted_count'] as int,
      feedbackAcceptedRate: (json['feedback_accepted_rate'] as num).toDouble(),
      improvementScore: (json['improvement_score'] as num).toDouble(),
      trendDirection: json['trend_direction'] as String,
    );
  }
}

class TimeSeriesReport {
  final String sessionId;
  final List<TimeSeriesPoint> points;

  TimeSeriesReport({
    required this.sessionId,
    required this.points,
  });

  factory TimeSeriesReport.fromJson(Map<String, dynamic> json) {
    return TimeSeriesReport(
      sessionId: json['session_id'] as String,
      points: (json['points'] as List)
          .map((p) => TimeSeriesPoint.fromJson(p as Map<String, dynamic>))
          .toList(),
    );
  }
}

class TimeSeriesPoint {
  final DateTime timestamp;
  final double angerScore;
  final String emotionLevel;
  final String speakerId;

  TimeSeriesPoint({
    required this.timestamp,
    required this.angerScore,
    required this.emotionLevel,
    required this.speakerId,
  });

  factory TimeSeriesPoint.fromJson(Map<String, dynamic> json) {
    return TimeSeriesPoint(
      timestamp: DateTime.parse(json['timestamp'] as String),
      angerScore: (json['anger_score'] as num).toDouble(),
      emotionLevel: json['emotion_level'] as String,
      speakerId: json['speaker_id'] as String,
    );
  }
}

class FamilyRangeReport {
  final String familyId;
  final String start;
  final String end;
  final List<DailyData> dailyData;

  FamilyRangeReport({
    required this.familyId,
    required this.start,
    required this.end,
    required this.dailyData,
  });

  factory FamilyRangeReport.fromJson(Map<String, dynamic> json) {
    return FamilyRangeReport(
      familyId: json['family_id'] as String,
      start: json['start'] as String,
      end: json['end'] as String,
      dailyData: (json['daily_data'] as List)
          .map((d) => DailyData.fromJson(d as Map<String, dynamic>))
          .toList(),
    );
  }
}

class DailyData {
  final String date;
  final int eventCount;
  final double avgAngerScore;
  final int highEmotionCount;

  DailyData({
    required this.date,
    required this.eventCount,
    required this.avgAngerScore,
    required this.highEmotionCount,
  });

  factory DailyData.fromJson(Map<String, dynamic> json) {
    return DailyData(
      date: json['date'] as String,
      eventCount: json['event_count'] as int,
      avgAngerScore: (json['avg_anger_score'] as num).toDouble(),
      highEmotionCount: json['high_emotion_count'] as int,
    );
  }
}
