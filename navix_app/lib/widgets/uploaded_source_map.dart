import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:navix_app/providers/robot_state_provider.dart';

class UploadedSourceMap extends StatefulWidget {
  const UploadedSourceMap({super.key});

  @override
  State<UploadedSourceMap> createState() => _UploadedSourceMapState();
}

class _UploadedSourceMapState extends State<UploadedSourceMap> {
  ui.Image? _decodedImage;
  List<int>? _lastBytes;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = Provider.of<RobotStateProvider>(context);
    if (provider.mapImageBytes != null && provider.mapImageBytes!.isNotEmpty && provider.mapImageBytes != _lastBytes) {
      _lastBytes = provider.mapImageBytes;
      _decodeImage(provider.mapImageBytes!);
    } else if (provider.mapImageBytes == null || provider.mapImageBytes!.isEmpty) {
      _decodedImage = null;
      _lastBytes = null;
    }
  }

  Future<void> _decodeImage(List<int> bytes) async {
    if (bytes.isEmpty) {
      if (mounted) {
        setState(() {
          _decodedImage = null;
        });
      }
      return;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(Uint8List.fromList(bytes), (ui.Image img) {
      completer.complete(img);
    });
    final decoded = await completer.future;
    if (mounted) {
      setState(() {
        _decodedImage = decoded;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RobotStateProvider>(context);
    final bool showMap = provider.mapLoaded;

    return LayoutBuilder(
      builder: (context, constraints) {
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0F141C),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: const Color(0xFF1F2E45),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.orange.withValues(alpha: 0.02),
                blurRadius: 20,
                spreadRadius: 2,
              )
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              children: [
                // Paint occupancy grid and checkpoints
                CustomPaint(
                  size: Size(constraints.maxWidth, constraints.maxHeight),
                  painter: UploadedSourceMapPainter(
                    mapImage: showMap ? _decodedImage : null,
                    checkpoints: showMap ? provider.checkpoints : const {},
                    source: showMap ? provider.sourceCheckpoint : "",
                    dest: showMap ? provider.destinationCheckpoint : "",
                  ),
                ),
                
                // Title Banner
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.orange.withValues(alpha: 0.3), width: 1),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: Colors.orange,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          "LAYER 1: SOURCE OCCUPANCY GRID (Reference)",
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.orange,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class UploadedSourceMapPainter extends CustomPainter {
  final ui.Image? mapImage;
  final Map<String, dynamic> checkpoints;
  final String source;
  final String dest;

  UploadedSourceMapPainter({
    required this.mapImage,
    required this.checkpoints,
    required this.source,
    required this.dest,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (mapImage == null) {
      // Draw grid when map is not loaded or for custom map
      final gridPaint = Paint()
        ..color = const Color(0xFF151D2A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      
      const double step = 40.0;
      for (double i = 0; i < size.width; i += step) {
        canvas.drawLine(Offset(i, 0), Offset(i, size.height), gridPaint);
      }
      for (double i = 0; i < size.height; i += step) {
        canvas.drawLine(Offset(0, i), Offset(size.width, i), gridPaint);
      }
      if (checkpoints.isEmpty) {
        return;
      }
    }

    final double scaleX = mapImage != null ? size.width / mapImage!.width.toDouble() : size.width / 1000.0;
    final double scaleY = mapImage != null ? size.height / mapImage!.height.toDouble() : size.height / 1000.0;

    if (mapImage != null) {
      // Draw raw source map image
      canvas.drawImageRect(
        mapImage!,
        Rect.fromLTWH(0, 0, mapImage!.width.toDouble(), mapImage!.height.toDouble()),
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..filterQuality = ui.FilterQuality.high,
      );
    }

    // Overlay waypoints in pixel coordinates
    checkpoints.forEach((label, coords) {
      final double cx = coords["x"] * scaleX;
      final double cy = coords["y"] * scaleY;

      Color nodeColor = const Color(0xFFE5A823); // Yellowish for checkpoints
      bool isTarget = (label == source || label == dest);

      if (label == source) {
        nodeColor = const Color(0xFFFF9100);
      } else if (label == dest) {
        nodeColor = const Color(0xFF00FF66);
      }

      // Outer ring
      final outerPaint = Paint()
        ..color = nodeColor.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx, cy), isTarget ? 20 : 12, outerPaint);

      // Border ring
      final borderPaint = Paint()
        ..color = nodeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(Offset(cx, cy), isTarget ? 12 : 8, borderPaint);

      // Center dot
      final centerPaint = Paint()
        ..color = nodeColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx, cy), 3.0, centerPaint);

      // Text label
      final textSpan = TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontFamily: 'monospace',
          fontWeight: FontWeight.bold,
        ),
      );
      
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(cx - textPainter.width / 2, cy - textPainter.height - 8));
    });
  }

  @override
  bool shouldRepaint(covariant UploadedSourceMapPainter oldDelegate) {
    return oldDelegate.mapImage != mapImage ||
        oldDelegate.checkpoints != checkpoints ||
        oldDelegate.source != source ||
        oldDelegate.dest != dest;
  }
}
