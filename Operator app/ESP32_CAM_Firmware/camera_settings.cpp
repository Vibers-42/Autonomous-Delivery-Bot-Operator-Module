/*
 * ═════════════════════════════════════════════════════════════════════════════
 *  AUTONOMOUS DELIVERY BOT - CAMERA SETTINGS IMPLEMENTATION
 * ═════════════════════════════════════════════════════════════════════════════
 *  File:        camera_settings.cpp
 *  Description: Manages OV2640 sensor driver, setting variables, and Flash LED.
 * ═════════════════════════════════════════════════════════════════════════════
 */

#include "camera_settings.h"
#include <WiFi.h>

CameraSettings cameraSettings;

CameraSettings::CameraSettings()
  : _initialized(false), _flashLedState(false), _startTimeMs(0) {}

bool CameraSettings::begin() {
  _startTimeMs = millis();
  _setupPins();

  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer   = LEDC_TIMER_0;
  config.pin_d0       = Y2_GPIO_NUM;
  config.pin_d1       = Y3_GPIO_NUM;
  config.pin_d2       = Y4_GPIO_NUM;
  config.pin_d3       = Y5_GPIO_NUM;
  config.pin_d4       = Y6_GPIO_NUM;
  config.pin_d5       = Y7_GPIO_NUM;
  config.pin_d6       = Y8_GPIO_NUM;
  config.pin_d7       = Y9_GPIO_NUM;
  config.pin_xclk     = XCLK_GPIO_NUM;
  config.pin_pclk     = PCLK_GPIO_NUM;
  config.pin_vsync    = VSYNC_GPIO_NUM;
  config.pin_href     = HREF_GPIO_NUM;
  config.pin_sscb_sda = SIOD_GPIO_NUM;
  config.pin_sscb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn     = PWDN_GPIO_NUM;
  config.pin_reset    = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;

  if (psramFound()) {
    config.frame_size = FRAMESIZE_VGA;  // 640x480
    config.jpeg_quality = 12;           // 10-63
    config.fb_count = 2;
  } else {
    config.frame_size = FRAMESIZE_QVGA; // 320x240
    config.jpeg_quality = 15;
    config.fb_count = 1;
  }

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("[CameraSettings] Camera init failed with error 0x%x\n", err);
    _initialized = false;
    return false;
  }

  sensor_t * s = esp_camera_sensor_get();
  if (s) {
    s->set_vflip(s, 1);
    s->set_hmirror(s, 0);
  }

  _initialized = true;
  Serial.println("[CameraSettings] OV2640 Driver Initialized Successfully!");
  return true;
}

void CameraSettings::_setupPins() {
  pinMode(FLASH_LED_PIN, OUTPUT);
  digitalWrite(FLASH_LED_PIN, _flashLedState ? HIGH : LOW);
}

void CameraSettings::setFlashLed(bool enable) {
  _flashLedState = enable;
  digitalWrite(FLASH_LED_PIN, _flashLedState ? HIGH : LOW);
}

bool CameraSettings::getFlashLed() const {
  return _flashLedState;
}

void CameraSettings::toggleFlashLed() {
  setFlashLed(!_flashLedState);
}

bool CameraSettings::setParam(const String& variable, int val) {
  sensor_t * s = esp_camera_sensor_get();
  if (!s) return false;

  int res = 0;

  if (variable == "framesize") {
    if (s->pixformat == PIXFORMAT_JPEG) {
      res = s->set_framesize(s, (framesize_t)val);
    }
  } else if (variable == "quality") res = s->set_quality(s, val);
  else if (variable == "contrast") res = s->set_contrast(s, val);
  else if (variable == "brightness") res = s->set_brightness(s, val);
  else if (variable == "saturation") res = s->set_saturation(s, val);
  else if (variable == "gainceiling") res = s->set_gainceiling(s, (gainceiling_t)val);
  else if (variable == "colorbar") res = s->set_colorbar(s, val);
  else if (variable == "awb") res = s->set_whitebal(s, val);
  else if (variable == "agc") res = s->set_gain_ctrl(s, val);
  else if (variable == "aec") res = s->set_exposure_ctrl(s, val);
  else if (variable == "hmirror") res = s->set_hmirror(s, val);
  else if (variable == "vflip") res = s->set_vflip(s, val);
  else if (variable == "awb_gain") res = s->set_awb_gain(s, val);
  else if (variable == "agc_gain") res = s->set_agc_gain(s, val);
  else if (variable == "aec_value") res = s->set_aec_value(s, val);
  else if (variable == "aec2") res = s->set_aec2(s, val);
  else if (variable == "dcw") res = s->set_dcw(s, val);
  else if (variable == "bpc") res = s->set_bpc(s, val);
  else if (variable == "wpc") res = s->set_wpc(s, val);
  else if (variable == "raw_gma") res = s->set_raw_gma(s, val);
  else if (variable == "lenc") res = s->set_lenc(s, val);
  else if (variable == "special_effect") res = s->set_special_effect(s, val);
  else if (variable == "wb_mode") res = s->set_wb_mode(s, val);
  else if (variable == "ae_level") res = s->set_ae_level(s, val);
  else if (variable == "flash") {
    setFlashLed(val > 0);
    return true;
  } else {
    return false;
  }

  return (res == 0);
}

CameraStatus CameraSettings::getStatus() const {
  CameraStatus status;
  status.initialized = _initialized;
  status.flashLedOn = _flashLedState;
  status.wifiRssi = (WiFi.status() == WL_CONNECTED) ? WiFi.RSSI() : 0;
  status.ipAddress = (WiFi.status() == WL_CONNECTED) ? WiFi.localIP().toString() : "Disconnected";
  status.uptimeMs = millis() - _startTimeMs;
  status.fps = 0.0; // Updated dynamically by streamer

  sensor_t * s = esp_camera_sensor_get();
  if (s) {
    status.currentResolution = resolutionToString((framesize_t)s->status.framesize);
  } else {
    status.currentResolution = "Unknown";
  }

  return status;
}

String CameraSettings::getSettingsJson() const {
  sensor_t * s = esp_camera_sensor_get();
  if (!s) return "{}";

  String json = "{";
  json += "\"framesize\":" + String(s->status.framesize) + ",";
  json += "\"quality\":" + String(s->status.quality) + ",";
  json += "\"brightness\":" + String(s->status.brightness) + ",";
  json += "\"contrast\":" + String(s->status.contrast) + ",";
  json += "\"saturation\":" + String(s->status.saturation) + ",";
  json += "\"special_effect\":" + String(s->status.special_effect) + ",";
  json += "\"wb_mode\":" + String(s->status.wb_mode) + ",";
  json += "\"awb\":" + String(s->status.awb) + ",";
  json += "\"awb_gain\":" + String(s->status.awb_gain) + ",";
  json += "\"aec\":" + String(s->status.aec) + ",";
  json += "\"aec2\":" + String(s->status.aec2) + ",";
  json += "\"ae_level\":" + String(s->status.ae_level) + ",";
  json += "\"agc\":" + String(s->status.agc) + ",";
  json += "\"gainceiling\":" + String(s->status.gainceiling) + ",";
  json += "\"bpc\":" + String(s->status.bpc) + ",";
  json += "\"wpc\":" + String(s->status.wpc) + ",";
  json += "\"raw_gma\":" + String(s->status.raw_gma) + ",";
  json += "\"lenc\":" + String(s->status.lenc) + ",";
  json += "\"hmirror\":" + String(s->status.hmirror) + ",";
  json += "\"vflip\":" + String(s->status.vflip) + ",";
  json += "\"dcw\":" + String(s->status.dcw) + ",";
  json += "\"colorbar\":" + String(s->status.colorbar) + ",";
  json += "\"flash_led\":" + String(_flashLedState ? 1 : 0);
  json += "}";
  return json;
}

String CameraSettings::resolutionToString(framesize_t frameSize) {
  switch (frameSize) {
    case FRAMESIZE_QQVGA: return "QQVGA (160x120)";
    case FRAMESIZE_HQVGA: return "HQVGA (240x176)";
    case FRAMESIZE_QVGA:  return "QVGA (320x240)";
    case FRAMESIZE_CIF:   return "CIF (400x296)";
    case FRAMESIZE_VGA:   return "VGA (640x480)";
    case FRAMESIZE_SVGA:  return "SVGA (800x600)";
    case FRAMESIZE_XGA:   return "XGA (1024x768)";
    case FRAMESIZE_SXGA:  return "SXGA (1280x1024)";
    case FRAMESIZE_UXGA:  return "UXGA (1600x1200)";
    default: return "Custom";
  }
}
