import 'package:flutter/material.dart';
import 'package:navix_app/utils/hud_colors.dart';

class ScanlineBackground extends StatefulWidget {
  const ScanlineBackground({super.key});

  @override
  State<ScanlineBackground> createState() => _ScanlineBackgroundState();
}

class _ScanlineBackgroundState extends State<ScanlineBackground> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _ScanlinePainter(animation: _controller),
        child: Container(),
      ),
    );
  }
}

class _ScanlinePainter extends CustomPainter {
  final Animation<double> animation;

  _ScanlinePainter({required this.animation}) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Draw solid dark background
    final bgPaint = Paint()..color = HudColors.bg;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    // 2. Draw subtle grid
    final gridPaint = Paint()
      ..color = HudColors.teal.withValues(alpha: 0.02)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;

    const double gridSize = 40.0;
    for (double x = 0; x < size.width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y < size.height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // 3. Draw moving scanline
    final double scanlineY = animation.value * size.height;
    final scanlinePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          HudColors.teal.withValues(alpha: 0.0),
          HudColors.teal.withValues(alpha: 0.04),
          HudColors.teal.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromLTWH(0, scanlineY - 40, size.width, 80));

    canvas.drawRect(Rect.fromLTWH(0, scanlineY - 40, size.width, 80), scanlinePaint);
    
    // 4. Subtle overlay line
    final linePaint = Paint()
      ..color = HudColors.teal.withValues(alpha: 0.08)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, scanlineY), Offset(size.width, scanlineY), linePaint);
  }

  @override
  bool shouldRepaint(covariant _ScanlinePainter oldDelegate) => false;
}
