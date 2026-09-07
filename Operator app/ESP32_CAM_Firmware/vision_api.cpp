/*
 * ═════════════════════════════════════════════════════════════════════════════
 *  AUTONOMOUS DELIVERY BOT - VISION API IMPLEMENTATION
 * ═════════════════════════════════════════════════════════════════════════════
 *  File:        vision_api.cpp
 *  Description: Implements object detection queue, WiFi monitoring, frame metrics,
 *               and REST API serializers for Flutter integration.
 * ═════════════════════════════════════════════════════════════════════════════
 */

#include "vision_api.h"
#include "camera_settings.h"
#include "esp_camera.h"
#include <WiFi.h>
#include <HTTPClient.h>

VisionAPI visionApi;

VisionAPI::VisionAPI()
  : _detectionCount(0), _lastFpsMs(0), _framesThisSecond(0), _currentFps(0.0), _lastWifiCheckMs(0), _lastStreamPushMs(0) {}

void VisionAPI::begin() {
  _lastFpsMs = millis();
  _lastWifiCheckMs = millis();
  _lastStreamPushMs = millis();
  _detectionCount = 0;
}

void VisionAPI::update() {
  unsigned long now = millis();

  // 1. Calculate FPS
  if (now - _lastFpsMs >= 1000) {
    _currentFps = (float)_framesThisSecond / ((now - _lastFpsMs) / 1000.0f);
    _framesThisSecond = 0;
    _lastFpsMs = now;
  }

  // 2. Check WiFi connection health
  if (now - _lastWifiCheckMs >= TELEMETRY_CHECK_MS) {
    _lastWifiCheckMs = now;
    _checkWifiHealth();
  }

#if ENABLE_BACKEND_STREAM_PUSH
  // 3. Push frame to laptop FastAPI Backend (10 FPS target, works on Mobile Hotspot with AP Isolation!)
  if (now - _lastStreamPushMs >= 100) {
    _lastStreamPushMs = now;
    pushFrameToBackend();
  }
#endif
}

void VisionAPI::pushFrameToBackend() {
  if (WiFi.status() != WL_CONNECTED) return;

  camera_fb_t * fb = esp_camera_fb_get();
  if (!fb) return;

  HTTPClient http;
  String url = "http://" + String(BACKEND_IP) + ":" + String(BACKEND_PORT) + "/api/esp32cam/upload";
  http.begin(url);
  http.addHeader("Content-Type", "image/jpeg");
  int code = http.POST(fb->buf, fb->len);
  http.end();

  esp_camera_fb_return(fb);
  if (code > 0) {
    recordFrameSent();
  }
}

void VisionAPI::recordFrameSent() {
  _framesThisSecond++;
}

float VisionAPI::getFps() const {
  return _currentFps;
}

void VisionAPI::addDetection(const String& label, float confidence, int x, int y, int w, int h) {
  if (_detectionCount < MAX_DETECTIONS_BUFFER) {
    _detections[_detectionCount].label = label;
    _detections[_detectionCount].confidence = confidence;
    _detections[_detectionCount].x = x;
    _detections[_detectionCount].y = y;
    _detections[_detectionCount].w = w;
    _detections[_detectionCount].h = h;
    _detections[_detectionCount].timestamp = millis();
    _detectionCount++;
  } else {
    // Shift buffer left and insert new detection
    for (int i = 0; i < MAX_DETECTIONS_BUFFER - 1; i++) {
      _detections[i] = _detections[i + 1];
    }
    _detections[MAX_DETECTIONS_BUFFER - 1].label = label;
    _detections[MAX_DETECTIONS_BUFFER - 1].confidence = confidence;
    _detections[MAX_DETECTIONS_BUFFER - 1].x = x;
    _detections[MAX_DETECTIONS_BUFFER - 1].y = y;
    _detections[MAX_DETECTIONS_BUFFER - 1].w = w;
    _detections[MAX_DETECTIONS_BUFFER - 1].h = h;
    _detections[MAX_DETECTIONS_BUFFER - 1].timestamp = millis();
  }
}

void VisionAPI::clearDetections() {
  _detectionCount = 0;
}

String VisionAPI::getStatusJson() {
  CameraStatus status = cameraSettings.getStatus();
  status.fps = _currentFps;

  String json = "{";
  json += "\"status\":\"" + String(status.initialized ? "ONLINE" : "OFFLINE") + "\",";
  json += "\"camera_initialized\":" + String(status.initialized ? "true" : "false") + ",";
  json += "\"ip\":\"" + status.ipAddress + "\",";
  json += "\"rssi\":" + String(status.wifiRssi) + ",";
  json += "\"fps\":" + String(status.fps, 1) + ",";
  json += "\"resolution\":\"" + status.currentResolution + "\",";
  json += "\"flash_led\":" + String(status.flashLedOn ? "true" : "false") + ",";
  json += "\"uptime_ms\":" + String(status.uptimeMs) + ",";
  json += "\"heap_free\":" + String(ESP.getFreeHeap()) + ",";
  json += "\"psram_free\":" + String(ESP.getFreePsram());
  json += "}";
  return json;
}

String VisionAPI::getDetectionsJson() {
  String json = "{\"count\":" + String(_detectionCount) + ",\"detections\":[";
  for (int i = 0; i < _detectionCount; i++) {
    json += "{";
    json += "\"label\":\"" + _detections[i].label + "\",";
    json += "\"confidence\":" + String(_detections[i].confidence, 2) + ",";
    json += "\"x\":" + String(_detections[i].x) + ",";
    json += "\"y\":" + String(_detections[i].y) + ",";
    json += "\"w\":" + String(_detections[i].w) + ",";
    json += "\"h\":" + String(_detections[i].h) + ",";
    json += "\"timestamp\":" + String(_detections[i].timestamp);
    json += "}";
    if (i < _detectionCount - 1) json += ",";
  }
  json += "]}";
  return json;
}

bool VisionAPI::captureJpegFrame(uint8_t** outBuf, size_t* outLen) {
  camera_fb_t * fb = esp_camera_fb_get();
  if (!fb) {
    Serial.println("[VisionAPI] Frame capture failed");
    return false;
  }

  *outLen = fb->len;
  *outBuf = (uint8_t*)malloc(fb->len);
  if (*outBuf == nullptr) {
    esp_camera_fb_return(fb);
    return false;
  }

  memcpy(*outBuf, fb->buf, fb->len);
  esp_camera_fb_return(fb);
  return true;
}

void VisionAPI::_checkWifiHealth() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[VisionAPI] WiFi Connection Lost! Reconnecting...");
    WiFi.reconnect();
  }
}
