/*
 * ═════════════════════════════════════════════════════════════════════════════
 *  AUTONOMOUS DELIVERY BOT - ESP32-CAM VISION MODULE CONFIGURATION
 * ═════════════════════════════════════════════════════════════════════════════
 *  File:        config.h
 *  Description: Hardware pin definitions, default credentials, timing parameters,
 *               and shared data structures for AI-Thinker ESP32-CAM board.
 * ═════════════════════════════════════════════════════════════════════════════
 */

#ifndef CONFIG_H
#define CONFIG_H

#include <Arduino.h>

// ── WIFI MODE SELECTION ──────────────────────────────────────────────────────
// Set USE_AP_MODE to false so ESP32-CAM connects to the Main ESP32's 'ESP32_ROBOT' network!
#define USE_AP_MODE false

#define AP_SSID       "ESP32_CAM_STREAM"
#define AP_PASSWORD   "12345678"

// STA Mode Credentials (connects to Main ESP32 'ESP32_ROBOT' Access Point)
#ifndef WIFI_SSID
#define WIFI_SSID     "ESP32_ROBOT"
#endif

#ifndef WIFI_PASSWORD
#define WIFI_PASSWORD "12345678"
#endif

#define HTTP_SERVER_PORT 80

// ── BACKEND STREAMING CONFIGURATION ──────────────────────────────────────────
#define ENABLE_BACKEND_STREAM_PUSH true
#define BACKEND_IP   "192.168.4.2"   // Laptop's IP when connected to ESP32 AP
#define BACKEND_PORT 8000

// ── AI-THINKER ESP32-CAM PIN DEFINITIONS ─────────────────────────────────────
#define PWDN_GPIO_NUM     32
#define RESET_GPIO_NUM    -1
#define XCLK_GPIO_NUM      0
#define SIOD_GPIO_NUM     26
#define SIOC_GPIO_NUM     27

#define Y9_GPIO_NUM       35
#define Y8_GPIO_NUM       34
#define Y7_GPIO_NUM       39
#define Y6_GPIO_NUM       36
#define Y5_GPIO_NUM       21
#define Y4_GPIO_NUM       19
#define Y3_GPIO_NUM       18
#define Y2_GPIO_NUM        5
#define VSYNC_GPIO_NUM    25
#define HREF_GPIO_NUM     23
#define PCLK_GPIO_NUM     22

// Onboard High-Power Flash LED Pin
#define FLASH_LED_PIN      4

// ── UART COMMUNICATION (LINK TO NAVIGATION ESP32) ────────────────────────────
#define UART_BAUD_RATE     115200
#define UART_TX_PIN        14     // Hardware Serial2 TX -> Nav ESP32 RX
#define UART_RX_PIN        13     // Hardware Serial2 RX -> Nav ESP32 TX

// ── SYSTEM TIMING CONSTANTS ──────────────────────────────────────────────────
#define HEARTBEAT_INTERVAL_MS  1000  // 1Hz UART Heartbeat Packet
#define TELEMETRY_CHECK_MS     2000  // 2s Status Monitoring Interval
#define MAX_DETECTIONS_BUFFER  10    // Max active detections stored in memory

// ── SHARED DATA STRUCTURES ───────────────────────────────────────────────────
struct CameraStatus {
  bool initialized;
  bool flashLedOn;
  int wifiRssi;
  String ipAddress;
  unsigned long uptimeMs;
  float fps;
  String currentResolution;
};

struct DetectionResult {
  String label;
  float confidence;
  int x;
  int y;
  int w;
  int h;
  unsigned long timestamp;
};

#endif // CONFIG_H
