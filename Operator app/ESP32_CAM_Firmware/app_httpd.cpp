/*
 * ═════════════════════════════════════════════════════════════════════════════
 *  AUTONOMOUS DELIVERY BOT - HTTP SERVER & REST API IMPLEMENTATION
 * ═════════════════════════════════════════════════════════════════════════════
 *  File:        app_httpd.cpp
 *  Description: Implements MJPEG video stream handler, OV2640 control endpoint,
 *               and REST API endpoints (/api/status, /api/settings, /api/detections,
 *               /api/capture) for Flutter app integration.
 * ═════════════════════════════════════════════════════════════════════════════
 */

#include "app_httpd.h"
#include "esp_camera.h"
#include "camera_settings.h"
#include "vision_api.h"
#include "uart_manager.h"
#include "config.h"

#define PART_BOUNDARY "123456789000000000000987654321"
static const char* _STREAM_CONTENT_TYPE = "multipart/x-mixed-replace;boundary=" PART_BOUNDARY;
static const char* _STREAM_BOUNDARY = "\r\n--" PART_BOUNDARY "\r\n";
static const char* _STREAM_PART = "Content-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n";

httpd_handle_t camera_httpd = NULL;
httpd_handle_t stream_httpd = NULL;

// ── 1. MJPEG VIDEO STREAM HANDLER ────────────────────────────────────────────
static esp_err_t stream_handler(httpd_req_t *req) {
  camera_fb_t * fb = NULL;
  esp_err_t res = ESP_OK;
  size_t _jpg_buf_len = 0;
  uint8_t * _jpg_buf = NULL;
  char part_buf[64];

  res = httpd_resp_set_type(req, _STREAM_CONTENT_TYPE);
  if (res != ESP_OK) return res;

  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

  while (true) {
    fb = esp_camera_fb_get();
    if (!fb) {
      Serial.println("[HTTPD] Camera capture failed during stream");
      res = ESP_FAIL;
    } else {
      _jpg_buf_len = fb->len;
      _jpg_buf = fb->buf;
    }

    if (res == ESP_OK) {
      res = httpd_resp_send_chunk(req, _STREAM_BOUNDARY, strlen(_STREAM_BOUNDARY));
    }
    if (res == ESP_OK) {
      size_t hlen = snprintf(part_buf, 64, _STREAM_PART, _jpg_buf_len);
      res = httpd_resp_send_chunk(req, part_buf, hlen);
    }
    if (res == ESP_OK) {
      res = httpd_resp_send_chunk(req, (const char *)_jpg_buf, _jpg_buf_len);
    }

    if (fb) {
      esp_camera_fb_return(fb);
      fb = NULL;
      _jpg_buf = NULL;
    } else if (_jpg_buf) {
      free(_jpg_buf);
      _jpg_buf = NULL;
    }

    if (res != ESP_OK) break;

    visionApi.recordFrameSent();
  }

  return res;
}

// ── 2. OV2640 CONTROL SETTINGS HANDLER (/control?var=X&val=Y) ───────────────
static esp_err_t cmd_handler(httpd_req_t *req) {
  char* buf;
  size_t buf_len;
  char variable[32] = {0,};
  char value[32] = {0,};

  buf_len = httpd_req_get_url_query_len(req) + 1;
  if (buf_len > 1) {
    buf = (char*)malloc(buf_len);
    if (!buf) {
      httpd_resp_send_500(req);
      return ESP_FAIL;
    }
    if (httpd_req_get_url_query_str(req, buf, buf_len) == ESP_OK) {
      if (httpd_query_key_value(buf, "var", variable, sizeof(variable)) == ESP_OK &&
          httpd_query_key_value(buf, "val", value, sizeof(value)) == ESP_OK) {
      } else {
        free(buf);
        httpd_resp_send_404(req);
        return ESP_FAIL;
      }
    }
    free(buf);
  } else {
    httpd_resp_send_404(req);
    return ESP_FAIL;
  }

  int val = atoi(value);
  bool success = cameraSettings.setParam(String(variable), val);

  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  if (success) {
    httpd_resp_send(req, "OK", 2);
  } else {
    httpd_resp_send_500(req);
  }

  return ESP_OK;
}

// ── 3. REST API: STATUS HANDLER (/api/status) ────────────────────────────────
static esp_err_t api_status_handler(httpd_req_t *req) {
  httpd_resp_set_type(req, "application/json");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  String json = visionApi.getStatusJson();
  return httpd_resp_send(req, json.c_str(), json.length());
}

// ── 4. REST API: SETTINGS HANDLER (/api/settings) ────────────────────────────
static esp_err_t api_settings_handler(httpd_req_t *req) {
  httpd_resp_set_type(req, "application/json");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  String json = cameraSettings.getSettingsJson();
  return httpd_resp_send(req, json.c_str(), json.length());
}

// ── 5. REST API: DETECTIONS HANDLER (/api/detections) ─────────────────────────
static esp_err_t api_detections_handler(httpd_req_t *req) {
  httpd_resp_set_type(req, "application/json");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  String json = visionApi.getDetectionsJson();
  return httpd_resp_send(req, json.c_str(), json.length());
}

// ── 6. REST API: SNAPSHOT CAPTURE HANDLER (/api/capture & /capture) ──────────
static esp_err_t capture_handler(httpd_req_t *req) {
  camera_fb_t * fb = NULL;
  esp_err_t res = ESP_OK;

  fb = esp_camera_fb_get();
  if (!fb) {
    Serial.println("[HTTPD] Camera capture failed");
    httpd_resp_send_500(req);
    return ESP_FAIL;
  }

  httpd_resp_set_type(req, "image/jpeg");
  httpd_resp_set_hdr(req, "Content-Disposition", "inline; filename=capture.jpg");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

  res = httpd_resp_send(req, (const char *)fb->buf, fb->len);
  esp_camera_fb_return(fb);

  return res;
}

// ── 7. ROOT INDEX HANDLER (/) ────────────────────────────────────────────────
static esp_err_t index_handler(httpd_req_t *req) {
  httpd_resp_set_type(req, "text/html");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  const char* html = "<!DOCTYPE html><html><head><title>ESP32-CAM Vision Module</title></head>"
                     "<body style='background:#0f151f;color:#fff;font-family:sans-serif;text-align:center;padding-top:40px;'>"
                     "<h2>ESP32-CAM Vision Module Active</h2>"
                     "<p><a href='/stream' style='color:#00f2fe;font-size:18px;'>▶ View Live MJPEG Stream (/stream)</a></p>"
                     "<p><a href='/api/status' style='color:#00f2fe;'>📊 View API Status (/api/status)</a></p>"
                     "<p><a href='/api/settings' style='color:#00f2fe;'>⚙️ View Settings (/api/settings)</a></p>"
                     "</body></html>";
  return httpd_resp_send(req, html, strlen(html));
}

// ── REGISTER HTTP SERVER ENDPOINTS ───────────────────────────────────────────
void startCameraServer() {
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = HTTP_SERVER_PORT;

  httpd_uri_t index_uri = {
    .uri       = "/",
    .method    = HTTP_GET,
    .handler   = index_handler,
    .user_ctx  = NULL
  };

  httpd_uri_t stream_uri = {
    .uri       = "/stream",
    .method    = HTTP_GET,
    .handler   = stream_handler,
    .user_ctx  = NULL
  };

  httpd_uri_t cmd_uri = {
    .uri       = "/control",
    .method    = HTTP_GET,
    .handler   = cmd_handler,
    .user_ctx  = NULL
  };

  httpd_uri_t status_uri = {
    .uri       = "/api/status",
    .method    = HTTP_GET,
    .handler   = api_status_handler,
    .user_ctx  = NULL
  };

  httpd_uri_t settings_uri = {
    .uri       = "/api/settings",
    .method    = HTTP_GET,
    .handler   = api_settings_handler,
    .user_ctx  = NULL
  };

  httpd_uri_t detections_uri = {
    .uri       = "/api/detections",
    .method    = HTTP_GET,
    .handler   = api_detections_handler,
    .user_ctx  = NULL
  };

  httpd_uri_t capture_uri = {
    .uri       = "/capture",
    .method    = HTTP_GET,
    .handler   = capture_handler,
    .user_ctx  = NULL
  };

  httpd_uri_t api_capture_uri = {
    .uri       = "/api/capture",
    .method    = HTTP_GET,
    .handler   = capture_handler,
    .user_ctx  = NULL
  };

  Serial.printf("[HTTPD] Starting web server on port %d\n", config.server_port);
  if (httpd_start(&camera_httpd, &config) == ESP_OK) {
    httpd_register_uri_handler(camera_httpd, &index_uri);
    httpd_register_uri_handler(camera_httpd, &stream_uri);
    httpd_register_uri_handler(camera_httpd, &cmd_uri);
    httpd_register_uri_handler(camera_httpd, &status_uri);
    httpd_register_uri_handler(camera_httpd, &settings_uri);
    httpd_register_uri_handler(camera_httpd, &detections_uri);
    httpd_register_uri_handler(camera_httpd, &capture_uri);
    httpd_register_uri_handler(camera_httpd, &api_capture_uri);
    Serial.println("[HTTPD] All REST API & Streaming Endpoints Registered!");
  } else {
    Serial.println("[HTTPD] Error starting HTTP server!");
  }
}

void stopCameraServer() {
  if (camera_httpd) {
    httpd_stop(camera_httpd);
    camera_httpd = NULL;
  }
}
