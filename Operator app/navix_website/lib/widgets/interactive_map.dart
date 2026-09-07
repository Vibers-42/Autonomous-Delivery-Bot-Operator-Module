import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:navix_app/providers/robot_state_provider.dart';

class InteractiveMap extends StatefulWidget {
  final bool forceEmpty;
  const InteractiveMap({super.key, this.forceEmpty = false});

  @override
  State<InteractiveMap> createState() => _InteractiveMapState();
}

class _InteractiveMapState extends State<InteractiveMap> {
  ui.Image? _decodedImage;
  List<int>? _lastBytes;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = Provider.of<RobotStateProvider>(context);
    if (!widget.forceEmpty && provider.mapImageBytes != null && provider.mapImageBytes != _lastBytes) {
      _lastBytes = provider.mapImageBytes;
      _decodeImage(provider.mapImageBytes!);
    } else if (widget.forceEmpty || provider.mapImageBytes == null) {
      _decodedImage = null;
      _lastBytes = null;
    }
  }

  Future<void> _decodeImage(List<int> bytes) async {
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
    final bool showMap = !widget.forceEmpty && provider.mapLoaded;

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
                color: Colors.cyan.withValues(alpha: 0.03),
                blurRadius: 20,
                spreadRadius: 2,
              )
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              children: [
                // Paint occupation grid and routes
                CustomPaint(
                  size: Size(constraints.maxWidth, constraints.maxHeight),
                  painter: MapPainter(
                    mapImage: showMap ? _decodedImage : null,
                    checkpoints: showMap ? provider.checkpoints : const {},
                    connections: showMap ? provider.connections : const [],
                    calculatedPath: showMap ? provider.calculatedPath : const [],
                    calculatedCoordinates: showMap ? provider.calculatedCoordinates : const [],
                    source: showMap ? provider.sourceCheckpoint : "",
                    dest: showMap ? provider.destinationCheckpoint : "",
                    robotX: showMap ? provider.robotX : 100.0,
                    robotY: showMap ? provider.robotY : 100.0,
                    robotHeading: showMap ? provider.robotHeading : 0.0,
                    robotStatus: showMap ? provider.robotStatus : "IDLE",
                    robotMode: showMap ? provider.robotMode : "auto",
                  ),
                ),
                
                // Tech grid indicator
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFF00FFCC).withValues(alpha: 0.3), width: 1),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: showMap ? const Color(0xFF00FFCC) : Colors.amber,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: showMap ? const Color(0xFF00FFCC) : Colors.amber,
                                blurRadius: 4,
                              )
                            ]
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          showMap 
                            ? "MAP: ${provider.mapFileName ?? 'ONLINE_OCCUPANCY_GRID'}" 
                            : "NO MAP UPLOADED - STANDBY",
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: showMap ? const Color(0xFF00FFCC) : Colors.amber,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Radar sweep overlay if no map is loaded
                if (!showMap)
                  const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.grid_4x4_rounded,
                          size: 64,
                          color: Color(0xFF1F2E45),
                        ),
                        SizedBox(height: 16),
                        Text(
                          "NAVIX AMR MONITORING SYSTEM",
                          style: TextStyle(
                            color: Color(0xFF4F688B),
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2,
                            fontSize: 14,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          "Upload map to initialize navigation graph",
                          style: TextStyle(
                            color: Color(0xFF2E3F57),
                            fontSize: 12,
                          ),
                        ),
                      ],
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

class MapPainter extends CustomPainter {
  final ui.Image? mapImage;
  final Map<String, dynamic> checkpoints;
  final List<dynamic> connections;
  final List<String> calculatedPath;
  final List<List<double>> calculatedCoordinates;
  final String source;
  final String dest;
  final double robotX;
  final double robotY;
  final double robotHeading;
  final String robotStatus;
  final String robotMode;

  MapPainter({
    required this.mapImage,
    required this.checkpoints,
    required this.connections,
    required this.calculatedPath,
    required this.calculatedCoordinates,
    required this.source,
    required this.dest,
    required this.robotX,
    required this.robotY,
    required this.robotHeading,
    required this.robotStatus,
    required this.robotMode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Draw occupancy grid map image (or background grid)
    final double imgW = mapImage != null ? mapImage!.width.toDouble() : 800.0;
    final double imgH = mapImage != null ? mapImage!.height.toDouble() : 600.0;
    final double scaleX = size.width / imgW;
    final double scaleY = size.height / imgH;

    if (mapImage != null) {
      canvas.drawImageRect(
        mapImage!,
        Rect.fromLTWH(0, 0, mapImage!.width.toDouble(), mapImage!.height.toDouble()),
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..filterQuality = ui.FilterQuality.high,
      );
    } else {
      // Draw industrial-looking scan lines and grid
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
    }

    // If no checkpoints, exit
    if (checkpoints.isEmpty) return;

    // 2. Draw connections (Corridors)
    final connectionPaint = Paint()
      ..color = const Color(0xFF1A334B).withValues(alpha: 0.6)
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;

    for (var conn in connections) {
      final String from = conn["from"];
      final String to = conn["to"];
      
      if (checkpoints.containsKey(from) && checkpoints.containsKey(to)) {
        final double x1 = checkpoints[from]["x"] * scaleX;
        final double y1 = checkpoints[from]["y"] * scaleY;
        final double x2 = checkpoints[to]["x"] * scaleX;
        final double y2 = checkpoints[to]["y"] * scaleY;
        canvas.drawLine(Offset(x1, y1), Offset(x2, y2), connectionPaint);
      }
    }

    // 3. Draw calculated path (glowing neon cyan line)
    if (calculatedCoordinates.length >= 2) {
      final pathPaint = Paint()
        ..color = const Color(0xFF00FFCC)
        ..strokeWidth = 5.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      final glowPaint = Paint()
        ..color = const Color(0xFF00FFCC).withValues(alpha: 0.3)
        ..strokeWidth = 12.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      final path = Path();
      path.moveTo(calculatedCoordinates[0][0] * scaleX, calculatedCoordinates[0][1] * scaleY);
      for (int i = 1; i < calculatedCoordinates.length; i++) {
        path.lineTo(calculatedCoordinates[i][0] * scaleX, calculatedCoordinates[i][1] * scaleY);
      }

      canvas.drawPath(path, glowPaint);
      canvas.drawPath(path, pathPaint);
    }

    // 4. Draw Waypoint Checkpoints
    checkpoints.forEach((label, coords) {
      final double cx = coords["x"] * scaleX;
      final double cy = coords["y"] * scaleY;

      // Decide color
      Color nodeColor = const Color(0xFF00E5FF); // default blue-cyan
      bool isTarget = false;

      if (label == source) {
        nodeColor = const Color(0xFFFF9100); // Amber source
        isTarget = true;
      } else if (label == dest) {
        nodeColor = const Color(0xFF00FF66); // Green destination
        isTarget = true;
      } else if (calculatedPath.contains(label)) {
        nodeColor = const Color(0xFF00FFCC); // Cyan path node
      }

      // Outer glow ring
      final glowPaint = Paint()
        ..color = nodeColor.withValues(alpha: 0.2)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx, cy), isTarget ? 24 : 16, glowPaint);

      // Border ring
      final ringPaint = Paint()
        ..color = nodeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawCircle(Offset(cx, cy), isTarget ? 16 : 10, ringPaint);

      // Center point
      final centerPaint = Paint()
        ..color = nodeColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx, cy), 4.0, centerPaint);

      // Draw letter label text (Futuristic Monospace)
      final textSpan = TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.white,
          fontSize: isTarget ? 14 : 10,
          fontFamily: 'monospace',
          fontWeight: FontWeight.bold,
          shadows: [
            Shadow(
              color: nodeColor,
              blurRadius: 6,
            )
          ]
        ),
      );
      
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(cx - textPainter.width / 2, cy - textPainter.height - 10));
    });

    // 5. Draw Robot Avatar (if map loaded)
    final double rx = robotX * scaleX;
    final double ry = robotY * scaleY;

    canvas.save();
    canvas.translate(rx, ry);
    canvas.rotate(robotHeading);

    // Draw robot body (Neon glowing circular disc)
    final botGlow = Paint()
      ..color = const Color(0xFFCC00FF).withValues(alpha: 0.3)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset.zero, 18, botGlow);

    final botBody = Paint()
      ..color = const Color(0xFF1E0E35)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset.zero, 12, botBody);

    final botRing = Paint()
      ..color = const Color(0xFFCC00FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    canvas.drawCircle(Offset.zero, 12, botRing);

    // Draw heading arrow / pointer
    final arrowPaint = Paint()
      ..color = const Color(0xFF00FFCC)
      ..style = PaintingStyle.fill;
    final path = Path();
    path.moveTo(14, 0);       // Nose
    path.lineTo(6, -6);      // Left wing
    path.lineTo(6, 6);       // Right wing
    path.close();
    canvas.drawPath(path, arrowPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant MapPainter oldDelegate) {
    return oldDelegate.robotX != robotX ||
        oldDelegate.robotY != robotY ||
        oldDelegate.robotHeading != robotHeading ||
        oldDelegate.robotStatus != robotStatus ||
        oldDelegate.robotMode != robotMode ||
        oldDelegate.calculatedPath != calculatedPath ||
        oldDelegate.mapImage != mapImage ||
        oldDelegate.source != source ||
        oldDelegate.dest != dest;
  }
}
