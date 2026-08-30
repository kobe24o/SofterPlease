import 'package:flutter/material.dart';

import '../local/score_trends.dart';

class RoleScoreTrendChart extends StatelessWidget {
  const RoleScoreTrendChart({super.key, required this.series});
  final RoleScoreSeries series;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 132,
        width: double.infinity,
        child: CustomPaint(painter: _ScoreTrendPainter(series)),
      );
}

class _ScoreTrendPainter extends CustomPainter {
  const _ScoreTrendPainter(this.series);
  final RoleScoreSeries series;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 1;
    for (final fraction in [0.0, .5, 1.0]) {
      canvas.drawLine(Offset(0, size.height * fraction),
          Offset(size.width, size.height * fraction), grid);
    }
    final good = Paint()
      ..color = Colors.green.shade700
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    final bad = Paint()
      ..color = Colors.red.shade700
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    Offset? previous;
    for (var index = 0; index < series.points.length; index++) {
      final value = series.points[index].average;
      if (value == null) {
        previous = null;
        continue;
      }
      final point = Offset(
        series.points.length < 2
            ? size.width / 2
            : index * size.width / (series.points.length - 1),
        (100 - value) / 200 * size.height,
      );
      if (previous != null) {
        canvas.drawLine(previous, point, (value >= 0 ? good : bad));
      }
      previous = point;
    }
  }

  @override
  bool shouldRepaint(covariant _ScoreTrendPainter oldDelegate) =>
      oldDelegate.series != series;
}
