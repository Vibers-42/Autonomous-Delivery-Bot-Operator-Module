/*
 * ═════════════════════════════════════════════════════════════════════════════
 *  AUTONOMOUS DELIVERY BOT - HTTP SERVER & REST API HANDLER
 * ═════════════════════════════════════════════════════════════════════════════
 *  File:        app_httpd.h
 *  Description: ESP-IDF HTTP WebServer interface registering MJPEG video stream,
 *               OV2640 controls, and Flutter REST API endpoints.
 * ═════════════════════════════════════════════════════════════════════════════
 */

#ifndef APP_HTTPD_H
#define APP_HTTPD_H

#include <Arduino.h>
#include "esp_http_server.h"

// Start HTTP web server & stream server on port 80
void startCameraServer();

// Stop HTTP server
void stopCameraServer();

#endif // APP_HTTPD_H
