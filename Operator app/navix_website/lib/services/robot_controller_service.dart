import 'dart:async';
import 'package:http/http.dart' as http;

class RobotControllerService {
  String baseUrl;

  RobotControllerService({this.baseUrl = "http://192.168.4.1"});

  // Configure target ESP32 IP address
  void updateBaseUrl(String newIp) {
    // Standardize URL format
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

  // 1. Start Robot
  Future<RobotApiResponse> startRobot() async {
    return _sendGetRequest("$baseUrl/start");
  }

  // 2. Stop Robot (Emergency/Pause)
  Future<RobotApiResponse> stopRobot() async {
    return _sendGetRequest("$baseUrl/stop");
  }

  // 3. Set Robot Speed (0 - 255)
  Future<RobotApiResponse> setSpeed(int value) async {
    if (value < 0 || value > 255) {
      return RobotApiResponse(
        success: false,
        message: "Speed value must be between 0 and 255.",
      );
    }
    return _sendGetRequest("$baseUrl/speed?value=$value");
  }

  // 4. Send Manual Direction Command (FORWARD, BACKWARD, LEFT, RIGHT, STOP)
  Future<RobotApiResponse> sendDirectionCommand(String direction) async {
    return _sendGetRequest("$baseUrl/command?direction=$direction");
  }

  // 5. Set Operation Mode (auto, manual)
  Future<RobotApiResponse> setMode(String mode) async {
    return _sendGetRequest("$baseUrl/mode?type=$mode");
  }

  // Helper method to execute HTTP GET requests with custom timeouts and error handling
  Future<RobotApiResponse> _sendGetRequest(String url) async {
    try {
      final response = await http.get(Uri.parse(url)).timeout(
        const Duration(seconds: 3),
      );
      
      if (response.statusCode == 200) {
        return RobotApiResponse(
          success: true,
          statusCode: response.statusCode,
          message: "Request OK",
          body: response.body,
        );
      } else {
        return RobotApiResponse(
          success: false,
          statusCode: response.statusCode,
          message: "Server Error: ${response.statusCode}",
          body: response.body,
        );
      }
    } on TimeoutException {
      return RobotApiResponse(
        success: false,
        message: "Connection Timeout. Robot is unreachable.",
      );
    } on Exception catch (e) {
      return RobotApiResponse(
        success: false,
        message: "Network Error: ${e.toString()}",
      );
    }
  }
}

class RobotApiResponse {
  final bool success;
  final int? statusCode;
  final String message;
  final String? body;

  RobotApiResponse({
    required this.success,
    this.statusCode,
    required this.message,
    this.body,
  });

  @override
  String toString() {
    return "RobotApiResponse(success: $success, statusCode: $statusCode, message: $message)";
  }
}
