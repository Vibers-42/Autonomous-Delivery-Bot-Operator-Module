import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:provider/provider.dart';
import 'package:navix_app/providers/robot_state_provider.dart';
import 'package:navix_app/services/backend_service.dart';
import 'package:navix_app/utils/hud_colors.dart';

// dart:io is NOT available on web — use conditional import
import 'package:navix_app/utils/file_reader_stub.dart'
    if (dart.library.io) 'package:navix_app/utils/file_reader_io.dart';

enum ToolType { pan, select, addNode, linkNodes, drawPath, delete }

IconData _getIconData(String type) {
  switch (type.toLowerCase()) {
    case 'reception':
      return Icons.business_rounded;
    case 'kitchen':
      return Icons.restaurant_rounded;
    case 'warehouse':
      return Icons.warehouse_rounded;
    case 'bay':
      return Icons.local_shipping_rounded;
    case 'charging':
      return Icons.bolt_rounded;
    case 'general':
    default:
      return Icons.location_on_rounded;
  }
}

class MapDesignerScreen extends StatefulWidget {
  final VoidCallback onSelectForMission;
  const MapDesignerScreen({super.key, required this.onSelectForMission});

  @override
  State<MapDesignerScreen> createState() => _MapDesignerScreenState();
}

class _MapDesignerScreenState extends State<MapDesignerScreen> {
  // Map Designer Local Graph State
  final Map<String, Map<String, dynamic>> _checkpoints = {};
  final List<Map<String, dynamic>> _connections = [];

  ToolType _activeTool = ToolType.select;
  double _snapStep = 0.5; // 1.0m, 0.5m, 0.25m, 0.0m (no snap)
  
  String? _selectedNodeId;
  int? _selectedConnectionIndex;
  String? _linkStartNodeId;
  String? _draggingNodeId;
  int? _draggingControlPointIndex;
  Offset? _dragStartOffset;

  final TransformationController _transformationController = TransformationController();
  final GlobalKey _canvasKey = GlobalKey();
  final GlobalKey _innerCanvasKey = GlobalKey();

  String _mapName = "Factory Layout 1";
  bool _isAIBootstrapping = false;
  Offset? _hoverOffset;
  double? _alignX;
  double? _alignY;

  Uint8List? _uploadedImageBytes;
  double _overlayOpacity = 0.5;
  List<Offset>? _freehandDragPoints;
  // Draw-path tool state
  String? _drawPathStartNodeId;
  List<Offset> _drawPathPoints = [];
  Offset? _drawPathCursor;

  @override
  void initState() {
    super.initState();
    // Load custom maps list on load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<RobotStateProvider>(context, listen: false).loadCustomMaps();
    });
  }

  // Snapping logic
  double _snap(double value, double snapStep) {
    if (snapStep <= 0.0) return value;
    return (value / snapStep).round() * snapStep;
  }

  // Convert Screen pixel coordinate to virtual Canvas coordinates
  Offset _screenToCanvas(Offset screenOffset) {
    final RenderBox? renderBox = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return screenOffset;
    final Offset localOffset = renderBox.globalToLocal(screenOffset);
    final Matrix4 inverse = Matrix4.copy(_transformationController.value)..invert();
    return MatrixUtils.transformPoint(inverse, localOffset);
  }

  // Auto label generator
  String _getNextNodeLabel() {
    const letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    for (int i = 0; i < letters.length; i++) {
      final label = letters[i];
      if (!_checkpoints.containsKey(label)) return label;
    }
    int index = 1;
    while (true) {
      final label = "CP$index";
      if (!_checkpoints.containsKey(label)) return label;
      index++;
    }
  }

  // Segment distance checking for link selections
  double _distanceToSegment(Offset p, Offset a, Offset b) {
    final double l2 = (a - b).distanceSquared;
    if (l2 == 0) return (p - a).distance;
    final double t = math.max(0, math.min(1, ((p.dx - a.dx) * (b.dx - a.dx) + (p.dy - a.dy) * (b.dy - a.dy)) / l2));
    final Offset projection = a + (b - a) * t;
    return (p - projection).distance;
  }

  // Canvas Tap Handlers
  void _handleCanvasTap(TapUpDetails details) {
    final canvasOffset = _screenToCanvas(details.globalPosition);
    final double xMeter = canvasOffset.dx / 100.0;
    final double yMeter = canvasOffset.dy / 100.0;

    if (_activeTool == ToolType.addNode) {
      final snapX = _snap(xMeter, _snapStep);
      final snapY = _snap(yMeter, _snapStep);

      final label = _getNextNodeLabel();
      setState(() {
        _checkpoints[label] = {
          "x": snapX,
          "y": snapY,
          "name": "Node $label",
          "color": "#00FFCC",
          "iconType": "general",
        };
        _selectedNodeId = label;
        _selectedConnectionIndex = null;
      });
    } else if (_activeTool == ToolType.select || _activeTool == ToolType.linkNodes || _activeTool == ToolType.delete) {
      // Find tapped node within 20 canvas pixels
      String? tappedNodeId;
      _checkpoints.forEach((id, node) {
        final double nx = (node["x"] as double) * 100.0;
        final double ny = (node["y"] as double) * 100.0;
        final dist = (canvasOffset - Offset(nx, ny)).distance;
        if (dist < 20.0) {
          tappedNodeId = id;
        }
      });

      if (tappedNodeId != null) {
        if (_activeTool == ToolType.select) {
          setState(() {
            _selectedNodeId = tappedNodeId;
            _selectedConnectionIndex = null;
          });
        } else if (_activeTool == ToolType.linkNodes) {
          if (_linkStartNodeId == null) {
            setState(() {
              _linkStartNodeId = tappedNodeId;
            });
          } else if (_linkStartNodeId != tappedNodeId) {
            _showLinkDialog(_linkStartNodeId!, tappedNodeId!);
            setState(() {
              _linkStartNodeId = null;
            });
          }
        } else if (_activeTool == ToolType.delete) {
          setState(() {
            _checkpoints.remove(tappedNodeId);
            _connections.removeWhere((c) => c["from"] == tappedNodeId || c["to"] == tappedNodeId);
            if (_selectedNodeId == tappedNodeId) _selectedNodeId = null;
            if (_linkStartNodeId == tappedNodeId) _linkStartNodeId = null;
            _selectedConnectionIndex = null;
          });
        }
      } else {
        // Tapped empty space, check if connection is tapped
        int? tappedConnIndex;
        for (int i = 0; i < _connections.length; i++) {
          final conn = _connections[i];
          final from = conn["from"];
          final to = conn["to"];
          if (_checkpoints.containsKey(from) && _checkpoints.containsKey(to)) {
            List<dynamic> pathPoints = conn["path"] ?? [];
            if (pathPoints.isNotEmpty) {
              for (int j = 0; j < pathPoints.length - 1; j++) {
                final a = Offset((pathPoints[j][0] as double) * 100.0, (pathPoints[j][1] as double) * 100.0);
                final b = Offset((pathPoints[j+1][0] as double) * 100.0, (pathPoints[j+1][1] as double) * 100.0);
                if (_distanceToSegment(canvasOffset, a, b) < 12.0) {
                  tappedConnIndex = i;
                  break;
                }
              }
            } else {
              final a = Offset((_checkpoints[from]!["x"] as double) * 100.0, (_checkpoints[from]!["y"] as double) * 100.0);
              final b = Offset((_checkpoints[to]!["x"] as double) * 100.0, (_checkpoints[to]!["y"] as double) * 100.0);
              final corner = Offset(b.dx, a.dy);
              final dist1 = _distanceToSegment(canvasOffset, a, corner);
              final dist2 = _distanceToSegment(canvasOffset, corner, b);
              if (dist1 < 12.0 || dist2 < 12.0) {
                tappedConnIndex = i;
              }
            }
            if (tappedConnIndex != null) break;
          }
        }

        if (_activeTool == ToolType.delete && tappedConnIndex != null) {
          setState(() {
            _connections.removeAt(tappedConnIndex!);
            _selectedConnectionIndex = null;
          });
        } else if (_activeTool == ToolType.select) {
          setState(() {
            _selectedConnectionIndex = tappedConnIndex;
            _selectedNodeId = null;
          });
        }
      }
    }
  }

  // Drag Node & Control Point Handlers
  void _handleDragStart(DragStartDetails details) {
    final canvasOffset = _screenToCanvas(details.globalPosition);

    // Draw path tool – begin freehand stroke starting from a checkpoint
    if (_activeTool == ToolType.drawPath) {
      String? nearest;
      double nearestDist = double.infinity;
      _checkpoints.forEach((id, node) {
        final double nx = (node["x"] as double) * 100.0;
        final double ny = (node["y"] as double) * 100.0;
        final d = (canvasOffset - Offset(nx, ny)).distance;
        if (d < 35.0 && d < nearestDist) {
          nearestDist = d;
          nearest = id;
        }
      });
      setState(() {
        _drawPathStartNodeId = nearest;
        _drawPathPoints = [canvasOffset];
        _drawPathCursor = canvasOffset;
      });
      return;
    }

    if (_activeTool == ToolType.linkNodes) {
      String? tappedNodeId;
      _checkpoints.forEach((id, node) {
        final double nx = (node["x"] as double) * 100.0;
        final double ny = (node["y"] as double) * 100.0;
        if ((canvasOffset - Offset(nx, ny)).distance < 25.0) {
          tappedNodeId = id;
        }
      });
      if (tappedNodeId != null) {
        setState(() {
          _linkStartNodeId = tappedNodeId;
          _freehandDragPoints = [canvasOffset];
        });
      }
      return;
    }

    if (_activeTool != ToolType.select) return;

    // 1. Check if user clicked near a control point of selected curve
    if (_selectedConnectionIndex != null) {
      final conn = _connections[_selectedConnectionIndex!];
      final type = conn["connection_type"] ?? "orthogonal";
      if (type == "curved" || type == "bezier" || type == "spline") {
        final List<dynamic> cps = conn["control_points"] ?? [];
        for (int idx = 0; idx < cps.length; idx++) {
          final double cpx = (cps[idx][0] as double) * 100.0;
          final double cpy = (cps[idx][1] as double) * 100.0;
          if ((canvasOffset - Offset(cpx, cpy)).distance < 15.0) {
            _draggingControlPointIndex = idx;
            _dragStartOffset = canvasOffset - Offset(cpx, cpy);
            return;
          }
        }
      }
    }

    // 2. Fallback to check if node is dragged
    String? dragNodeId;
    _checkpoints.forEach((id, node) {
      final double nx = (node["x"] as double) * 100.0;
      final double ny = (node["y"] as double) * 100.0;
      if ((canvasOffset - Offset(nx, ny)).distance < 20.0) {
        dragNodeId = id;
      }
    });

    if (dragNodeId != null) {
      _draggingNodeId = dragNodeId;
      _dragStartOffset = canvasOffset - Offset((_checkpoints[dragNodeId]!["x"] as double) * 100.0, (_checkpoints[dragNodeId]!["y"] as double) * 100.0);
      setState(() {
        _selectedNodeId = dragNodeId;
        _selectedConnectionIndex = null;
      });
    }
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final canvasOffset = _screenToCanvas(details.globalPosition);

    // Draw path – record every mouse position
    if (_activeTool == ToolType.drawPath && _drawPathStartNodeId != null) {
      setState(() {
        _drawPathPoints.add(canvasOffset);
        _drawPathCursor = canvasOffset;
      });
      return;
    }

    if (_activeTool == ToolType.linkNodes && _linkStartNodeId != null && _freehandDragPoints != null) {
      setState(() {
        _freehandDragPoints!.add(canvasOffset);
      });
      return;
    }

    // 1. Drag curve control point
    if (_draggingControlPointIndex != null && _selectedConnectionIndex != null && _dragStartOffset != null) {
      final targetOffset = canvasOffset - _dragStartOffset!;
      final double cpX = _snap(targetOffset.dx / 100.0, _snapStep);
      final double cpY = _snap(targetOffset.dy / 100.0, _snapStep);

      setState(() {
        final conn = _connections[_selectedConnectionIndex!];
        final List<dynamic> cps = List.from(conn["control_points"] ?? []);
        if (_draggingControlPointIndex! < cps.length) {
          cps[_draggingControlPointIndex!] = [cpX, cpY];
          conn["control_points"] = cps;
          _regenerateConnectionPath(conn);
        }
      });
      return;
    }

    // 2. Drag checkpoint node
    if (_draggingNodeId == null || _dragStartOffset == null) return;
    final targetOffset = canvasOffset - _dragStartOffset!;

    final double xMeter = targetOffset.dx / 100.0;
    final double yMeter = targetOffset.dy / 100.0;
    
    final snapX = _snap(xMeter, _snapStep);
    final snapY = _snap(yMeter, _snapStep);

    // Guidelines alignments
    double? alignX;
    double? alignY;

    _checkpoints.forEach((id, node) {
      if (id == _draggingNodeId) return;
      final double ox = node["x"] as double;
      final double oy = node["y"] as double;
      if ((snapX - ox).abs() < 0.05) {
        alignX = ox;
      }
      if ((snapY - oy).abs() < 0.05) {
        alignY = oy;
      }
    });

    setState(() {
      _checkpoints[_draggingNodeId!]!["x"] = alignX ?? snapX;
      _checkpoints[_draggingNodeId!]!["y"] = alignY ?? snapY;
      _alignX = alignX;
      _alignY = alignY;
      _updateConnectionPathsForNode(_draggingNodeId!);
    });
  }

  void _handleDragEnd(DragEndDetails details) {
    // Draw path – finish stroke and create connection
    if (_activeTool == ToolType.drawPath && _drawPathStartNodeId != null && _drawPathPoints.length >= 2) {
      final endOffset = _drawPathPoints.last;
      String? endNodeId;
      double nearestDist = double.infinity;
      _checkpoints.forEach((id, node) {
        if (id == _drawPathStartNodeId) return;
        final double nx = (node["x"] as double) * 100.0;
        final double ny = (node["y"] as double) * 100.0;
        final d = (endOffset - Offset(nx, ny)).distance;
        if (d < 45.0 && d < nearestDist) {
          nearestDist = d;
          endNodeId = id;
        }
      });

      if (endNodeId != null) {
        // Simplify the drawn stroke
        final simplified = _simplifyPath(_drawPathPoints, 8.0);

        // Determine connection type from stroke curvature
        final bool isCurved = simplified.length > 2;
        String connectionType = isCurved ? "bezier" : "straight";
        List<List<double>> controlPoints = [];

        if (isCurved) {
          // Fit 2 Bezier control points evenly along the stroke
          final cp1 = _drawPathPoints[_drawPathPoints.length ~/ 3];
          final cp2 = _drawPathPoints[(2 * _drawPathPoints.length) ~/ 3];
          controlPoints = [
            [cp1.dx / 100.0, cp1.dy / 100.0],
            [cp2.dx / 100.0, cp2.dy / 100.0],
          ];
        }

        final double p1x = _checkpoints[_drawPathStartNodeId!]!["x"] as double;
        final double p1y = _checkpoints[_drawPathStartNodeId!]!["y"] as double;
        final double p2x = _checkpoints[endNodeId!]!["x"] as double;
        final double p2y = _checkpoints[endNodeId!]!["y"] as double;
        final double dist = math.sqrt((p2x - p1x) * (p2x - p1x) + (p2y - p1y) * (p2y - p1y));

        final newConn = <String, dynamic>{
          "from": _drawPathStartNodeId!,
          "to": endNodeId!,
          "distance": dist,
          "connection_type": connectionType,
          "control_points": controlPoints,
          "radius": dist * 0.75,
          "length": dist,
        };
        _regenerateConnectionPath(newConn);

        setState(() {
          // Replace any existing connection between these two nodes
          _connections.removeWhere((c) =>
              (c["from"] == _drawPathStartNodeId! && c["to"] == endNodeId!) ||
              (c["from"] == endNodeId! && c["to"] == _drawPathStartNodeId!));
          _connections.add(newConn);
        });
      }

      setState(() {
        _drawPathStartNodeId = null;
        _drawPathPoints = [];
        _drawPathCursor = null;
      });
      return;
    }

    if (_activeTool == ToolType.linkNodes && _linkStartNodeId != null && _freehandDragPoints != null) {
      if (_freehandDragPoints!.length >= 2) {
        final endOffset = _freehandDragPoints!.last;
        String? endNodeId;
        _checkpoints.forEach((id, node) {
          if (id == _linkStartNodeId) return;
          final double nx = (node["x"] as double) * 100.0;
          final double ny = (node["y"] as double) * 100.0;
          if ((endOffset - Offset(nx, ny)).distance < 30.0) {
            endNodeId = id;
          }
        });

        if (endNodeId != null) {
          final simplified = _simplifyPath(_freehandDragPoints!, 10.0);
          String connectionType = "straight";
          List<List<double>> controlPoints = [];
          
          if (simplified.length > 2) {
            connectionType = "bezier";
            final cp1 = _freehandDragPoints![_freehandDragPoints!.length ~/ 3];
            final cp2 = _freehandDragPoints![(2 * _freehandDragPoints!.length) ~/ 3];
            controlPoints = [
              [cp1.dx / 100.0, cp1.dy / 100.0],
              [cp2.dx / 100.0, cp2.dy / 100.0]
            ];
          }

          final double p1x = _checkpoints[_linkStartNodeId!]!["x"] as double;
          final double p1y = _checkpoints[_linkStartNodeId!]!["y"] as double;
          final double p2x = _checkpoints[endNodeId!]!["x"] as double;
          final double p2y = _checkpoints[endNodeId!]!["y"] as double;
          final double pixelDist = math.sqrt((p2x - p1x) * (p2x - p1x) + (p2y - p1y) * (p2y - p1y)) * 100.0;
          final double length = pixelDist / 100.0;

          final newConn = {
            "from": _linkStartNodeId!,
            "to": endNodeId!,
            "distance": length,
            "connection_type": connectionType,
            "control_points": controlPoints,
            "radius": length * 0.75,
            "length": length,
          };
          
          _regenerateConnectionPath(newConn);
          
          setState(() {
            _connections.removeWhere((c) => 
              (c["from"] == _linkStartNodeId! && c["to"] == endNodeId!) ||
              (c["from"] == endNodeId! && c["to"] == _linkStartNodeId!)
            );
            _connections.add(newConn);
          });
        }
      }

      setState(() {
        _linkStartNodeId = null;
        _freehandDragPoints = null;
      });
      return;
    }

    setState(() {
      _draggingNodeId = null;
      _draggingControlPointIndex = null;
      _dragStartOffset = null;
      _alignX = null;
      _alignY = null;
    });
  }

  // ── Raw pointer handlers for the Draw Path Listener overlay ──────────────
  // localPosition is already in canvas-space (inside InteractiveViewer child)
  void _onDrawPointerDown(PointerDownEvent e) {
    final pos = e.localPosition;
    String? nearest;
    double nearestDist = double.infinity;
    _checkpoints.forEach((id, node) {
      final double nx = (node["x"] as double) * 100.0;
      final double ny = (node["y"] as double) * 100.0;
      final d = (pos - Offset(nx, ny)).distance;
      if (d < 50.0 && d < nearestDist) {
        nearestDist = d;
        nearest = id;
      }
    });
    setState(() {
      _drawPathStartNodeId = nearest;
      _drawPathPoints = [pos];
      _drawPathCursor = pos;
    });
  }

  void _onDrawPointerMove(PointerMoveEvent e) {
    if (_drawPathStartNodeId == null) return;
    setState(() {
      _drawPathPoints.add(e.localPosition);
      _drawPathCursor = e.localPosition;
    });
  }

  void _onDrawPointerUp(PointerUpEvent e) {
    if (_drawPathStartNodeId == null || _drawPathPoints.length < 2) {
      setState(() {
        _drawPathStartNodeId = null;
        _drawPathPoints = [];
        _drawPathCursor = null;
      });
      return;
    }

    final endOffset = e.localPosition;
    String? endNodeId;
    double nearestDist = double.infinity;
    _checkpoints.forEach((id, node) {
      if (id == _drawPathStartNodeId) return;
      final double nx = (node["x"] as double) * 100.0;
      final double ny = (node["y"] as double) * 100.0;
      final d = (endOffset - Offset(nx, ny)).distance;
      if (d < 60.0 && d < nearestDist) {
        nearestDist = d;
        endNodeId = id;
      }
    });

    if (endNodeId != null) {
      final simplified = _simplifyPath(_drawPathPoints, 8.0);
      final bool isCurved = simplified.length > 2;
      final String connectionType = isCurved ? "bezier" : "straight";
      List<List<double>> controlPoints = [];

      if (isCurved) {
        final cp1 = _drawPathPoints[_drawPathPoints.length ~/ 3];
        final cp2 = _drawPathPoints[(2 * _drawPathPoints.length) ~/ 3];
        controlPoints = [
          [cp1.dx / 100.0, cp1.dy / 100.0],
          [cp2.dx / 100.0, cp2.dy / 100.0],
        ];
      }

      final double p1x = _checkpoints[_drawPathStartNodeId!]!["x"] as double;
      final double p1y = _checkpoints[_drawPathStartNodeId!]!["y"] as double;
      final double p2x = _checkpoints[endNodeId!]!["x"] as double;
      final double p2y = _checkpoints[endNodeId!]!["y"] as double;
      final double dist = math.sqrt((p2x - p1x) * (p2x - p1x) + (p2y - p1y) * (p2y - p1y));

      final newConn = <String, dynamic>{
        "from": _drawPathStartNodeId!,
        "to": endNodeId!,
        "distance": dist,
        "connection_type": connectionType,
        "control_points": controlPoints,
        "radius": dist * 0.75,
        "length": dist,
      };
      _regenerateConnectionPath(newConn);

      setState(() {
        _connections.removeWhere((c) =>
            (c["from"] == _drawPathStartNodeId! && c["to"] == endNodeId!) ||
            (c["from"] == endNodeId! && c["to"] == _drawPathStartNodeId!));
        _connections.add(newConn);
      });
    }

    setState(() {
      _drawPathStartNodeId = null;
      _drawPathPoints = [];
      _drawPathCursor = null;
    });
  }

  List<Offset> _simplifyPath(List<Offset> points, double epsilon) {
    if (points.length < 3) return points;
    int maxIndex = 0;
    double maxDist = 0.0;
    for (int i = 1; i < points.length - 1; i++) {
      double dist = _perpendicularDistance(points[i], points[0], points.last);
      if (dist > maxDist) {
        maxDist = dist;
        maxIndex = i;
      }
    }
    if (maxDist > epsilon) {
      List<Offset> results1 = _simplifyPath(points.sublist(0, maxIndex + 1), epsilon);
      List<Offset> results2 = _simplifyPath(points.sublist(maxIndex), epsilon);
      return results1.sublist(0, results1.length - 1) + results2;
    } else {
      return [points.first, points.last];
    }
  }

  double _perpendicularDistance(Offset p, Offset p1, Offset p2) {
    double num = ((p2.dy - p1.dy) * p.dx - (p2.dx - p1.dx) * p.dy + p2.dx * p1.dy - p2.dy * p1.dx).abs();
    double den = math.sqrt((p2.dy - p1.dy) * (p2.dy - p1.dy) + (p2.dx - p1.dx) * (p2.dx - p1.dx));
    return den == 0 ? (p - p1).distance : num / den;
  }

  // Curve geometry generation and editing helpers
  void _regenerateConnectionPath(Map<String, dynamic> conn) {
    final String from = conn["from"];
    final String to = conn["to"];
    if (!_checkpoints.containsKey(from) || !_checkpoints.containsKey(to)) return;

    final double x1 = _checkpoints[from]!["x"] as double;
    final double y1 = _checkpoints[from]!["y"] as double;
    final double x2 = _checkpoints[to]!["x"] as double;
    final double y2 = _checkpoints[to]!["y"] as double;

    final String type = conn["connection_type"] ?? "orthogonal";
    final provider = Provider.of<RobotStateProvider>(context, listen: false);
    final int curveRes = provider.curveResolution;

    List<List<double>> path = [];
    double length = 0.0;

    if (type == "straight") {
      length = math.sqrt((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2));
      path = [
        [x1, y1],
        [x2, y2]
      ];
    } else if (type == "curved" || type == "bezier") {
      List<dynamic> cps = conn["control_points"] ?? [];
      if (cps.length < 2) {
        cps = [
          [x1 + (x2 - x1) / 3, y1 + (y2 - y1) / 3],
          [x1 + 2 * (x2 - x1) / 3, y1 + 2 * (y2 - y1) / 3]
        ];
        conn["control_points"] = cps;
      }
      final double cx1 = cps[0][0] as double;
      final double cy1 = cps[0][1] as double;
      final double cx2 = cps[1][0] as double;
      final double cy2 = cps[1][1] as double;

      double approxLen = 0.0;
      List<double> prevPt = [x1, y1];
      for (int step = 0; step <= curveRes; step++) {
        double t = step / curveRes;
        double tx = (1 - t) * (1 - t) * (1 - t) * x1 + 3 * (1 - t) * (1 - t) * t * cx1 + 3 * (1 - t) * t * t * cx2 + t * t * t * x2;
        double ty = (1 - t) * (1 - t) * (1 - t) * y1 + 3 * (1 - t) * (1 - t) * t * cy1 + 3 * (1 - t) * t * t * cy2 + t * t * t * y2;
        path.add([tx, ty]);
        if (step > 0) {
          approxLen += math.sqrt((tx - prevPt[0]) * (tx - prevPt[0]) + (ty - prevPt[1]) * (ty - prevPt[1]));
        }
        prevPt = [tx, ty];
      }
      length = approxLen;
    } else if (type == "arc") {
      double r = (conn["radius"] as num?)?.toDouble() ?? (math.sqrt((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2)) * 0.75);
      conn["radius"] = r;

      double mx = (x1 + x2) / 2;
      double my = (y1 + y2) / 2;
      double d = math.sqrt((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2));
      if (r < d / 2) {
        r = d / 2 + 0.01;
        conn["radius"] = r;
      }
      double hDist = math.sqrt(r * r - (d / 2) * (d / 2));
      double px = -(y2 - y1) / d;
      double py = (x2 - x1) / d;
      double cx = mx + px * hDist;
      double cy = my + py * hDist;

      double a1 = math.atan2(y1 - cy, x1 - cx);
      double a2 = math.atan2(y2 - cy, x2 - cx);
      double adiff = a2 - a1;
      if (adiff.abs() > math.pi) {
        if (adiff > 0) {
          adiff -= 2 * math.pi;
        } else {
          adiff += 2 * math.pi;
        }
      }

      double approxLen = 0.0;
      List<double> prevPt = [x1, y1];
      for (int step = 0; step <= curveRes; step++) {
        double t = step / curveRes;
        double angle = a1 + t * adiff;
        double tx = cx + r * math.cos(angle);
        double ty = cy + r * math.sin(angle);
        path.add([tx, ty]);
        if (step > 0) {
          approxLen += math.sqrt((tx - prevPt[0]) * (tx - prevPt[0]) + (ty - prevPt[1]) * (ty - prevPt[1]));
        }
        prevPt = [tx, ty];
      }
      length = approxLen;
      conn["control_points"] = [[cx, cy]];
    } else {
      length = (x1 - x2).abs() + (y1 - y2).abs();
      path = [
        [x1, y1],
        [x2, y1],
        [x2, y2]
      ];
    }

    conn["path"] = path;
    conn["distance"] = length;
  }

  void _updateConnectionPathsForNode(String nodeId) {
    for (var conn in _connections) {
      if (conn["from"] == nodeId || conn["to"] == nodeId) {
        _regenerateConnectionPath(conn);
      }
    }
  }

  void _splitSelectedConnection() {
    if (_selectedConnectionIndex == null) return;
    final conn = _connections[_selectedConnectionIndex!];
    final String from = conn["from"];
    final String to = conn["to"];
    final List<dynamic> path = conn["path"] ?? [];
    if (path.length < 2) return;

    final midIdx = path.length ~/ 2;
    final double nx = path[midIdx][0];
    final double ny = path[midIdx][1];

    final newLabel = _getNextNodeLabel();
    setState(() {
      _checkpoints[newLabel] = {
        "x": nx,
        "y": ny,
        "name": "Node $newLabel",
        "color": "#00FFCC",
        "iconType": "general",
      };

      _connections.removeAt(_selectedConnectionIndex!);

      final conn1 = {
        "from": from,
        "to": newLabel,
        "connection_type": conn["connection_type"] ?? "orthogonal",
      };
      _connections.add(conn1);
      _regenerateConnectionPath(conn1);

      final conn2 = {
        "from": newLabel,
        "to": to,
        "connection_type": conn["connection_type"] ?? "orthogonal",
      };
      _connections.add(conn2);
      _regenerateConnectionPath(conn2);

      _selectedConnectionIndex = null;
      _selectedNodeId = newLabel;
    });
  }

  void _mergeNodeConnections(String nodeId) {
    final nodeConns = _connections.where((c) => c["from"] == nodeId || c["to"] == nodeId).toList();
    if (nodeConns.length != 2) return;

    final conn1 = nodeConns[0];
    final conn2 = nodeConns[1];

    final String a = conn1["from"] == nodeId ? conn1["to"] : conn1["from"];
    final String b = conn2["from"] == nodeId ? conn2["to"] : conn2["from"];
    final double mx = _checkpoints[nodeId]!["x"] as double;
    final double my = _checkpoints[nodeId]!["y"] as double;

    setState(() {
      _checkpoints.remove(nodeId);
      _connections.remove(conn1);
      _connections.remove(conn2);

      final newConn = {
        "from": a,
        "to": b,
        "connection_type": "curved",
        "control_points": [
          [mx, my],
          [mx, my]
        ]
      };
      _connections.add(newConn);
      _regenerateConnectionPath(newConn);

      _selectedNodeId = null;
      _selectedConnectionIndex = _connections.indexOf(newConn);
    });
  }

  // Hover Updates (mostly for snapping visuals)
  void _handlePointerHover(PointerHoverEvent event) {
    if (_activeTool == ToolType.addNode) {
      final canvasOffset = _screenToCanvas(event.position);
      final double xMeter = canvasOffset.dx / 100.0;
      final double yMeter = canvasOffset.dy / 100.0;
      final snapX = _snap(xMeter, _snapStep);
      final snapY = _snap(yMeter, _snapStep);

      setState(() {
        _hoverOffset = Offset(snapX * 100.0, snapY * 100.0);
      });
    } else {
      if (_hoverOffset != null) {
        setState(() {
          _hoverOffset = null;
        });
      }
    }
  }

  // Link Dialog
  Future<void> _showLinkDialog(String from, String to) async {
    final x1 = _checkpoints[from]!["x"] as double;
    final y1 = _checkpoints[from]!["y"] as double;
    final x2 = _checkpoints[to]!["x"] as double;
    final y2 = _checkpoints[to]!["y"] as double;

    String connectionType = "orthogonal"; // Default
    final provider = Provider.of<RobotStateProvider>(context, listen: false);
    final int curveRes = provider.curveResolution;

    double calcDist(String type) {
      if (type == "straight") {
        return math.sqrt((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2));
      } else if (type == "curved") {
        double approxLen = 0.0;
        List<double> prevPt = [x1, y1];
        for (int step = 1; step <= curveRes; step++) {
          double t = step / curveRes;
          double tx = (1 - t) * (1 - t) * x1 + 2 * (1 - t) * t * x2 + t * t * x2;
          double ty = (1 - t) * (1 - t) * y1 + 2 * (1 - t) * t * y1 + t * t * y2;
          double dx = tx - prevPt[0];
          double dy = ty - prevPt[1];
          approxLen += math.sqrt(dx * dx + dy * dy);
          prevPt = [tx, ty];
        }
        return approxLen;
      } else {
        // Orthogonal (L-Shape)
        return (x1 - x2).abs() + (y1 - y2).abs();
      }
    }

    final controller = TextEditingController(text: calcDist(connectionType).toStringAsFixed(1));

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF131B26),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xFF1F2E45))),
              title: Text(
                "CONNECT $from ↔ $to",
                style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Connection Routing Type:",
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0C1017),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFF1E2E43)),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: connectionType,
                        dropdownColor: const Color(0xFF131B26),
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        items: const [
                          DropdownMenuItem(
                            value: "orthogonal",
                            child: Text("Orthogonal (L-Shape)"),
                          ),
                          DropdownMenuItem(
                            value: "straight",
                            child: Text("Straight (Direct Line)"),
                          ),
                          DropdownMenuItem(
                            value: "curved",
                            child: Text("Curved (Bezier Curve)"),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() {
                              connectionType = val;
                              controller.text = calcDist(connectionType).toStringAsFixed(1);
                            });
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    "Calculated Length: ${calcDist(connectionType).toStringAsFixed(2)} meters",
                    style: const TextStyle(color: Color(0xFF8BA2C0), fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    "Verify/Edit Distance (meters)",
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(
                        color: Colors.white, fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                      filled: true,
                      fillColor: Color(0xFF0C1017),
                      border: OutlineInputBorder(),
                      focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF00FFCC))),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text("CANCEL", style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  onPressed: () {
                    final double dist = double.tryParse(controller.text) ?? calcDist(connectionType);
                    
                    List<List<double>> path = [];
                    if (connectionType == "straight") {
                      path = [
                        [x1, y1],
                        [x2, y2]
                      ];
                    } else if (connectionType == "curved") {
                      for (int step = 0; step <= curveRes; step++) {
                        double t = step / curveRes;
                        double tx = (1 - t) * (1 - t) * x1 + 2 * (1 - t) * t * x2 + t * t * x2;
                        double ty = (1 - t) * (1 - t) * y1 + 2 * (1 - t) * t * y1 + t * t * y2;
                        path.add([tx, ty]);
                      }
                    } else {
                      // Orthogonal
                      path = [
                        [x1, y1],
                        [x2, y1],
                        [x2, y2]
                      ];
                    }

                    setState(() {
                      _connections.removeWhere((c) =>
                          (c["from"] == from && c["to"] == to) ||
                          (c["from"] == to && c["to"] == from));

                      _connections.add({
                        "from": from,
                        "to": to,
                        "distance": dist,
                        "path": path,
                        "connection_type": connectionType,
                      });
                    });
                    Navigator.of(context).pop();
                  },
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00FFCC)),
                  child: const Text("CONNECT",
                      style: TextStyle(
                          color: Colors.black, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Details dialog for checkpoints
  Future<void> _showNodeDetailsDialog(String nodeId) async {
    final node = _checkpoints[nodeId]!;
    final idController = TextEditingController(text: nodeId);
    final nameController = TextEditingController(text: node["name"] ?? "");
    String selectedIcon = node["iconType"] ?? "general";
    String selectedColorHex = node["color"] ?? "#00FFCC";

    final List<String> iconTypes = [
      "general",
      "reception",
      "kitchen",
      "warehouse",
      "bay",
      "charger"
    ];
    final List<Map<String, String>> colors = [
      {"name": "Neon Cyan", "hex": "#00FFCC"},
      {"name": "Electric Purple", "hex": "#CC00FF"},
      {"name": "Amber Gold", "hex": "#FF9100"},
      {"name": "Emerald Green", "hex": "#00FF66"},
      {"name": "Ruby Red", "hex": "#FF3366"},
      {"name": "Sky Blue", "hex": "#00E5FF"},
    ];

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF131B26),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Color(0xFF1F2E45))),
            title: Text(
              "EDIT CHECKPOINT: $nodeId",
              style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("CHECKPOINT LABEL ID",
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: idController,
                    style: const TextStyle(
                        color: Colors.white, fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                      filled: true,
                      fillColor: Color(0xFF0C1017),
                      border: OutlineInputBorder(),
                      focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF00FFCC))),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text("CUSTOM NAME / DESCRIPTION",
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      filled: true,
                      fillColor: Color(0xFF0C1017),
                      border: OutlineInputBorder(),
                      focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF00FFCC))),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text("ICON TYPE",
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0C1017),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF1F2E45)),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: selectedIcon,
                        dropdownColor: const Color(0xFF101622),
                        isExpanded: true,
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold),
                        items: iconTypes
                            .map((t) => DropdownMenuItem<String>(
                                  value: t,
                                  child: Row(
                                    children: [
                                      Icon(_getIconData(t),
                                          color: const Color(0xFF00FFCC), size: 16),
                                      const SizedBox(width: 8),
                                      Text(t.toUpperCase()),
                                    ],
                                  ),
                                ))
                            .toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() {
                              selectedIcon = val;
                            });
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text("COLOR CODING",
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: colors.map((c) {
                      final bool isSel = selectedColorHex == c["hex"];
                      final Color col =
                          Color(int.parse(c["hex"]!.replaceAll("#", "0xFF")));
                      return GestureDetector(
                        onTap: () {
                          setDialogState(() {
                            selectedColorHex = c["hex"]!;
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: isSel
                                ? col.withValues(alpha: 0.2)
                                : const Color(0xFF0C1017),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                                color: isSel ? col : const Color(0xFF1F2E45),
                                width: isSel ? 1.5 : 1),
                          ),
                          child: Text(
                            c["name"]!,
                            style: TextStyle(
                                color: isSel ? Colors.white : Colors.white60,
                                fontSize: 10,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child:
                    const Text("CANCEL", style: TextStyle(color: Colors.grey)),
              ),
              ElevatedButton(
                onPressed: () {
                  final newId = idController.text.trim();
                  if (newId.isEmpty) return;

                  setState(() {
                    if (newId != nodeId) {
                      if (_checkpoints.containsKey(newId)) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text("Checkpoint label already exists!"),
                              backgroundColor: Colors.redAccent),
                        );
                        return;
                      }
                      final oldData = _checkpoints.remove(nodeId)!;
                      _checkpoints[newId] = {
                        ...oldData,
                        "name": nameController.text.trim().isEmpty
                            ? "Node $newId"
                            : nameController.text.trim(),
                        "iconType": selectedIcon,
                        "color": selectedColorHex,
                      };
                      for (var conn in _connections) {
                        if (conn["from"] == nodeId) conn["from"] = newId;
                        if (conn["to"] == nodeId) conn["to"] = newId;
                      }
                      if (_selectedNodeId == nodeId) _selectedNodeId = newId;
                    } else {
                      _checkpoints[nodeId] = {
                        ..._checkpoints[nodeId]!,
                        "name": nameController.text.trim().isEmpty
                            ? "Node $nodeId"
                            : nameController.text.trim(),
                        "iconType": selectedIcon,
                        "color": selectedColorHex,
                      };
                    }
                  });
                  Navigator.of(context).pop();
                },
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00FFCC)),
                child: const Text("SAVE CHANGES",
                    style: TextStyle(
                        color: Colors.black, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        });
      },
    );
  }

  // Load backend map JSON details to local editor state
  Future<void> _loadMapToEditor(
      RobotStateProvider provider, String fileName, String mapName) async {
    final backendService = BackendService(
        baseUrl: provider.backendIp.startsWith("http")
            ? provider.backendIp
            : "http://${provider.backendIp}");
    final detail = await backendService.fetchCustomMapDetail(fileName);
    if (detail.containsKey("error")) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text("Failed to load map details: ${detail["error"]}"),
              backgroundColor: Colors.redAccent),
        );
      }
      return;
    }

    setState(() {
      _mapName = mapName;
      _checkpoints.clear();
      _connections.clear();

      final mapCheckpoints = detail["checkpoints"] as Map<String, dynamic>? ?? {};
      final mapConnections = detail["connections"] as List<dynamic>? ?? [];

      mapCheckpoints.forEach((key, val) {
        _checkpoints[key] = {
          "x": (val["x"] as num).toDouble(),
          "y": (val["y"] as num).toDouble(),
          "name": val["name"] ?? "Node $key",
          "iconType": val["iconType"] ?? "general",
          "color": val["color"] ?? "#00FFCC",
        };
      });

      for (var conn in mapConnections) {
        _connections.add({
          "from": conn["from"],
          "to": conn["to"],
          "distance": (conn["distance"] as num).toDouble(),
          "path": conn["path"],
          "connection_type": conn["connection_type"] ?? "straight",
          "control_points": conn["control_points"] ?? [],
          "radius": conn["radius"] != null ? (conn["radius"] as num).toDouble() : null,
          "length": conn["length"] != null ? (conn["length"] as num).toDouble() : (conn["distance"] as num).toDouble(),
          "heading": conn["heading"] != null ? (conn["heading"] as num).toDouble() : 0.0,
          "curvature": conn["curvature"] != null ? (conn["curvature"] as num).toDouble() : 0.0,
        });
      }
      _selectedNodeId = null;
      _selectedConnectionIndex = null;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text("Map '$mapName' loaded to designer workspace"),
            backgroundColor: const Color(0xFF131B26)),
      );
    }
  }

  // Bootstrap layout from AI occupancy map upload
  Future<void> _bootstrapFromAI(RobotStateProvider provider) async {
    setState(() {
      _isAIBootstrapping = true;
    });

    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        setState(() {
          _isAIBootstrapping = false;
        });
        return;
      }

      final pickedFile = result.files.single;
      List<int>? fileBytes;
      final String filename = pickedFile.name;

      if (pickedFile.bytes != null && pickedFile.bytes!.isNotEmpty) {
        fileBytes = pickedFile.bytes!;
      } else if (!kIsWeb && pickedFile.path != null) {
        fileBytes = await readFileBytes(pickedFile.path!);
      }

      if (fileBytes == null || fileBytes.isEmpty) {
        setState(() {
          _isAIBootstrapping = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text("Could not read file bytes"),
                backgroundColor: Colors.redAccent),
          );
        }
        return;
      }

      final backendService = BackendService(
          baseUrl: provider.backendIp.startsWith("http")
              ? provider.backendIp
              : "http://${provider.backendIp}");
      final apiResult = await backendService.uploadMap(fileBytes, filename);

      setState(() {
        _isAIBootstrapping = false;
      });

      if (apiResult["status"] == "SUCCESS") {
        final parsedMetric =
            Map<String, dynamic>.from(apiResult["metric_checkpoints"] ?? {});
        final parsedConns = List<dynamic>.from(apiResult["connections"] ?? []);

        setState(() {
          _uploadedImageBytes = Uint8List.fromList(fileBytes!);
          _checkpoints.clear();
          _connections.clear();

          parsedMetric.forEach((key, val) {
            _checkpoints[key] = {
              "x": (val["x"] as num).toDouble(),
              "y": (val["y"] as num).toDouble(),
              "name": "Node $key",
              "iconType": "general",
              "color": "#00FFCC",
            };
          });

          for (var c in parsedConns) {
            _connections.add({
              "from": c["from"],
              "to": c["to"],
              "distance": (c["distance"] as num).toDouble(),
              "path": c["path"],
              "connection_type": c["connection_type"] ?? "straight",
              "control_points": c["control_points"] ?? [],
              "radius": c["radius"] != null ? (c["radius"] as num).toDouble() : null,
              "length": c["length"] != null ? (c["length"] as num).toDouble() : (c["distance"] as num).toDouble(),
              "heading": c["heading"] != null ? (c["heading"] as num).toDouble() : 0.0,
              "curvature": c["curvature"] != null ? (c["curvature"] as num).toDouble() : 0.0,
            });
          }
          _selectedNodeId = null;
          _selectedConnectionIndex = null;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    "Draft map bootstrapped from '$filename'! ${parsedMetric.length} nodes extracted."),
                backgroundColor: const Color(0xFF131B26)),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content:
                    Text("AI Extract failed: ${apiResult["message"] ?? 'unknown'}")),
          );
        }
      }
    } catch (e) {
      setState(() {
        _isAIBootstrapping = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: ${e.toString()}")),
        );
      }
    }
  }

  // Export local state to JSON text
  void _exportMap() {
    final mapData = {
      "map_name": _mapName,
      "unit": "meters",
      "checkpoints": _checkpoints,
      "connections": _connections,
    };
    final jsonText = const JsonEncoder.withIndent("  ").convert(mapData);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF131B26),
          title: Text(
            "EXPORT MAP: $_mapName",
            style: const TextStyle(
                color: Colors.white,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Copy the JSON code block below to transfer this custom layout configuration.",
                style: TextStyle(color: Colors.white60, fontSize: 11),
              ),
              const SizedBox(height: 12),
              Container(
                constraints: const BoxConstraints(maxHeight: 250),
                width: double.maxFinite,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0C1017),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    jsonText,
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        color: Color(0xFF00FFCC),
                        fontSize: 10),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("CLOSE", style: TextStyle(color: Colors.grey)),
            ),
          ],
        );
      },
    );
  }

  // Import JSON configuration
  void _importMapJSON() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF131B26),
          title: const Text(
            "IMPORT JSON LAYOUT",
            style: TextStyle(
                color: Colors.white,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Paste the valid custom map JSON contents below:",
                style: TextStyle(color: Colors.white60, fontSize: 11),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 10,
                style: const TextStyle(
                    fontFamily: 'monospace', color: Colors.white, fontSize: 10),
                decoration: const InputDecoration(
                  filled: true,
                  fillColor: Color(0xFF0C1017),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("CANCEL", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                try {
                  final data = json.decode(controller.text);
                  if (data is Map<String, dynamic>) {
                    setState(() {
                      _mapName = data["map_name"] ?? "Imported Map";
                      _checkpoints.clear();
                      _connections.clear();

                      final cps = data["checkpoints"] as Map<String, dynamic>? ?? {};
                      final conns = data["connections"] as List<dynamic>? ?? [];

                      cps.forEach((key, val) {
                        _checkpoints[key] = {
                          "x": (val["x"] as num).toDouble(),
                          "y": (val["y"] as num).toDouble(),
                          "name": val["name"] ?? "Node $key",
                          "iconType": val["iconType"] ?? "general",
                          "color": val["color"] ?? "#00FFCC",
                        };
                      });

                      for (var conn in conns) {
                        _connections.add({
                          "from": conn["from"],
                          "to": conn["to"],
                          "distance": (conn["distance"] as num).toDouble(),
                          "path": conn["path"],
                          "connection_type": conn["connection_type"] ?? "straight",
                          "control_points": conn["control_points"] ?? [],
                          "radius": conn["radius"] != null ? (conn["radius"] as num).toDouble() : null,
                          "length": conn["length"] != null ? (conn["length"] as num).toDouble() : (conn["distance"] as num).toDouble(),
                          "heading": conn["heading"] != null ? (conn["heading"] as num).toDouble() : 0.0,
                          "curvature": conn["curvature"] != null ? (conn["curvature"] as num).toDouble() : 0.0,
                        });
                      }
                      _selectedNodeId = null;
                      _selectedConnectionIndex = null;
                    });
                    Navigator.of(context).pop();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text("Map '$_mapName' imported successfully!"),
                            backgroundColor: const Color(0xFF131B26)),
                      );
                    }
                  }
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text("Invalid JSON structure!"),
                        backgroundColor: Colors.redAccent),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00FFCC)),
              child: const Text("IMPORT",
                  style: TextStyle(
                      color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  // Duplicate current map layout
  void _duplicateMap() {
    final controller = TextEditingController(text: "$_mapName (Copy)");
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF131B26),
          title: const Text(
            "DUPLICATE MAP LAYOUT",
            style: TextStyle(
                color: Colors.white,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Enter Duplicate Name",
                  style: TextStyle(color: Colors.white70, fontSize: 11)),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  filled: true,
                  fillColor: Color(0xFF0C1017),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("CANCEL", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                final newName = controller.text.trim();
                if (newName.isNotEmpty) {
                  setState(() {
                    _mapName = newName;
                  });
                  Navigator.of(context).pop();
                }
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00FFCC)),
              child: const Text("DUPLICATE",
                  style: TextStyle(
                      color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  // Save Layout and switch to Mission Planner
  Future<void> _saveAndActivateMap(RobotStateProvider provider) async {
    if (_checkpoints.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Cannot save an empty map graph!"),
            backgroundColor: Colors.redAccent),
      );
      return;
    }

    final mapData = {
      "map_name": _mapName,
      "checkpoints": _checkpoints,
      "connections": _connections,
      "unit": "meters"
    };

    final success = await provider.saveAndActivateCustomMap(_mapName, mapData);
    if (success) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text("Map '$_mapName' saved and set active!"),
              backgroundColor: const Color(0xFF131B26)),
        );
      }
      widget.onSelectForMission(); // nav callback to mission planner index 1
    }
  }

  void _deleteAllNodesAndCorridors() {
    setState(() {
      _checkpoints.clear();
      _connections.clear();
      _selectedNodeId = null;
      _selectedConnectionIndex = null;
      _linkStartNodeId = null;
      _draggingNodeId = null;
      _freehandDragPoints = null;
      _drawPathPoints.clear();
      _drawPathStartNodeId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RobotStateProvider>(context);

    // Bounding stats calculations
    double minX = double.infinity;
    double maxX = -double.infinity;
    double minY = double.infinity;
    double maxY = -double.infinity;
    _checkpoints.forEach((_, node) {
      final double x = node["x"] as double;
      final double y = node["y"] as double;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    });
    double widthM = _checkpoints.isEmpty ? 0.0 : (maxX - minX);
    double heightM = _checkpoints.isEmpty ? 0.0 : (maxY - minY);
    double totalLength = _connections.fold(
        0.0, (sum, item) => sum + (item["distance"] as double));

    return LayoutBuilder(builder: (context, constraints) {
      final bool isWide = constraints.maxWidth > 950;

      return Row(
        children: [
          // ── LEFT WORKSPACE CANVAS ──────────────────────────────────────────
          Expanded(
            child: Container(
              color: const Color(0xFF080B0F),
              child: Column(
                children: [
                  // Top Canvas Toolbar
                  _buildCanvasToolbar(),
                  // Canvas Painter Area
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0A0D14),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF1F2E45), width: 2.0),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Stack(
                          children: [
                            // Main CAD editor canvas
                            MouseRegion(
                              onHover: _handlePointerHover,
                              child: GestureDetector(
                                key: _canvasKey,
                                onTapUp: _handleCanvasTap,
                                onPanStart: _handleDragStart,
                                onPanUpdate: _handleDragUpdate,
                                onPanEnd: _handleDragEnd,
                                child: InteractiveViewer(
                                  transformationController: _transformationController,
                                  boundaryMargin: const EdgeInsets.all(1000),
                                  minScale: 0.2,
                                  maxScale: 5.0,
                                  panEnabled: _activeTool == ToolType.pan,
                                  scaleEnabled: _activeTool == ToolType.pan,
                                  child: SizedBox(
                                    key: _innerCanvasKey,
                                    width: 2000,
                                    height: 2000,
                                    child: Stack(
                                      children: [
                                        if (_uploadedImageBytes != null)
                                          Positioned.fill(
                                            child: Opacity(
                                              opacity: _overlayOpacity,
                                              child: Image.memory(
                                                _uploadedImageBytes!,
                                                fit: BoxFit.fill,
                                              ),
                                            ),
                                          ),
                                        CustomPaint(
                                          size: const Size(2000, 2000),
                                          painter: DesignerCanvasPainter(
                                            checkpoints: _checkpoints,
                                            connections: _connections,
                                            selectedNodeId: _selectedNodeId,
                                            selectedConnectionIndex: _selectedConnectionIndex,
                                            linkStartNodeId: _linkStartNodeId,
                                            activeTool: _activeTool,
                                            snapStep: _snapStep,
                                            hoverOffset: _hoverOffset,
                                            alignX: _alignX,
                                            alignY: _alignY,
                                            freehandDragPoints: _freehandDragPoints,
                                            drawPathPoints: _drawPathPoints,
                                            drawPathCursor: _drawPathCursor,
                                          ),
                                        ),
                                        // Transparent Listener overlay for raw pointer capture (draw path)
                                        if (_activeTool == ToolType.drawPath)
                                          Positioned.fill(
                                            child: Listener(
                                              behavior: HitTestBehavior.translucent,
                                              onPointerDown: _onDrawPointerDown,
                                              onPointerMove: _onDrawPointerMove,
                                              onPointerUp: _onDrawPointerUp,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            
                            // Visual CAD Scale Overlay
                            Positioned(
                              top: 12,
                              left: 12,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.75),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: const Color(0xFFCC00FF).withValues(alpha: 0.4), width: 1),
                                ),
                                child: Text(
                                  "DESIGNER CAD: 1 Grid Block = 1.0m (100px) • Snap: ${_snapStep > 0 ? '${_snapStep}m' : 'OFF'}",
                                  style: const TextStyle(
                                    color: Color(0xFFCC00FF),
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.bold,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                            ),

                            // Mini stats overlay
                            Positioned(
                              bottom: 12,
                              left: 12,
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.7),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: const Color(0xFF1F2E45)),
                                ),
                                child: Text(
                                  "Checkpoints: ${_checkpoints.length}\nCorridors: ${_connections.length}\nBounds: ${widthM.toStringAsFixed(1)}m × ${heightM.toStringAsFixed(1)}m\nTotal Path Distance: ${totalLength.toStringAsFixed(1)}m",
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
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          // ── RIGHT CONTROLS PANEL ───────────────────────────────────────────
          if (isWide)
            Container(
              width: 320,
              decoration: const BoxDecoration(
                color: HudColors.cardBg,
                border: Border(left: BorderSide(color: HudColors.border, width: 1.5)),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildMapInfoCard(),
                    const SizedBox(height: 20),
                    _buildCheckpointSelectionDetailsPanel(),
                    const SizedBox(height: 20),
                    _buildConnectionSelectionDetailsPanel(),
                    const SizedBox(height: 20),
                    _buildAISandboxBootstrapCard(provider),
                    const SizedBox(height: 20),
                    _buildSavedMapsList(provider),
                  ],
                ),
              ),
            )
        ],
      );
    });
  }

  // Horizontal Canvas toolbar controls
  Widget _buildCanvasToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Tool Button actions
          _buildToolButton(ToolType.select, Icons.arrow_outward_rounded, "Select / Move"),
          const SizedBox(width: 8),
          _buildToolButton(ToolType.addNode, Icons.add_location_alt_rounded, "Add Checkpoint"),
          const SizedBox(width: 8),
          _buildToolButton(ToolType.linkNodes, Icons.add_link_rounded, "Add corridor"),
          const SizedBox(width: 8),
          _buildToolButton(ToolType.drawPath, Icons.gesture_rounded, "Draw path"),
          const SizedBox(width: 8),
          _buildToolButton(ToolType.delete, Icons.delete_outline_rounded, "Delete tool"),
          const SizedBox(width: 8),
          _buildToolButton(ToolType.pan, Icons.pan_tool_outlined, "Pan canvas"),
          const Spacer(),
          
          // Snapping dropdown selector
          const Text("SNAP: ", style: TextStyle(color: Color(0xFF5A6F8F), fontSize: 10, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF0C1017),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF1F2E45)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<double>(
                value: _snapStep,
                dropdownColor: const Color(0xFF101622),
                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                items: const [
                  DropdownMenuItem(value: 1.0, child: Text("1.0 m")),
                  DropdownMenuItem(value: 0.5, child: Text("0.5 m")),
                  DropdownMenuItem(value: 0.25, child: Text("0.25 m")),
                  DropdownMenuItem(value: 0.0, child: Text("NONE")),
                ],
                onChanged: (val) {
                  if (val != null) {
                    setState(() {
                      _snapStep = val;
                    });
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolButton(ToolType tool, IconData icon, String tooltip) {
    final bool isSelected = _activeTool == tool;
    final activeColor = isSelected ? const Color(0xFF00FFCC) : const Color(0xFF6B7A90);
    
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () {
          setState(() {
            _activeTool = tool;
            _linkStartNodeId = null;
          });
        },
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF00FFCC).withValues(alpha: 0.08) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: isSelected ? const Color(0xFF00FFCC).withValues(alpha: 0.4) : Colors.transparent),
          ),
          child: Icon(icon, color: activeColor, size: 18),
        ),
      ),
    );
  }

  // Bounding map details card
  Widget _buildMapInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF131B26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E2E43)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("MAP IDENTIFIER", style: TextStyle(color: Color(0xFF5A6F8F), fontSize: 9, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
          const SizedBox(height: 6),
          TextField(
            controller: TextEditingController(text: _mapName),
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 8),
              focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00FFCC))),
              enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF1F2E45))),
            ),
            onChanged: (val) {
              _mapName = val;
            },
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              OutlinedButton(
                onPressed: _duplicateMap,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF1F2E45)),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
                child: const Text("DUPLICATE", style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
              ),
              OutlinedButton(
                onPressed: _exportMap,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF1F2E45)),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
                child: const Text("EXPORT JSON", style: TextStyle(color: Color(0xFF00E5FF), fontSize: 9, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _importMapJSON,
            icon: const Icon(Icons.upload_file_rounded, size: 12, color: Colors.white70),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF1F2E45)),
              minimumSize: const Size(double.infinity, 36),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            label: const Text("IMPORT JSON CONFIG", style: TextStyle(color: Colors.white70, fontSize: 9, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: () => _saveAndActivateMap(Provider.of<RobotStateProvider>(context, listen: false)),
            icon: const Icon(Icons.save_rounded, size: 14, color: Colors.black),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00FFCC),
              minimumSize: const Size(double.infinity, 40),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            label: const Text("SAVE & ACTIVATE MAP", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 11)),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _deleteAllNodesAndCorridors,
            icon: const Icon(Icons.delete_sweep_rounded, size: 14, color: Colors.redAccent),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.redAccent),
              minimumSize: const Size(double.infinity, 36),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            label: const Text("DELETE ALL NODES AND CORIDORS", style: TextStyle(color: Colors.redAccent, fontSize: 9, fontWeight: FontWeight.bold)),
          ),
          if (_uploadedImageBytes != null) ...[
            const SizedBox(height: 16),
            const Divider(color: Color(0xFF1E2E43)),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("OVERLAY OPACITY", style: TextStyle(color: Color(0xFF5A6F8F), fontSize: 9, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                Text("${(_overlayOpacity * 100).toStringAsFixed(0)}%", style: const TextStyle(color: Color(0xFF00FFCC), fontSize: 9, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
              ],
            ),
            const SizedBox(height: 4),
            Slider(
              value: _overlayOpacity,
              min: 0.0,
              max: 1.0,
              activeColor: const Color(0xFF00FFCC),
              inactiveColor: const Color(0xFF1F2E45),
              onChanged: (val) {
                setState(() {
                  _overlayOpacity = val;
                });
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildConnectionSelectionDetailsPanel() {
    if (_selectedConnectionIndex == null || _selectedConnectionIndex! >= _connections.length) {
      return const SizedBox.shrink();
    }

    final conn = _connections[_selectedConnectionIndex!];
    final String from = conn["from"];
    final String to = conn["to"];
    final double dist = (conn["distance"] as num).toDouble();
    final String type = conn["connection_type"] ?? "orthogonal";

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF131B26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF00FFCC).withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.alt_route_rounded, color: Color(0xFF00FFCC), size: 14),
              const SizedBox(width: 8),
              Text(
                "CORRIDOR: $from ↔ $to",
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
            ],
          ),
          const Divider(color: Color(0xFF1E2E43), height: 16),
          _buildMetricRow("Calculated Length", "${dist.toStringAsFixed(2)} m"),
          const SizedBox(height: 12),
          const Text(
            "Routing/Curve Type:",
            style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF0C1017),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFF1E2E43)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: type == "curved" ? "bezier" : type,
                dropdownColor: const Color(0xFF131B26),
                isExpanded: true,
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                items: const [
                  DropdownMenuItem(value: "orthogonal", child: Text("Orthogonal (L-Shape)")),
                  DropdownMenuItem(value: "straight", child: Text("Straight (Direct Line)")),
                  DropdownMenuItem(value: "bezier", child: Text("Cubic Bezier")),
                  DropdownMenuItem(value: "arc", child: Text("Circular Arc")),
                ],
                onChanged: (val) {
                  if (val != null) {
                    setState(() {
                      conn["connection_type"] = val;
                      if (val == "bezier") {
                        final double x1 = _checkpoints[from]!["x"] as double;
                        final double y1 = _checkpoints[from]!["y"] as double;
                        final double x2 = _checkpoints[to]!["x"] as double;
                        final double y2 = _checkpoints[to]!["y"] as double;
                        conn["control_points"] = [
                          [x1 + (x2 - x1) / 3, y1 + (y2 - y1) / 3],
                          [x1 + 2 * (x2 - x1) / 3, y1 + 2 * (y2 - y1) / 3]
                        ];
                      } else if (val == "arc") {
                        final double x1 = _checkpoints[from]!["x"] as double;
                        final double y1 = _checkpoints[from]!["y"] as double;
                        final double x2 = _checkpoints[to]!["x"] as double;
                        final double y2 = _checkpoints[to]!["y"] as double;
                        conn["radius"] = math.sqrt((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2)) * 0.75;
                      }
                      _regenerateConnectionPath(conn);
                    });
                  }
                },
              ),
            ),
          ),
          if (type == "arc") ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Arc Radius:", style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold)),
                Text("${(conn["radius"] as num?)?.toStringAsFixed(2) ?? '1.0'} m", style: const TextStyle(color: Color(0xFF00FFCC), fontSize: 10, fontFamily: 'monospace')),
              ],
            ),
            Slider(
              value: (conn["radius"] as num?)?.toDouble() ?? 1.0,
              min: math.max(0.1, math.sqrt(
                ((_checkpoints[from]!["x"] as double) - (_checkpoints[to]!["x"] as double)) * ((_checkpoints[from]!["x"] as double) - (_checkpoints[to]!["x"] as double)) +
                ((_checkpoints[from]!["y"] as double) - (_checkpoints[to]!["y"] as double)) * ((_checkpoints[from]!["y"] as double) - (_checkpoints[to]!["y"] as double))
              ) / 2.0),
              max: 20.0,
              activeColor: const Color(0xFF00FFCC),
              inactiveColor: const Color(0xFF1F2E45),
              onChanged: (val) {
                setState(() {
                  conn["radius"] = val;
                  _regenerateConnectionPath(conn);
                });
              },
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _splitSelectedConnection,
                  icon: const Icon(Icons.splitscreen_rounded, size: 12, color: Colors.black),
                  label: const Text("SPLIT", style: TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber,
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _connections.removeAt(_selectedConnectionIndex!);
                      _selectedConnectionIndex = null;
                    });
                  },
                  icon: const Icon(Icons.delete_forever_rounded, size: 12, color: Colors.white),
                  label: const Text("DELETE", style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Display details of currently selected node
  Widget _buildCheckpointSelectionDetailsPanel() {
    if (_selectedNodeId == null || !_checkpoints.containsKey(_selectedNodeId)) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF131B26).withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF1E2E43)),
        ),
        child: const Center(
          child: Text(
            "Select a checkpoint node on the canvas to configure settings and color details.",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white30, fontSize: 10),
          ),
        ),
      );
    }

    final String id = _selectedNodeId!;
    final node = _checkpoints[id]!;
    final colorHex = node["color"] ?? "#00FFCC";
    final Color color = Color(int.parse(colorHex.replaceAll("#", "0xFF")));
    final nodeConns = _connections.where((c) => c["from"] == id || c["to"] == id).toList();
    final bool canMerge = nodeConns.length == 2;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF131B26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_getIconData(node["iconType"] ?? "general"), color: color, size: 16),
              const SizedBox(width: 8),
              Text(
                "CHECKPOINT: $id",
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.edit, size: 14, color: Color(0xFF00FFCC)),
                onPressed: () => _showNodeDetailsDialog(id),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const Divider(color: Color(0xFF1E2E43), height: 16),
          _buildMetricRow("Custom label", node["name"] ?? "Node $id"),
          _buildMetricRow("Coordinates", "(${node['x']}m, ${node['y']}m)"),
          _buildMetricRow("Icon type", (node["iconType"] ?? "general").toUpperCase()),
          if (canMerge) ...[
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () => _mergeNodeConnections(id),
              icon: const Icon(Icons.merge_type_rounded, size: 14, color: Colors.black),
              label: const Text("MERGE NEIGHBOR CORRIDORS", style: TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5FF),
                minimumSize: const Size(double.infinity, 36),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMetricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Color(0xFF5A6F8F), fontSize: 9, fontWeight: FontWeight.bold)),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 10, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // AI Assist Card
  Widget _buildAISandboxBootstrapCard(RobotStateProvider provider) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF131B26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFF9100).withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.auto_awesome, color: Color(0xFFFF9100), size: 14),
              SizedBox(width: 8),
              Text(
                "AI ASSIST BOOTSTRAP",
                style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.0),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            "Upload an existing map layout image to automatically pre-generate checkpoints and pathways in the designer.",
            style: TextStyle(color: Color(0xFF6B7A90), fontSize: 9),
          ),
          const SizedBox(height: 12),
          _isAIBootstrapping
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 8.0),
                    child: SpinKitRing(color: Color(0xFFFF9100), size: 24, lineWidth: 2.0),
                  ),
                )
              : OutlinedButton.icon(
                  onPressed: () => _bootstrapFromAI(provider),
                  icon: const Icon(Icons.rocket_launch_rounded, size: 12, color: Color(0xFFFF9100)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFFFF9100)),
                    minimumSize: const Size(double.infinity, 38),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  label: const Text("GENERATE FROM IMAGE", style: TextStyle(color: Color(0xFFFF9100), fontSize: 9, fontWeight: FontWeight.bold)),
                ),
        ],
      ),
    );
  }

  // Saved maps metadata listing
  Widget _buildSavedMapsList(RobotStateProvider provider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "SAVED LAYOUTS",
          style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.0),
        ),
        const SizedBox(height: 8),
        provider.customMapsList.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 12.0),
                child: Text("No custom maps found.", style: TextStyle(color: Colors.white30, fontSize: 10)),
              )
            : ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: provider.customMapsList.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final map = provider.customMapsList[index];
                  final String mapName = map["name"] ?? "Unnamed";
                  final String fileName = map["file_name"] ?? "";
                  final bool isActive = provider.mapFileName == fileName;

                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0C1017),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: isActive ? const Color(0xFF00FFCC) : const Color(0xFF1F2E45)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                mapName,
                                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                              Text(
                                "${map["checkpoints_count"]} nodes • ${map["connections_count"]} links",
                                style: const TextStyle(color: Colors.white30, fontSize: 9),
                              ),
                            ],
                          ),
                        ),
                        // Load Button
                        IconButton(
                          icon: const Icon(Icons.download_rounded, color: Color(0xFF00FFCC), size: 14),
                          tooltip: "Load to Editor",
                          onPressed: () => _loadMapToEditor(provider, fileName, mapName),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                        const SizedBox(width: 8),
                        // Delete Button
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 14),
                          tooltip: "Delete",
                          onPressed: () => provider.deleteCustomMapProvider(fileName),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ],
    );
  }
}

class DesignerCanvasPainter extends CustomPainter {
  final Map<String, Map<String, dynamic>> checkpoints;
  final List<Map<String, dynamic>> connections;
  final String? selectedNodeId;
  final int? selectedConnectionIndex;
  final String? linkStartNodeId;
  final ToolType activeTool;
  final double snapStep;
  final Offset? hoverOffset;
  final double? alignX;
  final double? alignY;
  final List<Offset>? freehandDragPoints;
  final List<Offset> drawPathPoints;
  final Offset? drawPathCursor;

  DesignerCanvasPainter({
    required this.checkpoints,
    required this.connections,
    required this.selectedNodeId,
    required this.selectedConnectionIndex,
    required this.linkStartNodeId,
    required this.activeTool,
    required this.snapStep,
    this.hoverOffset,
    this.alignX,
    this.alignY,
    this.freehandDragPoints,
    this.drawPathPoints = const [],
    this.drawPathCursor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Paint background dark grid
    final gridPaint = Paint()
      ..color = const Color(0xFF151D2A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    final subGridPaint = Paint()
      ..color = const Color(0xFF0F141C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.4;

    const double step = 100.0; // 1m
    
    // Draw grid lines
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
      if (snapStep == 0.5 || snapStep == 0.25) {
        canvas.drawLine(Offset(x + step / 2, 0), Offset(x + step / 2, size.height), subGridPaint);
      }
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      if (snapStep == 0.5 || snapStep == 0.25) {
        canvas.drawLine(Offset(0, y + step / 2), Offset(size.width, y + step / 2), subGridPaint);
      }
    }

    // 2. Draw snapping guidelines
    final guidePaint = Paint()
      ..color = const Color(0xFFCC00FF).withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    
    void drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint) {
      const double dashWidth = 8.0;
      const double dashSpace = 6.0;
      double distance = (p2 - p1).distance;
      if (distance == 0) return;
      Offset direction = (p2 - p1) / distance;
      double currentPos = 0.0;
      while (currentPos < distance) {
        final start = p1 + direction * currentPos;
        double endPos = currentPos + dashWidth;
        if (endPos > distance) endPos = distance;
        final end = p1 + direction * endPos;
        canvas.drawLine(start, end, paint);
        currentPos += dashWidth + dashSpace;
      }
    }

    if (alignX != null) {
      final double xPos = alignX! * 100.0;
      drawDashedLine(canvas, Offset(xPos, 0), Offset(xPos, size.height), guidePaint);
    }
    if (alignY != null) {
      final double yPos = alignY! * 100.0;
      drawDashedLine(canvas, Offset(0, yPos), Offset(size.width, yPos), guidePaint);
    }

    // 3. Draw connections
    final arrowPaint = Paint()
      ..color = const Color(0xFF00FFCC)
      ..style = PaintingStyle.fill;

    for (int i = 0; i < connections.length; i++) {
      final conn = connections[i];
      final String from = conn["from"];
      final String to = conn["to"];
      if (checkpoints.containsKey(from) && checkpoints.containsKey(to)) {
        final double x1 = (checkpoints[from]!["x"] as double) * 100.0;
        final double y1 = (checkpoints[from]!["y"] as double) * 100.0;
        final double x2 = (checkpoints[to]!["x"] as double) * 100.0;
        final double y2 = (checkpoints[to]!["y"] as double) * 100.0;

        final bool isSelectedConn = selectedConnectionIndex == i;
        final currentConnPaint = Paint()
          ..color = isSelectedConn ? const Color(0xFF00FFCC) : const Color(0xFF1E2E43)
          ..strokeWidth = isSelectedConn ? 5.5 : 4.0
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke;

        final p = Path();
        List<dynamic> pathPoints = conn["path"] ?? [];
        
        if (pathPoints.isNotEmpty) {
          p.moveTo((pathPoints[0][0] as double) * 100.0, (pathPoints[0][1] as double) * 100.0);
          for (int idx = 1; idx < pathPoints.length; idx++) {
            p.lineTo((pathPoints[idx][0] as double) * 100.0, (pathPoints[idx][1] as double) * 100.0);
          }
        } else {
          // Fallback L-shaped
          p.moveTo(x1, y1);
          p.lineTo(x2, y1);
          p.lineTo(x2, y2);
          pathPoints = [
            [x1 / 100.0, y1 / 100.0],
            [x2 / 100.0, y1 / 100.0],
            [x2 / 100.0, y2 / 100.0]
          ];
        }
        canvas.drawPath(p, currentConnPaint);

        // Find midpoint of path for arrow and label
        int midIdx = pathPoints.length ~/ 2;
        double midX = (pathPoints[midIdx][0] as double) * 100.0;
        double midY = (pathPoints[midIdx][1] as double) * 100.0;

        double angle = 0.0;
        if (pathPoints.length > 1) {
          int prevIdx = midIdx > 0 ? midIdx - 1 : 0;
          int nextIdx = midIdx < pathPoints.length - 1 ? midIdx + 1 : midIdx;
          double dx = (pathPoints[nextIdx][0] as double) - (pathPoints[prevIdx][0] as double);
          double dy = (pathPoints[nextIdx][1] as double) - (pathPoints[prevIdx][1] as double);
          angle = math.atan2(dy, dx);
        }

        // Draw dynamic heading arrow at midpoint
        const double arrowLength = 10.0;
        const double arrowWidth = 6.0;
        final arrowPath = Path();
        arrowPath.moveTo(arrowLength / 2, 0);
        arrowPath.lineTo(-arrowLength / 2, -arrowWidth);
        arrowPath.lineTo(-arrowLength / 2 + 2, 0);
        arrowPath.lineTo(-arrowLength / 2, arrowWidth);
        arrowPath.close();

        canvas.save();
        canvas.translate(midX, midY);
        canvas.rotate(angle);
        canvas.drawPath(arrowPath, arrowPaint);
        canvas.restore();

        // Draw connection distance label offset perpendicular to the heading direction
        final textSpan = TextSpan(
          text: "${(conn["distance"] as num).toStringAsFixed(1)}m",
          style: const TextStyle(color: Color(0xFF8BA2C0), fontSize: 9, fontFamily: 'monospace', fontWeight: FontWeight.bold),
        );
        final textPainter = TextPainter(
          text: textSpan,
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();

        double perpAngle = angle - math.pi / 2;
        double offsetDist = 14.0;
        double labelX = midX + math.cos(perpAngle) * offsetDist - textPainter.width / 2;
        double labelY = midY + math.sin(perpAngle) * offsetDist - textPainter.height / 2;
        textPainter.paint(canvas, Offset(labelX, labelY));

        // Draw control points drag handles
        if (isSelectedConn &&
            (conn["connection_type"] == "curved" ||
                conn["connection_type"] == "bezier" ||
                conn["connection_type"] == "spline")) {
          final List<dynamic> cps = conn["control_points"] ?? [];
          final handlePaint = Paint()
            ..color = Colors.amber
            ..style = PaintingStyle.fill;
          final handleBorder = Paint()
            ..color = Colors.white
            ..strokeWidth = 1.5
            ..style = PaintingStyle.stroke;
          final linePaint = Paint()
            ..color = Colors.amber.withValues(alpha: 0.4)
            ..strokeWidth = 1.0
            ..style = PaintingStyle.stroke;
          
          for (var cp in cps) {
            final double cpx = (cp[0] as double) * 100.0;
            final double cpy = (cp[1] as double) * 100.0;
            canvas.drawLine(Offset(x1, y1), Offset(cpx, cpy), linePaint);
            canvas.drawLine(Offset(x2, y2), Offset(cpx, cpy), linePaint);
            canvas.drawCircle(Offset(cpx, cpy), 6.0, handlePaint);
            canvas.drawCircle(Offset(cpx, cpy), 6.0, handleBorder);
          }
        }
      }
    }

    // 4. Draw checkpoints
    checkpoints.forEach((id, node) {
      final double cx = (node["x"] as double) * 100.0;
      final double cy = (node["y"] as double) * 100.0;
      final String colorHex = node["color"] ?? "#00FFCC";
      final Color color = Color(int.parse(colorHex.replaceAll("#", "0xFF")));
      
      final bool isSelected = id == selectedNodeId;
      final bool isLinkStart = id == linkStartNodeId;

      final glowPaint = Paint()
        ..color = color.withValues(alpha: isSelected || isLinkStart ? 0.3 : 0.15)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx, cy), isSelected || isLinkStart ? 24 : 16, glowPaint);

      final borderPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSelected || isLinkStart ? 2.5 : 1.5;
      canvas.drawCircle(Offset(cx, cy), isSelected || isLinkStart ? 14 : 10, borderPaint);

      final iconStr = node["iconType"] ?? "general";
      final iconData = _getIconData(iconStr);
      
      final textSpan = TextSpan(
        text: String.fromCharCode(iconData.codePoint),
        style: TextStyle(
          fontSize: 12,
          fontFamily: iconData.fontFamily,
          package: iconData.fontPackage,
          color: color,
        ),
      );
      final iconPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      iconPainter.layout();
      iconPainter.paint(canvas, Offset(cx - iconPainter.width / 2, cy - iconPainter.height / 2));

      final labelSpan = TextSpan(
        text: id,
        style: TextStyle(
          color: Colors.white,
          fontSize: isSelected ? 12 : 10,
          fontFamily: 'monospace',
          fontWeight: FontWeight.bold,
          shadows: [Shadow(color: color, blurRadius: 4)],
        ),
      );
      final labelPainter = TextPainter(
        text: labelSpan,
        textDirection: TextDirection.ltr,
      );
      labelPainter.layout();
      labelPainter.paint(canvas, Offset(cx - labelPainter.width / 2, cy - labelPainter.height - 12));
    });

    // 5. Draw active hover snaps indicator
    if (activeTool == ToolType.addNode && hoverOffset != null) {
      final snapIndicatorPaint = Paint()
        ..color = const Color(0xFF00FFCC).withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawCircle(hoverOffset!, 8, snapIndicatorPaint);
    }

    // 6. Draw live freehand path preview (linkNodes mode)
    if (freehandDragPoints != null && freehandDragPoints!.isNotEmpty) {
      final freehandPaint = Paint()
        ..color = const Color(0xFFFF007F)
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      final path = Path();
      path.moveTo(freehandDragPoints!.first.dx, freehandDragPoints!.first.dy);
      for (int i = 1; i < freehandDragPoints!.length; i++) {
        path.lineTo(freehandDragPoints![i].dx, freehandDragPoints![i].dy);
      }
      canvas.drawPath(path, freehandPaint);
    }

    // 7. Draw live Draw Path tool stroke
    if (activeTool == ToolType.drawPath && drawPathPoints.isNotEmpty) {
      // Glowing stroke trail
      final trailPaint = Paint()
        ..color = const Color(0xFF00E5FF).withValues(alpha: 0.9)
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final trailGlow = Paint()
        ..color = const Color(0xFF00E5FF).withValues(alpha: 0.25)
        ..strokeWidth = 8.0
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;

      final strokePath = Path();
      strokePath.moveTo(drawPathPoints.first.dx, drawPathPoints.first.dy);
      for (int i = 1; i < drawPathPoints.length; i++) {
        strokePath.lineTo(drawPathPoints[i].dx, drawPathPoints[i].dy);
      }
      canvas.drawPath(strokePath, trailGlow);
      canvas.drawPath(strokePath, trailPaint);

      // Draw a pulsing cursor dot at the current position
      if (drawPathCursor != null) {
        canvas.drawCircle(drawPathCursor!, 10.0, Paint()
          ..color = const Color(0xFF00E5FF).withValues(alpha: 0.25)
          ..style = PaintingStyle.fill);
        canvas.drawCircle(drawPathCursor!, 5.0, Paint()
          ..color = const Color(0xFF00E5FF)
          ..style = PaintingStyle.fill);
        canvas.drawCircle(drawPathCursor!, 5.0, Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
      }
    }
  }

  @override
  bool shouldRepaint(covariant DesignerCanvasPainter oldDelegate) {
    return oldDelegate.checkpoints != checkpoints ||
        oldDelegate.connections != connections ||
        oldDelegate.selectedNodeId != selectedNodeId ||
        oldDelegate.linkStartNodeId != linkStartNodeId ||
        oldDelegate.activeTool != activeTool ||
        oldDelegate.snapStep != snapStep ||
        oldDelegate.hoverOffset != hoverOffset ||
        oldDelegate.alignX != alignX ||
        oldDelegate.alignY != alignY ||
        oldDelegate.freehandDragPoints != freehandDragPoints ||
        oldDelegate.drawPathPoints != drawPathPoints ||
        oldDelegate.drawPathCursor != drawPathCursor;
  }
}

