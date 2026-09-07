/*
 * ═════════════════════════════════════════════════════════════════════════════
 *  AUTONOMOUS DELIVERY BOT - ESP32-CAM VISION MODULE MAIN FIRMWARE
 * ═════════════════════════════════════════════════════════════════════════════
 *  File:        ESP32_CAM_Firmware.ino
 *  Board:       AI-Thinker ESP32-CAM (OV2640 Camera Sensor)
 * 
 *  Modules:
 *    1. config.h            - Hardware pinout & system constants
 *    2. camera_settings.h/cpp - OV2640 sensor driver & Flash LED manager
 *    3. uart_manager.h/cpp  - Hardware Serial2 link & 1Hz Heartbeat to Nav ESP32
 *    4. vision_api.h/cpp    - Object detection buffer, FPS metrics & JSON API
 *    5. app_httpd.h/cpp     - HTTP WebServer, MJPEG streamer & REST APIs
 * 
 *  REST APIs Exposed:
 *    - GET /stream          : Live MJPEG Video Stream
 *    - GET /control         : OV2640 setting updater (/control?var=X&val=Y)
 *    - GET /api/status      : Camera & WiFi hardware status JSON
 *    - GET /api/settings    : Full OV2640 camera parameters JSON
 *    - GET /api/detections  : Active object detections JSON
 *    - GET /api/capture     : High-resolution JPEG snapshot
 * 
 * ═════════════════════════════════════════════════════════════════════════════
 */

#include <WiFi.h>
#include "config.h"
#include "camera_settings.h"
#include "uart_manager.h"
#include "vision_api.h"
#include "app_httpd.h"

// ── WIFI SETUP FUNCTION ──────────────────────────────────────────────────────
void setupWiFi() {
#if USE_AP_MODE
  Serial.printf("[System] Starting Direct ESP32 Wi-Fi Access Point: %s\n", AP_SSID);
  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID, AP_PASSWORD);
  IPAddress apIP = WiFi.softAPIP();
  Serial.println("[System] Wi-Fi Access Point Active!");
  Serial.print("[System] ESP32-CAM Fixed IP Address: ");
  Serial.println(apIP); // 192.168.4.1
  Serial.print("[System] MJPEG Stream URL: http://");
  Serial.print(apIP);
  Serial.println("/stream");
#else
  Serial.printf("[System] Connecting to WiFi SSID: %s", WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED && attempts < 30) {
    delay(500);
    Serial.print(".");
    attempts++;
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("\n[System] WiFi Connected Successfully!");
    Serial.print("[System] Local IP Address: ");
    Serial.println(WiFi.localIP());
    Serial.print("[System] MJPEG Stream URL: http://");
    Serial.print(WiFi.localIP());
    Serial.println("/stream");
  } else {
    Serial.println("\n[System] WiFi Connection Failed! Re-trying in background loop...");
  }
#endif
}

// ── HARDWARE INITIALIZATION ──────────────────────────────────────────────────
void setup() {
  // Initialize USB Serial for debug console
  Serial.begin(115200);
  delay(500);
  Serial.println("\n═════════════════════════════════════════════════════════════");
  Serial.println("  AUTONOMOUS DELIVERY BOT - ESP32-CAM VISION MODULE v2.0");
  Serial.println("═════════════════════════════════════════════════════════════");

  // 1. Initialize OV2640 camera sensor & driver
  if (!cameraSettings.begin()) {
    Serial.println("[System] ERROR: OV2640 Camera Hardware Initialization Failed!");
  }

  // 2. Connect to WiFi network
  setupWiFi();

  // 3. Initialize UART Hardware Serial2 for Navigation ESP32 link
  uartManager.begin(UART_BAUD_RATE, UART_RX_PIN, UART_TX_PIN);

  // 4. Initialize Vision API metrics & detection queue
  visionApi.begin();

  // 5. Start HTTP WebServer & REST endpoints
  startCameraServer();

  Serial.println("[System] ESP32-CAM Vision Module Ready!");
}

// ── MAIN NON-BLOCKING EXECUTION LOOP ─────────────────────────────────────────
void loop() {
  // 1. Update UART communications & 1Hz heartbeat transmission
  uartManager.update();

  // 2. Monitor camera status, WiFi connection health & FPS calculations
  visionApi.update();

  // Non-blocking yield for FreeRTOS background tasks
  delay(1);
}
