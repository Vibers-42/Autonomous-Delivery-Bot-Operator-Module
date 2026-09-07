import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:navix_app/providers/robot_state_provider.dart';
import 'package:navix_app/utils/hud_colors.dart';

class GeneratedNavigationMap extends StatefulWidget {
  final bool isFullscreen;
  final bool isMiniMap;
  
  const GeneratedNavigationMap({
    super.key,
    this.isFullscreen = false,
    this.isMiniMap = false,
  });

  @override
  State<GeneratedNavigationMap> createState() => _GeneratedNavigationMapState();
}

class _GeneratedNavigationMapState extends State<GeneratedNavigationMap> {
  final TransformationController _transformationController = TransformationController();

  void _zoomIn() {
    setState(() {
      _transformationController.value =
          _transformationController.value.clone()..scaleByDouble(1.2, 1.2, 1.0, 1.0);
    });
  }

  void _zoomOut() {
    setState(() {
      _transformationController.value =
          _transformationController.value.clone()..scaleByDouble(0.8, 0.8, 1.0, 1.0);
    });
  }

  void _zoomReset() {
    setState(() {
      _transformationController.value = Matrix4.identity();
    });
  }

  void _showFullscreenMap(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return Dialog.fullscreen(
          backgroundColor: const Color(0xFF0C1017),
          child: Scaffold(
            backgroundColor: const Color(0xFF0C1017),
            appBar: AppBar(
              title: const Text(
                "MISSION CONTROL MAP (METRIC SPECS)",
                style: TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              backgroundColor: const Color(0xFF0F141C),
              leading: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            body: const SafeArea(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: GeneratedNavigationMap(isFullscreen: true),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RobotStateProvider>(context);
    final bool showMap = provider.mapLoaded;

    return LayoutBuilder(
      builder: (context, constraints) {
        return Container(
          decoration: BoxDecoration(
            color: HudColors.cardBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: HudColors.teal.withValues(alpha: widget.isFullscreen ? 0.4 : 0.25),
              width: widget.isFullscreen ? 2.0 : 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: HudColors.teal.withValues(alpha: 0.02),
                blurRadius: 20,
                spreadRadius: 1,
              )
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              children: [
                // Zoomable & Pannable Custom Painter Canvas
                InteractiveViewer(
                  transformationController: _transformationController,
                  boundaryMargin: const EdgeInsets.all(500),
                  minScale: 0.1,
                  maxScale: 6.0,
                  child: CustomPaint(
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                    painter: GeneratedMapPainter(
                      checkpoints: showMap ? provider.metricCheckpoints : const {},
                      connections: showMap ? provider.connections : const [],
                      calculatedPath: showMap ? provider.calculatedPath : const [],
                      calculatedCoordinates: showMap ? provider.calculatedCoordinates : const [],
                      source: showMap ? provider.sourceCheckpoint : "",
                      dest: showMap ? provider.destinationCheckpoint : "",
                      robotX: showMap ? provider.robotX : 0.0,
                      robotY: showMap ? provider.robotY : 0.0,
                      robotHeading: showMap ? provider.robotHeading : 0.0,
                      robotStatus: showMap ? provider.robotStatus : "IDLE",
                      robotMode: showMap ? provider.robotMode : "auto",
                      isMiniMap: widget.isMiniMap,
                    ),
                  ),
                ),

                // Layer Banner indicator
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: HudColors.bg.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: HudColors.teal.withValues(alpha: 0.4), width: 1),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: Color(0xFF00FFCC),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          widget.isMiniMap
                              ? "LAYER 1: METRIC GRAPH (MINI)"
                              : "LAYER 1: GENERATED METRIC GRAPH (1m Grid)",
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF00FFCC),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Floating Zoom / fullscreen Controls Overlay
                Positioned(
                  bottom: 12,
                  right: 12,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF1F2E45), width: 1),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.zoom_in, color: Colors.white, size: 18),
                          onPressed: _zoomIn,
                          tooltip: 'Zoom In',
                        ),
                        const VerticalDivider(width: 1, color: Color(0xFF1F2E45)),
                        IconButton(
                          icon: const Icon(Icons.zoom_out, color: Colors.white, size: 18),
                          onPressed: _zoomOut,
                          tooltip: 'Zoom Out',
                        ),
                        const VerticalDivider(width: 1, color: Color(0xFF1F2E45)),
                        IconButton(
                          icon: const Icon(Icons.center_focus_strong, color: Colors.white, size: 18),
                          onPressed: _zoomReset,
                          tooltip: 'Reset View',
                        ),
                        if (!widget.isFullscreen && !widget.isMiniMap) ...[
                          const VerticalDivider(width: 1, color: Color(0xFF1F2E45)),
                          IconButton(
                            icon: const Icon(Icons.fullscreen, color: Color(0xFF00FFCC), size: 18),
                            onPressed: () => _showFullscreenMap(context),
                            tooltip: 'Fullscreen Map',
                          ),
                        ]
                      ],
                    ),
                  ),
                ),

                // Bounding stats badge overlay
                if (showMap && !widget.isMiniMap)
                  Positioned(
                    bottom: 12,
                    left: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFF1F2E45), width: 1),
                      ),
                      child: Text(
                        "Map Scale: Auto metric  •  Status: ${provider.robotStatus}\nPosition: (${provider.robotX.toStringAsFixed(2)}m, ${provider.robotY.toStringAsFixed(2)}m)",
                        style: const TextStyle(
                          color: Color(0xFF8BA2C0),
                          fontFamily: 'monospace',
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
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

class GeneratedMapPainter extends CustomPainter {
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
  final bool isMiniMap;

  GeneratedMapPainter({
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
    required this.isMiniMap,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. If checkpoints empty, just draw background grids
    if (checkpoints.isEmpty) {
      _drawBackgroundGrid(canvas, size, 40.0, 0.0, 0.0);
      return;
    }

    // 2. Compute dynamic bounds in meters to scale nodes perfectly
    double minX = double.infinity;
    double maxX = -double.infinity;
    double minY = double.infinity;
    double maxY = -double.infinity;

    checkpoints.forEach((_, coords) {
      final double x = (coords["x"] as num).toDouble();
      final double y = (coords["y"] as num).toDouble();
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    });

    double graphW = maxX - minX;
    double graphH = maxY - minY;

    // Bounding box center
    double cx = (minX + maxX) / 2;
    double cy = (minY + maxY) / 2;

    // Padding inside canvas
    final double padding = isMiniMap ? 24.0 : 48.0;
    final double availW = size.width - 2 * padding;
    final double availH = size.height - 2 * padding;

    // Calculate dynamic scaling factor (pixels per meter)
    double scale = 40.0; // fallback
    if (graphW > 0.01 && graphH > 0.01) {
      double scaleX = availW / graphW;
      double scaleY = availH / graphH;
      scale = math.min(scaleX, scaleY);
    }

    // Calculate translations to center the graph in the canvas
    double tx = size.width / 2 - cx * scale;
    double ty = size.height / 2 - cy * scale;

    // 3. Draw Background Metric Grid (lines drawn at every 1.0m block)
    _drawBackgroundGrid(canvas, size, scale, tx, ty);

    // 4. Draw Corridors (connections between checkpoints)
    final connectionPaint = Paint()
      ..color = const Color(0xFF1E2E43)
      ..strokeWidth = isMiniMap ? 3.0 : 5.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final connectionGlowPaint = Paint()
      ..color = const Color(0xFF00FFCC).withValues(alpha: 0.03)
      ..strokeWidth = isMiniMap ? 8.0 : 12.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    for (var conn in connections) {
      final String from = conn["from"];
      final String to = conn["to"];

      if (checkpoints.containsKey(from) && checkpoints.containsKey(to)) {
        final List<dynamic>? path = conn["path"];
        if (path != null && path.length >= 2) {
          final p = Path();
          p.moveTo((path[0][0] as num).toDouble() * scale + tx, (path[0][1] as num).toDouble() * scale + ty);
          for (int k = 1; k < path.length; k++) {
            p.lineTo((path[k][0] as num).toDouble() * scale + tx, (path[k][1] as num).toDouble() * scale + ty);
          }
          canvas.drawPath(p, connectionGlowPaint);
          canvas.drawPath(p, connectionPaint);
        } else {
          final double x1 = checkpoints[from]["x"] * scale + tx;
          final double y1 = checkpoints[from]["y"] * scale + ty;
          final double x2 = checkpoints[to]["x"] * scale + tx;
          final double y2 = checkpoints[to]["y"] * scale + ty;
          
          canvas.drawLine(Offset(x1, y1), Offset(x2, y2), connectionGlowPaint);
          canvas.drawLine(Offset(x1, y1), Offset(x2, y2), connectionPaint);
        }
      }
    }

    // 5. Draw neon route path with progress highlight
    if (calculatedCoordinates.length >= 2) {
      // Total path length in coordinate units
      double totalLen = 0.0;
      final List<double> segLengths = [];
      for (int i = 1; i < calculatedCoordinates.length; i++) {
        final dx = calculatedCoordinates[i][0] - calculatedCoordinates[i - 1][0];
        final dy = calculatedCoordinates[i][1] - calculatedCoordinates[i - 1][1];
        final d = math.sqrt(dx * dx + dy * dy);
        segLengths.add(d);
        totalLen += d;
      }

      // Use robotX/Y to find nearest point on path for live progress
      // (Simple approach: draw completed portion up to robot's nearest coord)
      final double robotMapX = robotX * scale + tx;
      final double robotMapY = robotY * scale + ty;

      // --- Dim (completed) path ---
      final completedPaint = Paint()
        ..color = const Color(0xFF00FFCC).withValues(alpha: 0.35)
        ..strokeWidth = isMiniMap ? 3.0 : 5.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      // --- Bright (remaining/active) path ---
      final activePaint = Paint()
        ..color = const Color(0xFF00FFCC)
        ..strokeWidth = isMiniMap ? 4.0 : 6.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      final glowPaint = Paint()
        ..color = const Color(0xFF00FFCC).withValues(alpha: 0.25)
        ..strokeWidth = isMiniMap ? 10.0 : 16.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      // Find which segment the robot is nearest to
      double cumulativeLen = 0.0;
      double robotPathDist = 0.0;
      double minDist = double.infinity;
      for (int i = 0; i < segLengths.length; i++) {
        final ax = calculatedCoordinates[i][0] * scale + tx;
        final ay = calculatedCoordinates[i][1] * scale + ty;
        final bx = calculatedCoordinates[i + 1][0] * scale + tx;
        final by = calculatedCoordinates[i + 1][1] * scale + ty;
        // Project robot onto segment
        final segLen = segLengths[i] * scale;
        double t = 0.0;
        if (segLen > 0.01) {
          t = ((robotMapX - ax) * (bx - ax) + (robotMapY - ay) * (by - ay)) / (segLen * segLen);
          t = t.clamp(0.0, 1.0);
        }
        final px = ax + t * (bx - ax);
        final py = ay + t * (by - ay);
        final d = math.sqrt((robotMapX - px) * (robotMapX - px) + (robotMapY - py) * (robotMapY - py));
        if (d < minDist) {
          minDist = d;
          robotPathDist = (cumulativeLen + t * segLengths[i]) / (totalLen > 0.01 ? totalLen : 1.0);
        }
        cumulativeLen += segLengths[i];
      }

      // Draw the full glow first
      final fullPath = Path();
      fullPath.moveTo(calculatedCoordinates[0][0] * scale + tx, calculatedCoordinates[0][1] * scale + ty);
      for (int i = 1; i < calculatedCoordinates.length; i++) {
        fullPath.lineTo(calculatedCoordinates[i][0] * scale + tx, calculatedCoordinates[i][1] * scale + ty);
      }
      canvas.drawPath(fullPath, glowPaint);

      // Draw dim completed portion
      if (robotPathDist > 0.01 && robotStatus == "MOVING") {
        final cPath = Path();
        double cum = 0.0;
        cPath.moveTo(calculatedCoordinates[0][0] * scale + tx, calculatedCoordinates[0][1] * scale + ty);
        for (int i = 0; i < segLengths.length; i++) {
          final ratio = (cum + segLengths[i]) / (totalLen > 0.01 ? totalLen : 1.0);
          final nx = calculatedCoordinates[i + 1][0] * scale + tx;
          final ny = calculatedCoordinates[i + 1][1] * scale + ty;
          if (ratio <= robotPathDist) {
            cPath.lineTo(nx, ny);
          } else {
            // Partial segment
            final frac = (robotPathDist - cum / (totalLen > 0.01 ? totalLen : 1.0)) / (segLengths[i] / (totalLen > 0.01 ? totalLen : 1.0));
            final px = calculatedCoordinates[i][0] * scale + tx + frac * (nx - (calculatedCoordinates[i][0] * scale + tx));
            final py = calculatedCoordinates[i][1] * scale + ty + frac * (ny - (calculatedCoordinates[i][1] * scale + ty));
            cPath.lineTo(px, py);
            break;
          }
          cum += segLengths[i];
        }
        canvas.drawPath(cPath, completedPaint);
      }

      // Draw bright remaining/active path
      canvas.drawPath(fullPath, robotStatus == "MOVING" ? activePaint : activePaint);
    }

    // 6. Draw Checkpoint nodes
    checkpoints.forEach((label, coords) {
      final double cxM = coords["x"] * scale + tx;
      final double cyM = coords["y"] * scale + ty;

      Color nodeColor = const Color(0xFF00E5FF); // standard node
      bool isTarget = false;

      if (label == source) {
        nodeColor = const Color(0xFFFF9100);
        isTarget = true;
      } else if (label == dest) {
        nodeColor = const Color(0xFF00FF66);
        isTarget = true;
      } else if (calculatedPath.contains(label)) {
        nodeColor = const Color(0xFF00FFCC);
      }

      // Glow circle
      final glowPaint = Paint()
        ..color = nodeColor.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cxM, cyM), isMiniMap ? 12 : (isTarget ? 24 : 16), glowPaint);

      // Border ring
      final borderPaint = Paint()
        ..color = nodeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = isMiniMap ? 1.5 : 2.5;
      canvas.drawCircle(Offset(cxM, cyM), isMiniMap ? 8 : (isTarget ? 15 : 10), borderPaint);

      // Core point
      final corePaint = Paint()
        ..color = nodeColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cxM, cyM), isMiniMap ? 2.5 : 4.0, corePaint);

      // Text label (hidden on mini map for clean look)
      if (!isMiniMap) {
        final textSpan = TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.white,
            fontSize: isTarget ? 12 : 9,
            fontFamily: 'monospace',
            fontWeight: FontWeight.bold,
            shadows: [Shadow(color: nodeColor, blurRadius: 4)],
          ),
        );
        final textPainter = TextPainter(
          text: textSpan,
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();
        textPainter.paint(canvas, Offset(cxM - textPainter.width / 2, cyM - textPainter.height - 8));
      }
    });

    // 7. Draw Robot Avatar (animated, on top of Layer 2 navigation map)
    final double rx = robotX * scale + tx;
    final double ry = robotY * scale + ty;

    canvas.save();
    canvas.translate(rx, ry);
    canvas.rotate(robotHeading);

    // Glowing circular avatar
    final botGlow = Paint()
      ..color = const Color(0xFFCC00FF).withValues(alpha: 0.25)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset.zero, isMiniMap ? 12 : 18, botGlow);

    final botBody = Paint()
      ..color = const Color(0xFF1D0D35)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset.zero, isMiniMap ? 8 : 12, botBody);

    final botRing = Paint()
      ..color = const Color(0xFFCC00FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = isMiniMap ? 1.5 : 2.5;
    canvas.drawCircle(Offset.zero, isMiniMap ? 8 : 12, botRing);

    // Robot heading nose
    final nosePaint = Paint()
      ..color = const Color(0xFF00FFCC)
      ..style = PaintingStyle.fill;
    final nosePath = Path();
    if (isMiniMap) {
      nosePath.moveTo(9, 0);
      nosePath.lineTo(4, -4);
      nosePath.lineTo(4, 4);
    } else {
      nosePath.moveTo(14, 0);
      nosePath.lineTo(6, -6);
      nosePath.lineTo(6, 6);
    }
    nosePath.close();
    canvas.drawPath(nosePath, nosePaint);

    canvas.restore();
  }

  void _drawBackgroundGrid(Canvas canvas, Size size, double scale, double tx, double ty) {
    final gridPaint = Paint()
      ..color = HudColors.gridLow
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;

    final axisPaint = Paint()
      ..color = HudColors.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Draw coordinate axis lines crossing the origin (tx, ty)
    canvas.drawLine(Offset(0, ty), Offset(size.width, ty), axisPaint);
    canvas.drawLine(Offset(tx, 0), Offset(tx, size.height), axisPaint);

    // Draw horizontal grid lines spaced by scale pixels (1.0 meter steps)
    double startX = tx % scale;
    for (double x = startX; x < size.width; x += scale) {
      if ((x - tx).abs() > 0.1) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
      }
    }

    // Draw vertical grid lines spaced by scale pixels (1.0 meter steps)
    double startY = ty % scale;
    for (double y = startY; y < size.height; y += scale) {
      if ((y - ty).abs() > 0.1) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant GeneratedMapPainter oldDelegate) {
    return oldDelegate.robotX != robotX ||
        oldDelegate.robotY != robotY ||
        oldDelegate.robotHeading != robotHeading ||
        oldDelegate.robotStatus != robotStatus ||
        oldDelegate.robotMode != robotMode ||
        oldDelegate.calculatedPath != calculatedPath ||
        oldDelegate.source != source ||
        oldDelegate.dest != dest ||
        oldDelegate.checkpoints != checkpoints ||
        oldDelegate.connections != connections;
  }
}
