/*
 * ═════════════════════════════════════════════════════════════════════════════
 *  AUTONOMOUS DELIVERY BOT - CAMERA SETTINGS MANAGER
 * ═════════════════════════════════════════════════════════════════════════════
 *  File:        camera_settings.h
 *  Description: Class interface for OV2640 sensor configuration, hardware LED
 *               control, and setting serialization for REST API.
 * ═════════════════════════════════════════════════════════════════════════════
 */

#ifndef CAMERA_SETTINGS_H
#define CAMERA_SETTINGS_H

#include <Arduino.h>
#include "esp_camera.h"
#include "config.h"

class CameraSettings {
public:
  // Constructor
  CameraSettings();

  // Initialize OV2640 sensor hardware
  bool begin();

  // Apply setting parameter by name and integer value (matches CameraWebServer /control endpoint)
  bool setParam(const String& variable, int val);

  // Flash LED Controls
  void setFlashLed(bool enable);
  bool getFlashLed() const;
  void toggleFlashLed();

  // Get current system status
  CameraStatus getStatus() const;

  // Generate JSON string of all camera settings for Flutter REST API
  String getSettingsJson() const;

  // Helper method to convert framesize enum to human-readable string
  static String resolutionToString(framesize_t frameSize);

private:
  bool _initialized;
  bool _flashLedState;
  unsigned long _startTimeMs;

  void _setupPins();
};

extern CameraSettings cameraSettings;

#endif // CAMERA_SETTINGS_H
