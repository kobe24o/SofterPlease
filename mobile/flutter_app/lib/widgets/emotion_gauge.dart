import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../utils/theme.dart';

class EmotionGauge extends StatelessWidget {
  final double angerScore;
  final String emotionLevel;
  final double size;

  const EmotionGauge({
    super.key,
    required this.angerScore,
    required this.emotionLevel,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size * 0.6,
      child: CustomPaint(
        size: Size(size, size * 0.6),
        painter: _GaugePainter(
          angerScore: angerScore,
          emotionLevel: emotionLevel,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: size * 0.25),
              Text(
                '${(angerScore * 100).toInt()}',
                style: TextStyle(
                  fontSize: size * 0.2,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.getEmotionColor(emotionLevel),
                ),
              ),
              Text(
                '情绪指数',
                style: TextStyle(
                  fontSize: size * 0.08,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double angerScore;
  final String emotionLevel;

  _GaugePainter({
    required this.angerScore,
    required this.emotionLevel,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height);
    final radius = size.width / 2 - 20;

    // 绘制背景弧
    final bgPaint = Paint()
      ..color = Colors.grey[200]!
      ..style = PaintingStyle.stroke
      ..strokeWidth = 20
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      math.pi,
      math.pi,
      false,
      bgPaint,
    );

    // 绘制进度弧
    final progressPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          AppTheme.calmColor,
          AppTheme.mildColor,
          AppTheme.moderateColor,
          AppTheme.highColor,
          AppTheme.extremeColor,
        ],
        stops: const [0.0, 0.25, 0.5, 0.75, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 20
      ..strokeCap = StrokeCap.round;

    final sweepAngle = math.pi * angerScore;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      math.pi,
      sweepAngle,
      false,
      progressPaint,
    );

    // 绘制刻度标记
    final tickPaint = Paint()
      ..color = Colors.grey[400]!
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    for (int i = 0; i <= 10; i++) {
      final angle = math.pi + (math.pi * i / 10);
      final tickStart = Offset(
        center.dx + (radius - 30) * math.cos(angle),
        center.dy + (radius - 30) * math.sin(angle),
      );
      final tickEnd = Offset(
        center.dx + (radius - 10) * math.cos(angle),
        center.dy + (radius - 10) * math.sin(angle),
      );
      canvas.drawLine(tickStart, tickEnd, tickPaint);
    }

    // 绘制指针
    final needleAngle = math.pi + (math.pi * angerScore);
    final needlePaint = Paint()
      ..color = AppTheme.getEmotionColor(emotionLevel)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    final needleEnd = Offset(
      center.dx + (radius - 40) * math.cos(needleAngle),
      center.dy + (radius - 40) * math.sin(needleAngle),
    );
    canvas.drawLine(center, needleEnd, needlePaint);

    // 绘制中心圆
    final centerPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 15, centerPaint);

    final centerBorderPaint = Paint()
      ..color = AppTheme.getEmotionColor(emotionLevel)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, 15, centerBorderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
