import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:navix_app/utils/hud_colors.dart';

class PolarRadarWidget extends StatefulWidget {
  final double distance; // distance in cm

  const PolarRadarWidget({
    super.key,
    required this.distance,
  });

  @override
  State<PolarRadarWidget> createState() => _PolarRadarWidgetState();
}

class _PolarRadarWidgetState extends State<PolarRadarWidget> with SingleTickerProviderStateMixin {
  late AnimationController _sweepController;

  @override
  void initState() {
    super.initState();
    _sweepController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _sweepController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        width: 200,
        height: 120,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: HudColors.cardBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: HudColors.border),
        ),
        child: CustomPaint(
          size: const Size(200, 110),
          painter: RadarPainter(
            sweepAnimation: _sweepController,
            distance: widget.distance,
          ),
        ),
      ),
    );
  }
}

class RadarPainter extends CustomPainter {
  final Animation<double> sweepAnimation;
  final double distance;

  RadarPainter({
    required this.sweepAnimation,
    required this.distance,
  }) : super(repaint: sweepAnimation);

  @override
  void paint(Canvas canvas, Size size) {
    final double cx = size.width / 2;
    final double cy = size.height - 5; // origin at bottom center
    final double radius = size.height - 10;

    // Draw background grid arcs
    final gridPaint = Paint()
      ..color = HudColors.teal.withValues(alpha: 0.05)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    // Concentric rings (25%, 50%, 75%, 100% range)
    for (double i = 0.25; i <= 1.0; i += 0.25) {
      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: radius * i),
        math.pi,
        math.pi,
        false,
        gridPaint,
      );
    }

    // Radial grid lines (30, 60, 90, 120, 150 degrees)
    for (int deg = 30; deg <= 150; deg += 30) {
      final double rad = deg * math.pi / 180;
      // Note the negative Y coordinate for drawing upward from origin
      final double x = cx + radius * math.cos(-rad);
      final double y = cy + radius * math.sin(-rad);
      canvas.drawLine(Offset(cx, cy), Offset(x, y), gridPaint);
    }

    // Draw sweep line (sweeping left to right, back and forth)
    final double sweepVal = sweepAnimation.value;
    // Map 0..1 to -math.pi to 0 (which is 180 to 0 degrees in standard cartesian drawing)
    final double sweepAngle = -math.pi + (sweepVal * math.pi);
    final double sx = cx + radius * math.cos(sweepAngle);
    final double sy = cy + radius * math.sin(sweepAngle);

    final sweepPaint = Paint()
      ..color = HudColors.teal.withValues(alpha: 0.25)
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(cx, cy), Offset(sx, sy), sweepPaint);

    // Draw obstacle if within detection range (max 150cm represented by visual radius)
    final double maxRadarRange = 150.0;
    if (distance > 0 && distance < maxRadarRange) {
      // Find relative scale
      final double relativeDist = distance / maxRadarRange;
      final double obstacleRadius = radius * relativeDist;
      
      // Draw obstacle point as a small glowing circle directly ahead (sonar sensor angle is central)
      const double targetAngle = -math.pi / 2; // -90 deg (straight up)
      final double ox = cx + obstacleRadius * math.cos(targetAngle);
      final double oy = cy + obstacleRadius * math.sin(targetAngle);

      final obstaclePaint = Paint()
        ..color = HudColors.magenta
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(ox, oy), 4.0, obstaclePaint);

      // Glow effect
      final glowPaint = Paint()
        ..color = HudColors.magenta.withValues(alpha: 0.35)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(ox, oy), 9.0, glowPaint);
    }
  }

  @override
  bool shouldRepaint(covariant RadarPainter oldDelegate) {
    return oldDelegate.distance != distance;
  }
}
