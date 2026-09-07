/*
 * ═════════════════════════════════════════════════════════════════════════════
 *  AUTONOMOUS DELIVERY BOT - UART COMMUNICATION MANAGER
 * ═════════════════════════════════════════════════════════════════════════════
 *  File:        uart_manager.h
 *  Description: Class interface for Serial2 communication with Navigation ESP32.
 * ═════════════════════════════════════════════════════════════════════════════
 */

#ifndef UART_MANAGER_H
#define UART_MANAGER_H

#include <Arduino.h>
#include "config.h"

class UARTManager {
public:
  // Constructor
  UARTManager();

  // Initialize Hardware Serial2 (TX=14, RX=13)
  void begin(long baudRate = UART_BAUD_RATE, int rxPin = UART_RX_PIN, int txPin = UART_TX_PIN);

  // Main loop update handler (non-blocking timing for heartbeat & serial reads)
  void update();

  // Send 1Hz heartbeat packet to Navigation ESP32
  void sendHeartbeat();

  // Send JSON object detection packet over UART
  void sendDetection(const String& label, float confidence, int x, int y, int w, int h);

  // Send generic raw JSON string over UART
  void sendJson(const String& jsonStr);

  // Callback setter for received UART messages from Navigation ESP32
  typedef void (*MessageCallback)(const String& message);
  void setMessageCallback(MessageCallback callback);

private:
  HardwareSerial _serialPort;
  unsigned long _lastHeartbeatMs;
  MessageCallback _onMessage;
  String _rxBuffer;

  void _processIncomingData();
};

extern UARTManager uartManager;

#endif // UART_MANAGER_H
