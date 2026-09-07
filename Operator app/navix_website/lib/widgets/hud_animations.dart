import 'dart:async';
import 'package:flutter/material.dart';

class PulsingGlowIndicator extends StatefulWidget {
  final Color color;
  final double size;

  const PulsingGlowIndicator({
    super.key,
    required this.color,
    this.size = 8.0,
  });

  @override
  State<PulsingGlowIndicator> createState() => _PulsingGlowIndicatorState();
}

class _PulsingGlowIndicatorState extends State<PulsingGlowIndicator> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    
    _glowAnimation = Tween<double>(begin: 0.2, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _glowAnimation,
        builder: (context, child) {
          final double val = _glowAnimation.value;
          return Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: widget.color.withValues(alpha: val * 0.6),
                  blurRadius: widget.size * 1.5,
                  spreadRadius: widget.size * 0.4,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class RadarPingIndicator extends StatefulWidget {
  final Color color;
  final double size;

  const RadarPingIndicator({
    super.key,
    required this.color,
    this.size = 20.0,
  });

  @override
  State<RadarPingIndicator> createState() => _RadarPingIndicatorState();
}

class _RadarPingIndicatorState extends State<RadarPingIndicator> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
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
        size: Size(widget.size, widget.size),
        painter: _RadarPingPainter(
          animation: _controller,
          color: widget.color,
        ),
      ),
    );
  }
}

class _RadarPingPainter extends CustomPainter {
  final Animation<double> animation;
  final Color color;

  _RadarPingPainter({required this.animation, required this.color}) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    final double value = animation.value;
    final double maxRadius = size.width / 2;
    
    // Core dot
    final corePaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(maxRadius, maxRadius), 4.0, corePaint);

    // Expanding pulse ring
    final ringPaint = Paint()
      ..color = color.withValues(alpha: (1.0 - value) * 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    
    canvas.drawCircle(Offset(maxRadius, maxRadius), value * maxRadius, ringPaint);
  }

  @override
  bool shouldRepaint(covariant _RadarPingPainter oldDelegate) => false;
}

class GlitchWrapper extends StatefulWidget {
  final Widget child;
  final dynamic value;

  const GlitchWrapper({super.key, required this.child, required this.value});

  @override
  State<GlitchWrapper> createState() => _GlitchWrapperState();
}

class _GlitchWrapperState extends State<GlitchWrapper> {
  double _opacity = 1.0;
  int _glitchFrame = 0;
  Timer? _timer;

  @override
  void didUpdateWidget(GlitchWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      _triggerGlitch();
    }
  }

  void _triggerGlitch() {
    _timer?.cancel();
    _glitchFrame = 0;
    
    final jitters = [0.15, 0.9, 0.1, 1.0];
    
    _timer = Timer.periodic(const Duration(milliseconds: 35), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _opacity = jitters[_glitchFrame];
        _glitchFrame++;
        if (_glitchFrame >= jitters.length) {
          _opacity = 1.0;
          timer.cancel();
        }
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: _opacity,
      child: widget.child,
    );
  }
}

class OdometerText extends StatelessWidget {
  final num value;
  final int decimals;
  final TextStyle style;

  const OdometerText({
    super.key,
    required this.value,
    this.decimals = 0,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: value.toDouble()),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      builder: (context, val, child) {
        return Text(
          val.toStringAsFixed(decimals),
          style: style.copyWith(fontFamily: 'monospace'),
        );
      },
    );
  }
}
