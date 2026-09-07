/*
 * ═════════════════════════════════════════════════════════════════════════════
 *  AUTONOMOUS DELIVERY BOT - VISION API MANAGER
 * ═════════════════════════════════════════════════════════════════════════════
 *  File:        vision_api.h
 *  Description: Class interface for object detection buffer, system monitoring,
 *               and REST JSON serializers for Flutter application integration.
 * ═════════════════════════════════════════════════════════════════════════════
 */

#ifndef VISION_API_H
#define VISION_API_H

#include <Arduino.h>
#include "config.h"

class VisionAPI {
public:
  // Constructor
  VisionAPI();

  // Initialize status & telemetry timers
  void begin();

  // Update background tasks (WiFi monitoring, FPS counter)
  void update();

  // Add object detection result to circular buffer
  void addDetection(const String& label, float confidence, int x, int y, int w, int h);

  // Clear detection buffer
  void clearDetections();

  // REST API JSON formatting methods
  String getStatusJson();
  String getDetectionsJson();

  // Snapshot frame capture helper (allocates JPEG frame buffer, caller frees buffer)
  bool captureJpegFrame(uint8_t** outBuf, size_t* outLen);

  // Push live frame to Backend API (/api/esp32cam/upload) for mobile hotspot routing
  void pushFrameToBackend();

  // Measure stream frame throughput (FPS calculation callback)
  void recordFrameSent();
  float getFps() const;

private:
  DetectionResult _detections[MAX_DETECTIONS_BUFFER];
  int _detectionCount;
  
  // FPS calculation variables
  unsigned long _lastFpsMs;
  int _framesThisSecond;
  float _currentFps;

  // WiFi monitoring & frame push timers
  unsigned long _lastWifiCheckMs;
  unsigned long _lastStreamPushMs;
  void _checkWifiHealth();
};

extern VisionAPI visionApi;

#endif // VISION_API_H
