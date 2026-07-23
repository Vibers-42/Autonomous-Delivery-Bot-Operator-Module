import 'package:flutter/material.dart';

class RollingSparkline extends StatefulWidget {
  final double value;
  final int maxPoints;
  final Color color;
  final double width;
  final double height;

  const RollingSparkline({
    super.key,
    required this.value,
    this.maxPoints = 100, // 10 seconds of 10Hz ticks
    required this.color,
    this.width = 100.0,
    this.height = 30.0,
  });

  @override
  State<RollingSparkline> createState() => _RollingSparklineState();
}

class _RollingSparklineState extends State<RollingSparkline> {
  final List<double> _history = [];

  @override
  void didUpdateWidget(covariant RollingSparkline oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Add value if different or list is empty
    if (widget.value != oldWidget.value || _history.isEmpty) {
      _history.add(widget.value);
      if (_history.length > widget.maxPoints) {
        _history.removeAt(0);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(widget.width, widget.height),
        painter: SparklinePainter(values: List.from(_history), color: widget.color),
      ),
    );
  }
}

class SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;

  SparklinePainter({required this.values, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    double minVal = values.reduce((a, b) => a < b ? a : b);
    double maxVal = values.reduce((a, b) => a > b ? a : b);
    double range = maxVal - minVal;

    final path = Path();
    final double dx = values.length > 1 ? size.width / (values.length - 1) : size.width;
    
    for (int i = 0; i < values.length; i++) {
      final double x = i * dx;
      final double normVal = range == 0.0 ? 0.5 : (values[i] - minVal) / range;
      // Invert Y axis for screen coordinate mapping
      final double y = size.height - (normVal * (size.height - 4)) - 2;
      
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant SparklinePainter oldDelegate) {
    // Check if lengths are different, or list content differs
    if (oldDelegate.values.length != values.length || oldDelegate.color != color) return true;
    for (int i = 0; i < values.length; i++) {
      if (oldDelegate.values[i] != values[i]) return true;
    }
    return false;
  }
}
