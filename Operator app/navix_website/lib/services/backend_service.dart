import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

class BackendService {
  String baseUrl;
  WebSocketChannel? _wsChannel;
  StreamController<Map<String, dynamic>>? _telemetryStreamController;
  StreamSubscription? _wsSubscription;

  BackendService({this.baseUrl = "http://127.0.0.1:8000"});

  // Configure target FastAPI backend IP address
  void updateBaseUrl(String newIp) {
    if (!newIp.startsWith("http://") && !newIp.startsWith("https://")) {
      baseUrl = "http://$newIp";
    } else {
      baseUrl = newIp;
    }
    // Remove trailing slash if present
    if (baseUrl.endsWith("/")) {
      baseUrl = baseUrl.substring(0, baseUrl.length - 1);
    }
  }

  // 1. Upload Map Image
  Future<Map<String, dynamic>> uploadMap(List<int> fileBytes, String filename) async {
    try {
      final uri = Uri.parse("$baseUrl/api/upload-map");
      final request = http.MultipartRequest("POST", uri);
      
      request.files.add(
        http.MultipartFile.fromBytes(
          "file",
          fileBytes,
          filename: filename,
        ),
      );

      final streamedResponse = await request.send().timeout(const Duration(seconds: 60));
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        try {
          final decoded = json.decode(response.body);
          return {
            "status": "ERROR",
            "message": decoded["detail"] ?? "Server error: ${response.statusCode}",
          };
        } catch (_) {
          return {
            "status": "ERROR",
            "message": "Server returned error: ${response.statusCode}. ${response.body}",
          };
        }
      }
    } catch (e) {
      return {
        "status": "ERROR",
        "message": "Failed to upload map: ${e.toString()}",
      };
    }
  }

  // 2. Plan shortest path route
  Future<Map<String, dynamic>> planPath(String start, String end, {List<String>? intermediates}) async {
    try {
      final uri = Uri.parse("$baseUrl/api/plan-path");
      final response = await http.post(
        uri,
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "start": start,
          "end": end,
          "intermediates": intermediates ?? [],
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        final decoded = json.decode(response.body);
        return {
          "status": "ERROR",
          "message": decoded["detail"] ?? "Server error: ${response.statusCode}",
        };
      }
    } catch (e) {
      return {
        "status": "ERROR",
        "message": "Path planning request failed: ${e.toString()}",
      };
    }
  }

  // 3. Sync the ESP32 IP with the backend health-check loop
  Future<void> setEsp32IpOnBackend(String esp32Ip) async {
    try {
      final uri = Uri.parse("$baseUrl/api/set-esp32-ip");
      await http.post(
        uri,
        headers: {"Content-Type": "application/json"},
        body: json.encode({"ip": esp32Ip}),
      ).timeout(const Duration(seconds: 3));
    } catch (_) {
      // Silently ignore — backend may not be running yet
    }
  }

  // 4. On-demand ESP32 ping (calls backend → backend pings ESP32)
  Future<bool> pingEsp32() async {
    try {
      final uri = Uri.parse("$baseUrl/api/ping-esp32");
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data["connected"] == true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // 3. Connect to WebSocket Telemetry Stream
  Stream<Map<String, dynamic>> connectTelemetryStream() {
    // Close existing connection if open
    disconnectTelemetryStream();

    _telemetryStreamController = StreamController<Map<String, dynamic>>.broadcast();

    // Map http://... or https://... to ws://... or wss://...
    String wsUrl = baseUrl.replaceAll("http://", "ws://").replaceAll("https://", "wss://");
    final wsUri = Uri.parse("$wsUrl/ws/telemetry");

    try {
      _wsChannel = WebSocketChannel.connect(wsUri);
      
      _wsSubscription = _wsChannel!.stream.listen(
        (message) {
          try {
            final Map<String, dynamic> data = json.decode(message);
            if (!_telemetryStreamController!.isClosed) {
              _telemetryStreamController!.add(data);
            }
          } catch (e) {
            // Ignore parse errors on ping/pong or bad frames
          }
        },
        onError: (error) {
          if (!_telemetryStreamController!.isClosed) {
            _telemetryStreamController!.addError(error);
          }
        },
        onDone: () {
          if (!_telemetryStreamController!.isClosed) {
            _telemetryStreamController!.close();
          }
        },
      );
    } catch (e) {
      if (!_telemetryStreamController!.isClosed) {
        _telemetryStreamController!.addError(e);
      }
    }

    return _telemetryStreamController!.stream;
  }

  // 4. Disconnect WebSocket Connection
  void disconnectTelemetryStream() {
    _wsSubscription?.cancel();
    _wsSubscription = null;
    
    // Close ws channel gracefully
    _wsChannel?.sink.close();
    _wsChannel = null;

    if (_telemetryStreamController != null && !_telemetryStreamController!.isClosed) {
      _telemetryStreamController!.close();
    }
    _telemetryStreamController = null;
  }

  // 5. Update robot's current position to a selected checkpoint on the backend
  Future<bool> setRobotPosition(String checkpoint) async {
    try {
      final uri = Uri.parse("$baseUrl/api/set-robot-position");
      final response = await http.post(
        uri,
        headers: {"Content-Type": "application/json"},
        body: json.encode({"checkpoint": checkpoint}),
      ).timeout(const Duration(seconds: 3));
      
      if (response.statusCode == 200) {
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // 6. Send WebSocket message (e.g. Ping)
  void sendWsMessage(Map<String, dynamic> msg) {
    if (_wsChannel != null) {
      _wsChannel!.sink.add(json.encode(msg));
    }
  }

  // ── Custom Map Persistence Methods ──────────────────────────────────────────

  // Fetch all custom maps metadata
  Future<Map<String, dynamic>> fetchCustomMaps() async {
    try {
      final uri = Uri.parse("$baseUrl/api/maps");
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return {"maps": []};
    } catch (e) {
      return {"maps": [], "error": e.toString()};
    }
  }

  // Fetch full details of a custom map JSON
  Future<Map<String, dynamic>> fetchCustomMapDetail(String fileName) async {
    try {
      final uri = Uri.parse("$baseUrl/api/maps/$fileName");
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return {};
    } catch (e) {
      return {"error": e.toString()};
    }
  }

  // Save a custom map to backend maps directory
  Future<Map<String, dynamic>> saveCustomMap(String mapName, Map<String, dynamic> mapData) async {
    try {
      final uri = Uri.parse("$baseUrl/api/maps");
      final response = await http.post(
        uri,
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "map_name": mapName,
          "checkpoints": mapData["checkpoints"] ?? {},
          "connections": mapData["connections"] ?? [],
          "unit": mapData["unit"] ?? "meters"
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return {
        "status": "ERROR",
        "message": "Failed to save map. Status code: ${response.statusCode}"
      };
    } catch (e) {
      return {
        "status": "ERROR",
        "message": "Failed to save map: ${e.toString()}"
      };
    }
  }

  // Delete a custom map from backend disk
  Future<Map<String, dynamic>> deleteCustomMap(String fileName) async {
    try {
      final uri = Uri.parse("$baseUrl/api/maps/$fileName");
      final response = await http.delete(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      return {
        "status": "ERROR",
        "message": "Failed to delete map. Status code: ${response.statusCode}"
      };
    } catch (e) {
      return {
        "status": "ERROR",
        "message": "Failed to delete map: ${e.toString()}"
      };
    }
  }

  // Select custom map as active console map
  Future<Map<String, dynamic>> selectCustomMap(Map<String, dynamic> mapData) async {
    try {
      final uri = Uri.parse("$baseUrl/api/select-map");
      final response = await http.post(
        uri,
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "map_name": mapData["map_name"] ?? "Manually Designed Map",
          "checkpoints": mapData["checkpoints"] ?? {},
          "connections": mapData["connections"] ?? [],
          "unit": mapData["unit"] ?? "meters"
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      final decoded = json.decode(response.body);
      return {
        "status": "ERROR",
        "message": decoded["detail"] ?? "Failed to select map. Status code: ${response.statusCode}"
      };
    } catch (e) {
      return {
        "status": "ERROR",
        "message": "Failed to select map: ${e.toString()}"
      };
    }
  }

  // 7. Open delivery ramp
  Future<bool> openRamp() async {
    try {
      final uri = Uri.parse("$baseUrl/api/open-ramp");
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data["status"] == "SUCCESS";
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // 8. Close delivery ramp
  Future<bool> closeRamp() async {
    try {
      final uri = Uri.parse("$baseUrl/api/close-ramp");
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data["status"] == "SUCCESS";
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // 9. Reset active mission state
  Future<bool> resetMission() async {
    try {
      final uri = Uri.parse("$baseUrl/api/reset-mission");
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data["status"] == "SUCCESS";
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // 10. Update obstacle avoidance settings on backend
  Future<bool> updateAvoidanceSettings({
    required bool enabled,
    required double avoidanceAngle,
    required double clearanceDistance,
    required double verificationDistance,
    required double maxAvoidanceAngle,
  }) async {
    try {
      final uri = Uri.parse("$baseUrl/api/update-avoidance-settings");
      final response = await http.post(
        uri,
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "enabled": enabled,
          "avoidance_angle": avoidanceAngle,
          "clearance_distance": clearanceDistance,
          "verification_distance": verificationDistance,
          "max_avoidance_angle": maxAvoidanceAngle,
        }),
      ).timeout(const Duration(seconds: 4));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data["status"] == "SUCCESS";
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // 11. Update Pure Pursuit settings on backend
  Future<bool> updatePurePursuitSettings({
    required bool enabled,
    required double lookAheadDistance,
    required double maxSteeringCorrection,
    required double trajectoryResolution,
    required int curveResolution,
  }) async {
    try {
      final uri = Uri.parse("$baseUrl/api/update-pure-pursuit-settings");
      final response = await http.post(
        uri,
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "enabled": enabled,
          "look_ahead_distance": lookAheadDistance,
          "max_steering_correction": maxSteeringCorrection,
          "trajectory_resolution": trajectoryResolution,
          "curve_resolution": curveResolution,
        }),
      ).timeout(const Duration(seconds: 4));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data["status"] == "SUCCESS";
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // 12. Start Free Roam autonomous wandering mode
  Future<bool> startFreeRoam() async {
    try {
      final uri = Uri.parse("$baseUrl/api/free-roam/start");
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data["status"] == "SUCCESS";
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // 13. Stop Free Roam mode
  Future<bool> stopFreeRoam() async {
    try {
      final uri = Uri.parse("$baseUrl/api/free-roam/stop");
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data["status"] == "SUCCESS";
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}
