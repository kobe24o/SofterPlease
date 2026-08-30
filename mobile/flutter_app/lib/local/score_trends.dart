import 'local_session_store.dart';
import 'conversation_models.dart';

enum ScorePeriod { day, week, month, year }

final class ScoreTrendPoint {
  const ScoreTrendPoint({required this.start, required this.average});
  final DateTime start;
  final double? average;
}

final class RoleScoreSeries {
  const RoleScoreSeries({required this.points, required this.sampleCount});
  final List<ScoreTrendPoint> points;
  final int sampleCount;
}

final class ScoreTrendBuilder {
  static RoleScoreSeries build({
    required ScorePeriod period,
    required String role,
    required DateTime now,
    required Iterable<LocalSessionSummary> conversations,
  }) {
    final starts = _starts(period, now);
    final values = <DateTime, List<int>>{for (final start in starts) start: []};
    for (final conversation in conversations) {
      final created = DateTime.tryParse(conversation.createdAt)?.toLocal();
      if (created == null) {
        continue;
      }
      for (final utterance in conversation.utterances) {
        final review = utterance.llmReview;
        if (utterance.speakerLabel != role ||
            review?.status != LlmSegmentReview.completed ||
            review?.score == null) {
          continue;
        }
        final at =
            created.add(Duration(milliseconds: utterance.startMilliseconds));
        final bucket = _bucket(period, at);
        values[bucket]?.add(review!.score!);
      }
    }
    return RoleScoreSeries(
      points: starts.map((start) {
        final scores = values[start]!;
        return ScoreTrendPoint(
            start: start,
            average: scores.isEmpty
                ? null
                : scores.reduce((a, b) => a + b) / scores.length);
      }).toList(growable: false),
      sampleCount: values.values.fold(0, (total, item) => total + item.length),
    );
  }

  static List<DateTime> _starts(ScorePeriod period, DateTime now) {
    final local = now.toLocal();
    return switch (period) {
      ScorePeriod.day => List.generate(
          24,
          (i) => DateTime(
              local.year, local.month, local.day, local.hour - 23 + i)),
      ScorePeriod.week => List.generate(7, (i) {
          final d = DateTime(local.year, local.month, local.day - 6 + i);
          return d;
        }),
      ScorePeriod.month => List.generate(30, (i) {
          final d = DateTime(local.year, local.month, local.day - 29 + i);
          return d;
        }),
      ScorePeriod.year =>
        List.generate(12, (i) => DateTime(local.year, local.month - 11 + i)),
    };
  }

  static DateTime _bucket(ScorePeriod period, DateTime time) =>
      switch (period) {
        ScorePeriod.day => DateTime(time.year, time.month, time.day, time.hour),
        ScorePeriod.week ||
        ScorePeriod.month =>
          DateTime(time.year, time.month, time.day),
        ScorePeriod.year => DateTime(time.year, time.month),
      };
}
