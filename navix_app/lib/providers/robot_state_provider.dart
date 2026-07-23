import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:navix_app/services/backend_service.dart';
import 'package:navix_app/services/robot_controller_service.dart';
import 'package:navix_app/widgets/toast_manager.dart';

class LogEntry {
  final String timestamp;
  final String message;

  LogEntry({required this.timestamp, required this.message});
}


/// Model representing a fully analyzed occupancy-grid map that was uploaded.
class LoadedMap {
  final String fileName;
  final List<int> imageBytes;
  final Map<String, dynamic> checkpoints;
  final Map<String, dynamic> metricCheckpoints;
  final List<dynamic> connections;
  final String detectedUnit;
  final DateTime uploadedAt;

  LoadedMap({
    required this.fileName,
    required this.imageBytes,
    required this.checkpoints,
    required this.metricCheckpoints,
    required this.connections,
    required this.detectedUnit,
    required this.uploadedAt,
  });
}

class RobotStateProvider extends ChangeNotifier {
  // Service Instances
  final RobotControllerService _robotController = RobotControllerService();
  final BackendService _backendService = BackendService();

  // Settings / IP configuration
  String _esp32Ip = "192.168.4.1";
  String _backendIp = "127.0.0.1:8000";
  double _calibrationOffset = 0.0;
  int _tunedSpeed = 128;
  bool _isDarkTheme = true;

  // Connection State
  bool _aiBackendConnected = false;
  bool _esp32Connected = false;
  StreamSubscription? _telemetrySubscription;
  String _connectionError = "";

  // Map state
  bool _mapLoaded = false;
  Map<String, dynamic> _checkpoints = {};
  Map<String, dynamic> _metricCheckpoints = {};
  List<dynamic> _connections = [];
  String _imageUrl = "";
  List<int>? _mapImageBytes;
  String? _mapFileName;
  String _detectedUnit = "m";

  // Multi-map history (stored locally in Flutter)
  final List<LoadedMap> _loadedMaps = [];

  // Custom Map Designer state
  List<Map<String, dynamic>> _customMapsList = [];
  bool _isCustomMapActive = false;
  String? _activeCustomMapName;

  // Mission state
  String _sourceCheckpoint = "";
  String _destinationCheckpoint = "";
  List<String> _intermediateCheckpoints = [];
  List<String> _calculatedPath = [];
  List<List<double>> _calculatedCoordinates = [];
  double _estimatedDistance = 0.0;
  double _estimatedTime = 0.0;
  String _routeInsights = "";
  String _deliveryIntelligence = "";
  int _turnsCount = 0;
  bool _isPlanning = false;
  String _missionStatus = "NO ACTIVE MISSION"; // NO ACTIVE MISSION, PLANNED, RUNNING, PAUSED, COMPLETED

  // Live Telemetry variables (mocked/streamed)
  String _robotStatus = "IDLE";
  String _robotMode = "auto";
  String _currentCheckpoint = "";
  String _nextCheckpoint = "";
  String _activeCommand = "STOP";
  int _robotSpeed = 128;
  double _missionProgress = 0.0;
  double _robotX = 100.0;
  double _robotY = 100.0;
  double _robotHeading = 0.0;
  String _lastApiResponse = "READY";
  String? _alertMessage;

  // Delivery Ramp State
  bool _deliveryComplete = false;
  bool _rampDeployed = false;
  String _rampStatus = "CLOSED";

  // Cyberpunk HUD Telemetry
  double _battery = 100.0;
  int _pwmLeft = 0;
  int _pwmRight = 0;
  double _gyroZ = 0.0;
  double _distanceSensor = 150.0;

  // PID and Logging State Telemetry
  double _yaw = 0.0;
  double _targetYaw = 0.0;
  double _yawError = 0.0;
  double _pidOutput = 0.0;
  final List<LogEntry> _missionLogs = [];

  // Obstacle avoidance settings & status variables
  bool _obstacleAvoidanceEnabled = true;
  double _avoidanceAngle = 5.0;
  double _clearanceDistance = 40.0;
  double _verificationDistance = 15.0;
  double _maxAvoidanceAngle = 45.0;
  String _obstacleAvoidanceStatus = "NORMAL";
  double _currentAvoidanceAngle = 0.0;
  double _originalHeading = 0.0;
  double _clearanceRemaining = 0.0;
  String _eventLog = "";

  // Pure Pursuit settings & status variables
  bool _purePursuitEnabled = true;
  double _lookAheadDistance = 0.25;
  double _maxSteeringCorrection = 30.0;
  double _trajectoryResolution = 0.05;
  int _curveResolution = 30;

  Map<String, dynamic> _lookAheadPoint = {"x": 0.0, "y": 0.0};
  double _desiredHeading = 0.0;
  double _headingError = 0.0;
  double _crossTrackError = 0.0;
  double _trajectoryProgress = 0.0;
  double _curveRadius = 999.0;
  String _purePursuitStatus = "INACTIVE";

  // LDE (Local Decision Engine) live state
  String _ldeState    = "IDLE";  // IDLE, MOVING, LDE_ASSESS, LDE_TURN, LDE_BYPASS, LDE_REVERSE, LDE_TURN_BACK, FAILED
  int    _ldeAttempts = 0;       // Current avoidance attempt count
  String _esp32Mode   = "auto";  // Actual mode on the ESP32 (mission, auto, manual)
  String? _prevLdeState;

  // Previous state trackers for logging transitions
  String? _prevStatus;
  String? _prevCommand;
  bool _prevObstacleDetected = false;
  String? _prevRampStatus;
  double? _prevYaw;
  String? _prevObstacleAvoidanceStatus;

  // Free Roam state
  bool _freeRoamActive = false;
  String _freeRoamState = "IDLE"; // IDLE, MOVING, BACKING, TURNING



  // Getters
  String get esp32Ip => _esp32Ip;
  String get backendIp => _backendIp;
  double get calibrationOffset => _calibrationOffset;
  int get tunedSpeed => _tunedSpeed;
  bool get isDarkTheme => _isDarkTheme;

  bool get aiBackendConnected => _aiBackendConnected;
  bool get esp32Connected => _esp32Connected;
  String get connectionError => _connectionError;

  bool get mapLoaded => _mapLoaded;
  Map<String, dynamic> get checkpoints => _checkpoints;
  Map<String, dynamic> get metricCheckpoints => _metricCheckpoints;
  List<dynamic> get connections => _connections;
  String get imageUrl => _imageUrl;
  List<int>? get mapImageBytes => _mapImageBytes;
  String? get mapFileName => _mapFileName;
  String get detectedUnit => _detectedUnit;
  List<LoadedMap> get loadedMaps => List.unmodifiable(_loadedMaps);
  List<Map<String, dynamic>> get customMapsList => _customMapsList;
  bool get isCustomMapActive => _isCustomMapActive;
  String? get activeCustomMapName => _activeCustomMapName;

  String get sourceCheckpoint => _sourceCheckpoint;
  String get destinationCheckpoint => _destinationCheckpoint;
  List<String> get intermediateCheckpoints => _intermediateCheckpoints;
  List<String> get calculatedPath => _calculatedPath;
  double get estimatedDistance => _estimatedDistance;
  double get estimatedTime => _estimatedTime;
  String get routeInsights => _routeInsights;
  String get deliveryIntelligence => _deliveryIntelligence;
  int get turnsCount => _turnsCount;
  bool get isPlanning => _isPlanning;
  String get missionStatus => _missionStatus;

  String get robotStatus => _robotStatus;
  String get robotMode => _robotMode;
  String get currentCheckpoint => _currentCheckpoint;
  String get nextCheckpoint => _nextCheckpoint;
  String get activeCommand => _activeCommand;
  int get robotSpeed => _robotSpeed;
  double get missionProgress => _missionProgress;
  double get robotX => _robotX;
  double get robotY => _robotY;
  double get robotHeading => _robotHeading;
  String get lastApiResponse => _lastApiResponse;
  String? get alertMessage => _alertMessage;

  bool get deliveryComplete => _deliveryComplete;
  bool get rampDeployed => _rampDeployed;
  String get rampStatus => _rampStatus;

  double get battery => _battery;
  int get pwmLeft => _pwmLeft;
  int get pwmRight => _pwmRight;
  double get gyroZ => _gyroZ;
  double get distanceSensor => _distanceSensor;
  List<List<double>> get calculatedCoordinates => _calculatedCoordinates;

  double get yaw => _yaw;
  double get targetYaw => _targetYaw;
  double get yawError => _yawError;
  double get pidOutput => _pidOutput;
  List<LogEntry> get missionLogs => List.unmodifiable(_missionLogs);

  // Obstacle avoidance getters
  bool get obstacleAvoidanceEnabled => _obstacleAvoidanceEnabled;
  double get avoidanceAngle => _avoidanceAngle;
  double get clearanceDistance => _clearanceDistance;
  double get verificationDistance => _verificationDistance;
  double get maxAvoidanceAngle => _maxAvoidanceAngle;
  String get obstacleAvoidanceStatus => _obstacleAvoidanceStatus;
  double get currentAvoidanceAngle => _currentAvoidanceAngle;
  double get originalHeading => _originalHeading;
  double get clearanceRemaining => _clearanceRemaining;
  String get eventLog => _eventLog;

  // Pure Pursuit Getters
  bool get purePursuitEnabled => _purePursuitEnabled;
  double get lookAheadDistance => _lookAheadDistance;
  double get maxSteeringCorrection => _maxSteeringCorrection;
  double get trajectoryResolution => _trajectoryResolution;
  int get curveResolution => _curveResolution;

  Map<String, dynamic> get lookAheadPoint => _lookAheadPoint;
  double get desiredHeading => _desiredHeading;
  double get headingError => _headingError;
  double get crossTrackError => _crossTrackError;
  double get trajectoryProgress => _trajectoryProgress;
  double get curveRadius => _curveRadius;
  String get purePursuitStatus => _purePursuitStatus;

  // LDE getters
  String get ldeState    => _ldeState;
  int    get ldeAttempts => _ldeAttempts;
  String get esp32Mode   => _esp32Mode;
  bool   get isLdeActive => _esp32Mode == "mission" && _ldeState != "IDLE" && _ldeState != "MOVING";

  // Free Roam getters
  bool get freeRoamActive => _freeRoamActive;
  String get freeRoamState => _freeRoamState;



  RobotStateProvider() {
    // Sync services with default IPs
    _robotController.updateBaseUrl(_backendIp);
    _backendService.updateBaseUrl(_backendIp);
    
    // Connect websocket telemetry stream automatically (silently – no error popup on first attempt)
    connectTelemetry(silent: true);

    // Tell backend which ESP32 IP to use for health checks
    _backendService.setEsp32IpOnBackend(_esp32Ip);

    // Sync default speed limit to backend
    adjustSpeed(_tunedSpeed);
  }

  // Update configuration parameters from settings
  void updateSettings({
    required String esp32Ip,
    required String backendIp,
    required double calibrationOffset,
    required int tunedSpeed,
    required bool isDarkTheme,
  }) {
    _esp32Ip = esp32Ip;
    _backendIp = backendIp;
    _calibrationOffset = calibrationOffset;
    _tunedSpeed = tunedSpeed;
    _isDarkTheme = isDarkTheme;

    _robotController.updateBaseUrl(_backendIp);
    _backendService.updateBaseUrl(_backendIp);

    // Notify backend of the new ESP32 IP for its health-check loop
    _backendService.setEsp32IpOnBackend(_esp32Ip);

    // Sync newly tuned speed limit to backend
    adjustSpeed(tunedSpeed);

    notifyListeners();
    
    // Reconnect telemetry under new backend IP
    connectTelemetry();
  }

  /// On-demand ESP32 ping — shows the user immediately if the bot is reachable.
  Future<void> pingEsp32() async {
    _alertMessage = null;
    notifyListeners();
    final connected = await _backendService.pingEsp32();
    if (connected) {
      _esp32Connected = true;
      setAlert("ESP32 ONLINE — Robot is reachable and ready!");
    } else {
      _esp32Connected = false;
      setAlert("ESP32 OFFLINE — Make sure your device is connected to the robot's WiFi hotspot (IP: $_esp32Ip).");
    }
    notifyListeners();
  }

  // Clear visual alert popup message
  void clearAlert() {
    _alertMessage = null;
    notifyListeners();
  }

  // Set visual alert popup message
  void setAlert(String message) {
    _alertMessage = message;
    ToastType type = ToastType.info;
    final msgLower = message.toLowerCase();
    if (msgLower.contains("emergency") || msgLower.contains("failed") || msgLower.contains("critical") || msgLower.contains("offline") || msgLower.contains("not reachable")) {
      type = ToastType.critical;
    } else if (msgLower.contains("warn") || msgLower.contains("paused") || msgLower.contains("stuck")) {
      type = ToastType.warning;
    }
    ToastManager.show(message, type: type);
    notifyListeners();
  }

  void addLog(String message) {
    final now = DateTime.now();
    final timeStr = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
    _missionLogs.add(LogEntry(timestamp: timeStr, message: message));
    if (_missionLogs.length > 100) {
      _missionLogs.removeAt(0);
    }
  }

  void clearLogs() {
    _missionLogs.clear();
  }

  // ── WebSocket reconnection state ─────────────────────────────────────────
  bool _wasEverConnected = false;  // true once first telemetry frame received
  int _wsReconnectDelaySec = 2;   // grows with each failed attempt (max 30s)
  bool _wsReconnecting = false;

  // Connect to WebSocket telemetry
  void connectTelemetry({bool silent = false}) {
    _telemetrySubscription?.cancel();
    _backendService.disconnectTelemetryStream();
    _wsReconnecting = false;
    
    final telemetryStream = _backendService.connectTelemetryStream();
    
    _telemetrySubscription = telemetryStream.listen(
      (data) {
        if (!_wasEverConnected) {
          // First successful frame — reset backoff
          _wasEverConnected = true;
          _wsReconnectDelaySec = 2;
        }
        _aiBackendConnected = true;
        _connectionError = "";
        
        // Parse incoming telemetry JSON
        _esp32Connected = data["esp32_connected"] ?? false;
        _robotStatus = data["robot_status"] ?? "IDLE";
        // Only trust telemetry mode if we're not in the middle of a mode switch
        if (!_isModeChanging) {
          _robotMode = data["mode"] ?? "auto";
        }
        _currentCheckpoint = data["current_checkpoint"] ?? "";
        _nextCheckpoint = data["next_checkpoint"] ?? "";
        _activeCommand = data["command"] ?? "STOP";
        _robotSpeed = data["speed"] ?? 128;
        _missionProgress = (data["progress"] as num?)?.toDouble() ?? 0.0;
        _robotX = (data["x"] as num?)?.toDouble() ?? 100.0;
        _robotY = (data["y"] as num?)?.toDouble() ?? 100.0;
        _robotHeading = (data["heading"] as num?)?.toDouble() ?? 0.0;
        _lastApiResponse = data["last_api_response"] ?? "";
        _routeInsights = data["route_insights"] ?? _routeInsights;
        _deliveryIntelligence = data["delivery_intelligence"] ?? _deliveryIntelligence;
        _deliveryComplete = data["delivery_complete"] ?? false;
        _rampDeployed = data["ramp_deployed"] ?? false;
        _rampStatus = data["ramp_status"] ?? "CLOSED";

        // Cyberpunk HUD details
        _battery = (data["battery"] as num?)?.toDouble() ?? 100.0;
        _pwmLeft = (data["pwm_left"] as num?)?.toInt() ?? 0;
        _pwmRight = (data["pwm_right"] as num?)?.toInt() ?? 0;
        _gyroZ = (data["gyro_z"] as num?)?.toDouble() ?? 0.0;
        _distanceSensor = (data["distance"] as num?)?.toDouble() ?? 150.0;

        // Parse new telemetry fields
        _yaw = (data["yaw"] as num?)?.toDouble() ?? 0.0;
        _targetYaw = (data["target_yaw"] as num?)?.toDouble() ?? 0.0;
        _yawError = (data["yaw_error"] as num?)?.toDouble() ?? 0.0;
        _pidOutput = (data["pid_output"] as num?)?.toDouble() ?? 0.0;

        // Parse obstacle avoidance telemetry
        _obstacleAvoidanceEnabled = data["obstacle_avoidance_enabled"] ?? _obstacleAvoidanceEnabled;
        _avoidanceAngle = (data["avoidance_angle"] as num?)?.toDouble() ?? _avoidanceAngle;
        _clearanceDistance = (data["clearance_distance"] as num?)?.toDouble() ?? _clearanceDistance;
        _verificationDistance = (data["verification_distance"] as num?)?.toDouble() ?? _verificationDistance;
        _maxAvoidanceAngle = (data["max_avoidance_angle"] as num?)?.toDouble() ?? _maxAvoidanceAngle;
        _obstacleAvoidanceStatus = data["obstacle_avoidance_status"] ?? _obstacleAvoidanceStatus;
        _currentAvoidanceAngle = (data["current_avoidance_angle"] as num?)?.toDouble() ?? _currentAvoidanceAngle;
        _originalHeading = (data["original_heading"] as num?)?.toDouble() ?? _originalHeading;
        _clearanceRemaining = (data["clearance_remaining"] as num?)?.toDouble() ?? _clearanceRemaining;
        _eventLog = data["event_log"] ?? _eventLog;

        // Parse LDE telemetry from backend (sourced from ESP32 /status)
        _ldeState    = data["lde_state"]    ?? _ldeState;
        _ldeAttempts = (data["lde_attempts"] as num?)?.toInt() ?? _ldeAttempts;
        _esp32Mode   = data["esp32_mode"]   ?? _esp32Mode;

        // Parse Pure Pursuit telemetry
        _purePursuitEnabled = data["pure_pursuit_enabled"] ?? _purePursuitEnabled;
        _lookAheadDistance = (data["look_ahead_distance"] as num?)?.toDouble() ?? _lookAheadDistance;
        _maxSteeringCorrection = (data["max_steering_correction"] as num?)?.toDouble() ?? _maxSteeringCorrection;
        _trajectoryResolution = (data["trajectory_resolution"] as num?)?.toDouble() ?? _trajectoryResolution;
        _curveResolution = (data["curve_resolution"] as num?)?.toInt() ?? _curveResolution;
        _lookAheadPoint = data["look_ahead_point"] ?? _lookAheadPoint;
        _desiredHeading = (data["desired_heading"] as num?)?.toDouble() ?? _desiredHeading;
        _headingError = (data["heading_error"] as num?)?.toDouble() ?? _headingError;
        _crossTrackError = (data["cross_track_error"] as num?)?.toDouble() ?? _crossTrackError;
        _trajectoryProgress = (data["trajectory_progress"] as num?)?.toDouble() ?? _trajectoryProgress;
        _curveRadius = (data["curve_radius"] as num?)?.toDouble() ?? _curveRadius;
        _purePursuitStatus = data["pure_pursuit_status"] ?? _purePursuitStatus;

        // Parse Free Roam telemetry
        _freeRoamActive = data["free_roam_active"] ?? _freeRoamActive;
        _freeRoamState  = data["free_roam_state"]  ?? _freeRoamState;

        // If automatic mission finishes, update status
        if ((_robotMode == "auto" && _robotStatus == "STOPPED" && _missionProgress >= 100.0 && _missionStatus == "RUNNING") || _deliveryComplete) {
          if (_missionStatus != "COMPLETED") {
            _missionStatus = "COMPLETED";
            setAlert("SUCCESS: Autonomous mission completed!");
          }
        }

        // Live logs check
        final bool isRunning = _missionStatus == "RUNNING";

        if (_missionStatus != _prevStatus) {
          if (_missionStatus == "RUNNING") {
            _missionLogs.clear();
            addLog("Mission Started");
          } else if (_missionStatus == "COMPLETED") {
            addLog("Destination Reached");
            addLog("Opening Ramp");
          } else if (_missionStatus == "PAUSED" && _prevStatus == "RUNNING") {
            addLog("Mission Paused");
          }
        }

        if (isRunning && _activeCommand != _prevCommand) {
          if (_activeCommand == "FORWARD") {
            addLog("Heading Straight");
          } else if (_activeCommand == "LEFT") {
            addLog("Turning Left");
            addLog("Target Angle ${_targetYaw.toStringAsFixed(0)}°");
          } else if (_activeCommand == "RIGHT") {
            addLog("Turning Right");
            addLog("Target Angle ${_targetYaw.toStringAsFixed(0)}°");
          } else if (_activeCommand == "STOP" && !_prevObstacleDetected) {
            addLog("Robot Stopped");
          }
        }

        final bool obstacleDetected = _distanceSensor <= 20.0;
        if (isRunning) {
          if (_obstacleAvoidanceEnabled) {
            if (_obstacleAvoidanceStatus != _prevObstacleAvoidanceStatus) {
              if (_obstacleAvoidanceStatus == "STOPPING") {
                addLog("Obstacle Detected (${_distanceSensor.toStringAsFixed(0)} cm)");
                addLog("Robot Stopped");
              } else if (_obstacleAvoidanceStatus == "ROTATING") {
                addLog("Bypass started: rotating left by ${_avoidanceAngle.toStringAsFixed(0)}° (Accumulated: ${_currentAvoidanceAngle.toStringAsFixed(0)}°)");
              } else if (_obstacleAvoidanceStatus == "CLEARANCE") {
                addLog("Path clear at ${_currentAvoidanceAngle.toStringAsFixed(0)}°. Moving forward for clearance (${_clearanceDistance.toStringAsFixed(0)} cm)");
              } else if (_obstacleAvoidanceStatus == "RETURNING") {
                addLog("Clearance reached. Returning to original heading (rotating right ${_currentAvoidanceAngle.toStringAsFixed(0)}°)");
              } else if (_obstacleAvoidanceStatus == "VERIFYING") {
                addLog("Heading aligned. Verifying path clearance (${_verificationDistance.toStringAsFixed(0)} cm)");
              } else if (_obstacleAvoidanceStatus == "FAILED") {
                addLog("Avoidance failed: angle exceeds ${_maxAvoidanceAngle.toStringAsFixed(0)}°");
                addLog("Mission Paused: Manual assistance required");
                setAlert("ERROR: Obstacle Too Large / Manual Assistance Required");
              } else if (_obstacleAvoidanceStatus == "NORMAL") {
                if (_prevObstacleAvoidanceStatus == "VERIFYING") {
                  addLog("Path verified. Bypass completed successfully.");
                  addLog("Resuming route.");
                }
              }
            }
          } else {
            if (obstacleDetected != _prevObstacleDetected) {
              if (obstacleDetected) {
                addLog("Obstacle Detected (${_distanceSensor.toStringAsFixed(0)} cm)");
                addLog("Robot Stopped");
              } else {
                addLog("Obstacle Cleared");
                addLog("Resuming Mission");
              }
            }
          }
        }

        if (isRunning && (_activeCommand == "LEFT" || _activeCommand == "RIGHT")) {
          if (_prevYaw == null || (_yaw - _prevYaw!).abs() >= 15.0) {
            addLog("Current Angle ${_yaw.toStringAsFixed(0)}°");
          }
        }

        if (isRunning && (_prevCommand == "LEFT" || _prevCommand == "RIGHT") && (_activeCommand == "FORWARD" || _activeCommand == "STOP")) {
          addLog("Turn Completed");
        }

        if (_rampStatus != _prevRampStatus) {
          if (_rampStatus == "OPENING") {
            if (_missionLogs.isEmpty || _missionLogs.last.message != "Opening Ramp") {
              addLog("Opening Ramp");
            }
          } else if (_rampStatus == "OPEN") {
            addLog("Ramp Open");
            addLog("Package Delivered");
          } else if (_rampStatus == "CLOSING") {
            addLog("Closing Ramp");
          } else if (_rampStatus == "CLOSED") {
            addLog("Ramp Closed");
            addLog("Mission Completed");
          }
        }

        // LDE phase transition logging (mission mode)
        if (_esp32Mode == "mission" && _ldeState != _prevLdeState) {
          switch (_ldeState) {
            case "LDE_ASSESS":
              addLog("⚡ Obstacle detected — LDE engaged");
              break;
            case "LDE_TURN":
              addLog("↩ LDE: Avoidance turn (attempt $_ldeAttempts)");
              break;
            case "LDE_BYPASS":
              addLog("⏩ LDE: Bypassing obstacle...");
              break;
            case "LDE_TURN_BACK":
              addLog("↪ LDE: Turning back to original heading");
              break;
            case "LDE_REVERSE":
              addLog("⬅ LDE: Reversing to retry");
              break;
            case "MOVING":
              if (_prevLdeState != null && _prevLdeState != "IDLE") {
                addLog("✅ LDE: Avoidance complete — mission resumed!");
              }
              break;
            case "FAILED":
              addLog("🚫 LDE: Recovery FAILED — operator required");
              setAlert("ERROR: LDE avoidance exhausted — operator intervention required!");
              break;
          }
          _prevLdeState = _ldeState;
        }

        // Store previous state trackers
        _prevStatus = _missionStatus;
        _prevCommand = _activeCommand;
        _prevObstacleDetected = obstacleDetected;
        _prevRampStatus = _rampStatus;
        _prevYaw = _yaw;
        _prevObstacleAvoidanceStatus = _obstacleAvoidanceStatus;

        notifyListeners();
      },
      onError: (err) {
        _aiBackendConnected = false;
        _connectionError = "WebSocket connection failed: ${err.toString()}";
        // Only alert the user if they previously had a live connection
        if (_wasEverConnected && !silent) {
          ToastManager.show("Backend connection lost — reconnecting…", type: ToastType.warning);
        }
        notifyListeners();
        _scheduleWsReconnect(silent: false);
      },
      onDone: () {
        _aiBackendConnected = false;
        notifyListeners();
        _scheduleWsReconnect(silent: !_wasEverConnected);
      }
    );
  }

  // Silent exponential-backoff reconnect scheduler
  void _scheduleWsReconnect({bool silent = false}) {
    if (_wsReconnecting) return;
    _wsReconnecting = true;
    Future.delayed(Duration(seconds: _wsReconnectDelaySec), () {
      // Increase delay up to 30 s
      _wsReconnectDelaySec = (_wsReconnectDelaySec * 2).clamp(2, 30);
      connectTelemetry(silent: silent);
    });
  }

  // Upload Occupancy Map to Backend
  Future<bool> uploadOccupancyMap(List<int> bytes, String fileName, {bool makeActive = false}) async {
    _isPlanning = true;
    notifyListeners();

    final result = await _backendService.uploadMap(bytes, fileName);
    _isPlanning = false;

    if (result["status"] == "SUCCESS") {
      final parsedCheckpoints = Map<String, dynamic>.from(result["checkpoints"] ?? {});
      final parsedMetricCheckpoints = Map<String, dynamic>.from(result["metric_checkpoints"] ?? {});
      final parsedConnections = List<dynamic>.from(result["connections"] ?? []);
      final parsedUnit = result["detected_unit"] ?? "m";

      if (makeActive) {
        _mapLoaded = true;
        _mapImageBytes = bytes;
        _mapFileName = fileName;
        _imageUrl = "${_backendService.baseUrl}${result["image_url"]}";
        _checkpoints = parsedCheckpoints;
        _metricCheckpoints = parsedMetricCheckpoints;
        _connections = parsedConnections;
        _detectedUnit = parsedUnit;
        
        // Clear path
        _intermediateCheckpoints = [];
        _calculatedPath = [];
        _calculatedCoordinates = [];
        _estimatedDistance = 0.0;
        _estimatedTime = 0.0;
        _missionStatus = "NO ACTIVE MISSION";

        if (_metricCheckpoints.isNotEmpty) {
          _sourceCheckpoint = _metricCheckpoints.keys.first;
          _destinationCheckpoint = _metricCheckpoints.keys.last;
          _robotX = _metricCheckpoints[_sourceCheckpoint]["x"]?.toDouble() ?? _robotX;
          _robotY = _metricCheckpoints[_sourceCheckpoint]["y"]?.toDouble() ?? _robotY;
          _currentCheckpoint = _sourceCheckpoint;
        }
      }

      // Add to the loaded-maps history (avoid duplicates by fileName)
      _loadedMaps.removeWhere((m) => m.fileName == fileName);
      _loadedMaps.add(LoadedMap(
        fileName: fileName,
        imageBytes: bytes,
        checkpoints: parsedCheckpoints,
        metricCheckpoints: parsedMetricCheckpoints,
        connections: parsedConnections,
        detectedUnit: parsedUnit,
        uploadedAt: DateTime.now(),
      ));

      notifyListeners();
      return true;
    } else {
      _alertMessage = "Map Analysis Failed: ${result["message"]}";
      notifyListeners();
      return false;
    }
  }

  /// Restore a previously uploaded map from local history.
  Future<void> selectMap(LoadedMap map) async {
    _mapLoaded = true;
    _mapImageBytes = map.imageBytes;
    _mapFileName = map.fileName;
    _checkpoints = Map<String, dynamic>.from(map.checkpoints);
    _metricCheckpoints = Map<String, dynamic>.from(map.metricCheckpoints);
    _connections = List<dynamic>.from(map.connections);
    _detectedUnit = map.detectedUnit;

    // Reset mission state for fresh planning on the new map
    _intermediateCheckpoints = [];
    _calculatedPath = [];
    _calculatedCoordinates = [];
    _estimatedDistance = 0.0;
    _estimatedTime = 0.0;
    _missionStatus = "NO ACTIVE MISSION";

    if (_metricCheckpoints.isNotEmpty) {
      _sourceCheckpoint = _metricCheckpoints.keys.first;
      _destinationCheckpoint = _metricCheckpoints.keys.last;
      _robotX = _metricCheckpoints[_sourceCheckpoint]["x"]?.toDouble() ?? _robotX;
      _robotY = _metricCheckpoints[_sourceCheckpoint]["y"]?.toDouble() ?? _robotY;
      _currentCheckpoint = _sourceCheckpoint;
    }

    if (map.imageBytes.isEmpty) {
      // It's a custom designer map! Call selectCustomMap active on backend
      _isCustomMapActive = true;
      _activeCustomMapName = map.fileName.replaceAll(".json", "").toUpperCase();
      final mapData = {
        "map_name": _activeCustomMapName,
        "checkpoints": map.checkpoints,
        "connections": map.connections,
        "unit": map.detectedUnit
      };
      await _backendService.selectCustomMap(mapData);
      notifyListeners();
    } else {
      _isCustomMapActive = false;
      _activeCustomMapName = null;
      // Re-upload the image so backend refreshes its graph
      await uploadOccupancyMap(map.imageBytes, map.fileName, makeActive: true);
    }
  }

  /// Delete a map from history. If it is the currently active map, clear active map state.
  void deleteMap(String fileName) {
    _loadedMaps.removeWhere((m) => m.fileName == fileName);
    if (_mapFileName == fileName) {
      _mapLoaded = false;
      _mapImageBytes = null;
      _mapFileName = null;
      _checkpoints = {};
      _metricCheckpoints = {};
      _connections = [];
      _intermediateCheckpoints = [];
      _calculatedPath = [];
      _calculatedCoordinates = [];
      _estimatedDistance = 0.0;
      _estimatedTime = 0.0;
      _missionStatus = "NO ACTIVE MISSION";
      _sourceCheckpoint = "";
      _destinationCheckpoint = "";
      _isCustomMapActive = false;
      _activeCustomMapName = null;
    }
    notifyListeners();
  }

  // ── Custom Maps Persistence State Management ──────────────────────────────

  // Fetch all custom maps from the backend
  Future<void> loadCustomMaps() async {
    final result = await _backendService.fetchCustomMaps();
    if (result["maps"] != null) {
      _customMapsList = List<Map<String, dynamic>>.from(result["maps"]);
      notifyListeners();
    }
  }

  // Save map and automatically load it into Loaded Maps list & select it
  Future<bool> saveAndActivateCustomMap(String mapName, Map<String, dynamic> mapData) async {
    _isPlanning = true;
    notifyListeners();

    // 1. Save map JSON to backend disk
    final saveResult = await _backendService.saveCustomMap(mapName, mapData);
    if (saveResult["status"] == "SUCCESS") {
      final fileName = saveResult["file_name"] as String;
      
      // 2. Select custom map as active on backend
      final selectResult = await _backendService.selectCustomMap(mapData);
      _isPlanning = false;

      if (selectResult["status"] == "SUCCESS") {
        _isCustomMapActive = true;
        _activeCustomMapName = mapName;
        _mapLoaded = true;
        _mapFileName = fileName;
        _mapImageBytes = null; // custom designer maps don't have occupancy grid images
        _imageUrl = "";

        _checkpoints = Map<String, dynamic>.from(selectResult["checkpoints"] ?? {});
        _metricCheckpoints = Map<String, dynamic>.from(selectResult["metric_checkpoints"] ?? {});
        _connections = List<dynamic>.from(selectResult["connections"] ?? []);
        _detectedUnit = selectResult["detected_unit"] ?? "m";

        // Reset mission routing state
        _intermediateCheckpoints = [];
        _calculatedPath = [];
        _calculatedCoordinates = [];
        _estimatedDistance = 0.0;
        _estimatedTime = 0.0;
        _missionStatus = "NO ACTIVE MISSION";

        if (_metricCheckpoints.isNotEmpty) {
          _sourceCheckpoint = _metricCheckpoints.keys.first;
          _destinationCheckpoint = _metricCheckpoints.keys.last;
          _robotX = _metricCheckpoints[_sourceCheckpoint]["x"]?.toDouble() ?? _robotX;
          _robotY = _metricCheckpoints[_sourceCheckpoint]["y"]?.toDouble() ?? _robotY;
          _currentCheckpoint = _sourceCheckpoint;
        }

        // 3. Add to Loaded Maps history list in Plan a Mission
        _loadedMaps.removeWhere((m) => m.fileName == fileName);
        _loadedMaps.add(LoadedMap(
          fileName: fileName,
          imageBytes: [], // mark empty to signify custom map
          checkpoints: _checkpoints,
          metricCheckpoints: _metricCheckpoints,
          connections: _connections,
          detectedUnit: _detectedUnit,
          uploadedAt: DateTime.now(),
        ));

        // Reload maps list
        await loadCustomMaps();
        notifyListeners();
        return true;
      } else {
        _alertMessage = "Map Selection Failed: ${selectResult["message"]}";
        notifyListeners();
        return false;
      }
    } else {
      _isPlanning = false;
      _alertMessage = "Map Save Failed: ${saveResult["message"]}";
      notifyListeners();
      return false;
    }
  }

  // Delete custom map
  Future<void> deleteCustomMapProvider(String fileName) async {
    final result = await _backendService.deleteCustomMap(fileName);
    if (result["status"] == "SUCCESS") {
      if (_mapFileName == fileName) {
        // Clear active map
        _mapLoaded = false;
        _mapFileName = null;
        _mapImageBytes = null;
        _imageUrl = "";
        _checkpoints = {};
        _metricCheckpoints = {};
        _connections = [];
        _isCustomMapActive = false;
        _activeCustomMapName = null;
        
        _sourceCheckpoint = "";
        _destinationCheckpoint = "";
        _intermediateCheckpoints = [];
        _calculatedPath = [];
        _calculatedCoordinates = [];
        _estimatedDistance = 0.0;
        _estimatedTime = 0.0;
        _missionStatus = "NO ACTIVE MISSION";
      }
      _loadedMaps.removeWhere((m) => m.fileName == fileName);
      await loadCustomMaps();
      notifyListeners();
    }
  }

  // Restore/select a custom map as active map
  Future<bool> selectCustomMapActive(String fileName, String mapName) async {
    _isPlanning = true;
    notifyListeners();

    final mapData = await _backendService.fetchCustomMapDetail(fileName);
    if (mapData.containsKey("error")) {
      _isPlanning = false;
      _alertMessage = "Failed to load map detail: ${mapData["error"]}";
      notifyListeners();
      return false;
    }

    final selectResult = await _backendService.selectCustomMap(mapData);
    _isPlanning = false;

    if (selectResult["status"] == "SUCCESS") {
      _isCustomMapActive = true;
      _activeCustomMapName = mapName;
      _mapLoaded = true;
      _mapFileName = fileName;
      _mapImageBytes = null;
      _imageUrl = "";

      _checkpoints = Map<String, dynamic>.from(selectResult["checkpoints"] ?? {});
      _metricCheckpoints = Map<String, dynamic>.from(selectResult["metric_checkpoints"] ?? {});
      _connections = List<dynamic>.from(selectResult["connections"] ?? []);
      _detectedUnit = selectResult["detected_unit"] ?? "m";

      _intermediateCheckpoints = [];
      _calculatedPath = [];
      _calculatedCoordinates = [];
      _estimatedDistance = 0.0;
      _estimatedTime = 0.0;
      _missionStatus = "NO ACTIVE MISSION";

      if (_metricCheckpoints.isNotEmpty) {
        _sourceCheckpoint = _metricCheckpoints.keys.first;
        _destinationCheckpoint = _metricCheckpoints.keys.last;
        _robotX = _metricCheckpoints[_sourceCheckpoint]["x"]?.toDouble() ?? _robotX;
        _robotY = _metricCheckpoints[_sourceCheckpoint]["y"]?.toDouble() ?? _robotY;
        _currentCheckpoint = _sourceCheckpoint;
      }

      // Add/Update in LoadedMap list
      _loadedMaps.removeWhere((m) => m.fileName == fileName);
      _loadedMaps.add(LoadedMap(
        fileName: fileName,
        imageBytes: [], // empty for custom map
        checkpoints: _checkpoints,
        metricCheckpoints: _metricCheckpoints,
        connections: _connections,
        detectedUnit: _detectedUnit,
        uploadedAt: DateTime.now(),
      ));

      notifyListeners();
      return true;
    } else {
      _alertMessage = "Failed to select map: ${selectResult["message"]}";
      notifyListeners();
      return false;
    }
  }

  void addIntermediate(String node) {
    if (!_intermediateCheckpoints.contains(node) &&
        node != _sourceCheckpoint &&
        node != _destinationCheckpoint &&
        _metricCheckpoints.containsKey(node)) {
      _intermediateCheckpoints.add(node);
      _calculatedPath = [];
      _missionStatus = "NO ACTIVE MISSION";
      notifyListeners();
    }
  }

  void removeIntermediate(String node) {
    if (_intermediateCheckpoints.remove(node)) {
      _calculatedPath = [];
      _missionStatus = "NO ACTIVE MISSION";
      notifyListeners();
    }
  }

  void clearIntermediates() {
    _intermediateCheckpoints.clear();
    _calculatedPath = [];
    _missionStatus = "NO ACTIVE MISSION";
    notifyListeners();
  }

  // Set planning selections
  void setSource(String src) {
    if (_metricCheckpoints.containsKey(src)) {
      _sourceCheckpoint = src;
      _intermediateCheckpoints.remove(src); // source cannot be intermediate
      _calculatedPath = [];
      _missionStatus = "NO ACTIVE MISSION";
      
      // Update local variables immediately for responsive UI
      _robotX = _metricCheckpoints[src]["x"]?.toDouble() ?? _robotX;
      _robotY = _metricCheckpoints[src]["y"]?.toDouble() ?? _robotY;
      _currentCheckpoint = src;
      
      notifyListeners();

      // Notify the backend so the source-of-truth position is also updated
      _backendService.setRobotPosition(src);
    }
  }

  void setDestination(String dest) {
    if (_metricCheckpoints.containsKey(dest)) {
      _destinationCheckpoint = dest;
      _intermediateCheckpoints.remove(dest); // destination cannot be intermediate
      _calculatedPath = [];
      _missionStatus = "NO ACTIVE MISSION";
      notifyListeners();
    }
  }

  // Plan path using Dijkstra
  Future<bool> planMissionRoute() async {
    if (_sourceCheckpoint.isEmpty || _destinationCheckpoint.isEmpty) {
      _alertMessage = "Please select both source and destination checkpoints.";
      notifyListeners();
      return false;
    }

    _isPlanning = true;
    notifyListeners();

    final result = await _backendService.planPath(
      _sourceCheckpoint,
      _destinationCheckpoint,
      intermediates: _intermediateCheckpoints,
    );
    _isPlanning = false;

    if (result["status"] == "SUCCESS") {
      _calculatedPath = List<String>.from(result["path"]);
      
      final coordsList = result["coordinates"] as List<dynamic>;
      _calculatedCoordinates = coordsList.map((item) {
        final pair = item as List<dynamic>;
        return [
          (pair[0] as num).toDouble(),
          (pair[1] as num).toDouble(),
        ];
      }).toList();

      _estimatedDistance = (result["distance"] as num).toDouble();
      _estimatedTime = (result["estimated_time"] as num).toDouble();
      _routeInsights = result["route_insights"] ?? "";
      _deliveryIntelligence = result["delivery_intelligence"] ?? "";
      _turnsCount = result["turns_count"] ?? 0;
      
      _missionStatus = "PLANNED";
      _missionProgress = 0.0;
      
      notifyListeners();
      return true;
    } else {
      _alertMessage = "Dijkstra routing failed: ${result["message"]}";
      notifyListeners();
      return false;
    }
  }

  // Action methods calling ESP32
  
  // Start Mission (Auto Mode)
  Future<void> startAutonomousMission() async {
    if (_missionStatus != "PLANNED" && _missionStatus != "PAUSED") {
      _alertMessage = "No valid planned mission route to start.";
      notifyListeners();
      return;
    }

    // ── ESP32 connection guard ────────────────────────────────────
    if (!_esp32Connected) {
      _alertMessage =
          "ROBOT NOT REACHABLE: Connect your device to the ESP32 WiFi "
          "hotspot (Network: $_esp32Ip) and tap TEST CONNECTION before starting.";
      notifyListeners();
      return;
    }

    // Switch robot to auto mode on backend
    await _robotController.setMode("auto");
    
    // Call ESP32 Start
    final response = await _robotController.startRobot();
    _lastApiResponse = response.toString();

    if (response.success) {
      _missionStatus = "RUNNING";
    } else {
      _alertMessage = "Failed to start robot: ${response.message}";
    }
    notifyListeners();
  }

  // Pause Mission
  Future<void> pauseMission() async {
    final response = await _robotController.stopRobot();
    _lastApiResponse = response.toString();

    if (response.success) {
      _missionStatus = "PAUSED";
      _robotStatus = "PAUSED";
    } else {
      _alertMessage = "Failed to pause robot: ${response.message}";
    }
    notifyListeners();
  }

  // Resume Mission
  Future<void> resumeMission() async {
    await startAutonomousMission();
  }

  // Cancel Mission
  Future<void> cancelMission() async {
    final response = await _robotController.stopRobot();
    _lastApiResponse = response.toString();

    if (response.success) {
      _missionStatus = "PLANNED"; // resets to planned
      _missionProgress = 0.0;
      _robotStatus = "STOPPED";
    } else {
      _alertMessage = "Failed to cancel: ${response.message}";
    }
    notifyListeners();
  }

  // Emergency Stop (Always works!)
  Future<void> emergencyStop() async {
    final response = await _robotController.stopRobot();
    _lastApiResponse = response.toString();
    _robotStatus = "STOPPED";
    _activeCommand = "STOP";
    _missionStatus = "PAUSED";
    _alertMessage = "EMERGENCY STOP ENFORCED IMMEDIATELY!";
    notifyListeners();
  }

  // Speed adjustments
  Future<void> adjustSpeed(int speedValue) async {
    _robotSpeed = speedValue;
    notifyListeners();

    // Call API
    final response = await _robotController.setSpeed(speedValue);
    _lastApiResponse = response.toString();
    notifyListeners();
  }

  // ── Mode switch guard ─────────────────────────────────────────────────────
  bool _isModeChanging = false;

  // Manual Mode Switch
  Future<void> switchMode(String targetMode) async {
    if (targetMode == _robotMode) return;

    // Optimistic update — toggle responds immediately without waiting for backend
    final String prevMode = _robotMode;
    _robotMode = targetMode;
    _robotStatus = "STOPPED";
    _activeCommand = "STOP";
    _isModeChanging = true;  // Block telemetry from overwriting during HTTP call
    notifyListeners();

    final response = await _robotController.setMode(targetMode);
    _lastApiResponse = response.toString();
    _isModeChanging = false;  // Allow telemetry to sync again

    if (!response.success) {
      // Roll back if backend rejected the mode change
      _robotMode = prevMode;
      _alertMessage = "Mode switch failed: ${response.message}";
      notifyListeners();
    }
  }

  // Manual driving commands (FORWARD, LEFT, etc.)
  Future<void> triggerManualCommand(String direction) async {
    if (_robotMode != "manual") {
      await switchMode("manual");
    }

    final response = await _robotController.sendDirectionCommand(direction);
    _lastApiResponse = response.toString();
    
    if (response.success) {
      _activeCommand = direction;
      _robotStatus = (direction == "STOP") ? "STOPPED" : "MOVING";
    } else {
      _alertMessage = "Manual command failed: ${response.message}";
    }
    notifyListeners();
  }

  // Open / Close delivery ramp
  Future<void> openRamp() async {
    final success = await _backendService.openRamp();
    _lastApiResponse = success ? "Ramp Open Command Sent" : "Failed to send open ramp command";
    notifyListeners();
  }

  Future<void> closeRamp() async {
    final success = await _backendService.closeRamp();
    _lastApiResponse = success ? "Ramp Close Command Sent" : "Failed to send close ramp command";
    notifyListeners();
  }

  Future<void> resetMission() async {
    _isPlanning = true;
    notifyListeners();

    try {
      final success = await _backendService.resetMission();
      if (success) {
        _calculatedPath = [];
        _calculatedCoordinates = [];
        _estimatedDistance = 0.0;
        _estimatedTime = 0.0;
        _turnsCount = 0;
        _routeInsights = "";
        _deliveryIntelligence = "";
        _missionStatus = "NO ACTIVE MISSION";
        _missionProgress = 0.0;
        _deliveryComplete = false;
        _rampDeployed = false;
        _rampStatus = "CLOSED";

        // Keep current robot checkpoint as source checkpoint for the next trip
        if (_currentCheckpoint.isNotEmpty) {
          _sourceCheckpoint = _currentCheckpoint;
        }
        _destinationCheckpoint = "";
        _intermediateCheckpoints = [];

        setAlert("SUCCESS: Active mission reset. Ready for a new mission!");
      } else {
        setAlert("ERROR: Failed to reset active mission on backend.");
      }
    } catch (e) {
      setAlert("ERROR: Reset mission failed: ${e.toString()}");
    }

    _isPlanning = false;
    notifyListeners();
  }

  // ── Free Roam Mode ────────────────────────────────────────────────────────

  /// Start Free Roam — robot wanders forward, backing up and turning on obstacles.
  Future<void> startFreeRoam() async {
    _freeRoamActive = true;
    _freeRoamState = "MOVING";
    notifyListeners();

    final success = await _backendService.startFreeRoam();
    if (!success) {
      _freeRoamActive = false;
      _freeRoamState = "IDLE";
      setAlert("ERROR: Failed to activate Free Roam mode. Check backend connection.");
      notifyListeners();
    } else {
      addLog("🔓 Free Roam activated");
      addLog("Moving forward...");
    }
  }

  /// Stop Free Roam and halt the robot.
  Future<void> stopFreeRoam() async {
    _freeRoamActive = false;
    _freeRoamState = "IDLE";
    notifyListeners();

    await _backendService.stopFreeRoam();
    addLog("⛔ Free Roam stopped");
  }

  // Update obstacle avoidance settings and sync to backend
  Future<bool> updateAvoidanceSettings({
    required bool enabled,
    required double avoidanceAngle,
    required double clearanceDistance,
    required double verificationDistance,
    required double maxAvoidanceAngle,
  }) async {
    final success = await _backendService.updateAvoidanceSettings(
      enabled: enabled,
      avoidanceAngle: avoidanceAngle,
      clearanceDistance: clearanceDistance,
      verificationDistance: verificationDistance,
      maxAvoidanceAngle: maxAvoidanceAngle,
    );
    if (success) {
      _obstacleAvoidanceEnabled = enabled;
      _avoidanceAngle = avoidanceAngle;
      _clearanceDistance = clearanceDistance;
      _verificationDistance = verificationDistance;
      _maxAvoidanceAngle = maxAvoidanceAngle;
      notifyListeners();
    }
    return success;
  }

  // Update Pure Pursuit settings and sync to backend
  Future<bool> updatePurePursuitSettings({
    required bool enabled,
    required double lookAheadDistance,
    required double maxSteeringCorrection,
    required double trajectoryResolution,
    required int curveResolution,
  }) async {
    final success = await _backendService.updatePurePursuitSettings(
      enabled: enabled,
      lookAheadDistance: lookAheadDistance,
      maxSteeringCorrection: maxSteeringCorrection,
      trajectoryResolution: trajectoryResolution,
      curveResolution: curveResolution,
    );
    if (success) {
      _purePursuitEnabled = enabled;
      _lookAheadDistance = lookAheadDistance;
      _maxSteeringCorrection = maxSteeringCorrection;
      _trajectoryResolution = trajectoryResolution;
      _curveResolution = curveResolution;
      notifyListeners();
    }
    return success;
  }

  @override
  void dispose() {
    _telemetrySubscription?.cancel();
    _backendService.disconnectTelemetryStream();
    super.dispose();
  }
}
