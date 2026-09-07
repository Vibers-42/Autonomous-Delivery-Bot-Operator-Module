/*
 * ═════════════════════════════════════════════════════════════════════════════
 *  AUTONOMOUS DELIVERY BOT - UART COMMUNICATION IMPLEMENTATION
 * ═════════════════════════════════════════════════════════════════════════════
 *  File:        uart_manager.cpp
 *  Description: Handles Serial2 UART packets, heartbeats, and detection relays.
 * ═════════════════════════════════════════════════════════════════════════════
 */

#include "uart_manager.h"
#include "camera_settings.h"
#include <WiFi.h>

UARTManager uartManager;

UARTManager::UARTManager()
  : _serialPort(2), _lastHeartbeatMs(0), _onMessage(nullptr) {}

void UARTManager::begin(long baudRate, int rxPin, int txPin) {
  _serialPort.begin(baudRate, SERIAL_8N1, rxPin, txPin);
  Serial.printf("[UARTManager] Hardware Serial2 Initialized on TX Pin %d, RX Pin %d at %ld baud\n", txPin, rxPin, baudRate);
}

void UARTManager::update() {
  unsigned long now = millis();

  // 1. Send 1Hz Heartbeat packet to Navigation ESP32
  if (now - _lastHeartbeatMs >= HEARTBEAT_INTERVAL_MS) {
    _lastHeartbeatMs = now;
    sendHeartbeat();
  }

  // 2. Read incoming serial commands from Navigation ESP32
  _processIncomingData();
}

void UARTManager::sendHeartbeat() {
  CameraStatus status = cameraSettings.getStatus();

  String json = "{";
  json += "\"type\":\"heartbeat\",";
  json += "\"source\":\"ESP32-CAM\",";
  json += "\"uptime_ms\":" + String(status.uptimeMs) + ",";
  json += "\"wifi_rssi\":" + String(status.wifiRssi) + ",";
  json += "\"flash_led\":" + String(status.flashLedOn ? 1 : 0) + ",";
  json += "\"resolution\":\"" + status.currentResolution + "\"";
  json += "}\n";

  sendJson(json);
}

void UARTManager::sendDetection(const String& label, float confidence, int x, int y, int w, int h) {
  String json = "{";
  json += "\"type\":\"detection\",";
  json += "\"label\":\"" + label + "\",";
  json += "\"confidence\":" + String(confidence, 2) + ",";
  json += "\"x\":" + String(x) + ",";
  json += "\"y\":" + String(y) + ",";
  json += "\"w\":" + String(w) + ",";
  json += "\"h\":" + String(h) + ",";
  json += "\"timestamp\":" + String(millis());
  json += "}\n";

  sendJson(json);
}

void UARTManager::sendJson(const String& jsonStr) {
  _serialPort.print(jsonStr);
  _serialPort.flush();
}

void UARTManager::setMessageCallback(MessageCallback callback) {
  _onMessage = callback;
}

void UARTManager::_processIncomingData() {
  while (_serialPort.available() > 0) {
    char c = (char)_serialPort.read();
    if (c == '\n') {
      _rxBuffer.trim();
      if (_rxBuffer.length() > 0) {
        Serial.print("[UARTManager] Received from Nav ESP32: ");
        Serial.println(_rxBuffer);
        if (_onMessage != nullptr) {
          _onMessage(_rxBuffer);
        }
      }
      _rxBuffer = "";
    } else if (c != '\r') {
      _rxBuffer += c;
    }
  }
}
