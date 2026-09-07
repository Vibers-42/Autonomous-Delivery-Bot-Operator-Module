import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import '../providers/robot_state_provider.dart';
import '../utils/hud_colors.dart';

class Esp32CamControlScreen extends StatefulWidget {
  const Esp32CamControlScreen({super.key});

  @override
  State<Esp32CamControlScreen> createState() => _Esp32CamControlScreenState();
}

class _Esp32CamControlScreenState extends State<Esp32CamControlScreen> {
  final TextEditingController _ipController = TextEditingController(text: "192.168.4.2");
  
  // OV2640 Camera Settings State
  int _resolutionIndex = 6; // QVGA default (320x240)
  double _quality = 12;
  double _brightness = 0;
  double _contrast = 0;
  double _saturation = 0;
  int _specialEffect = 0;
  
  bool _awb = true;
  bool _awbGain = true;
  int _wbMode = 0;
  
  bool _aecSensor = true;
  bool _aecDsp = true;
  double _aeLevel = 0;
  
  bool _agc = true;
  int _gainCeiling = 0;
  
  bool _bpc = false;
  bool _wpc = true;
  bool _rawGma = true;
  bool _lensCorrection = true;
  bool _hMirror = false;
  bool _vMirror = false;
  bool _dcw = true;
  bool _colorBar = false;
  bool _flashLed = false;

  bool _isSending = false;
  String _statusLog = "Ready";

  Timer? _frameTimer;
  Uint8List? _directImageBytes;
  bool _directConnected = false;
  bool _isFetchingFrame = false;

  final List<Map<String, dynamic>> _resolutions = [
    {"label": "UXGA (1600x1200)", "val": 10},
    {"label": "SXGA (1280x1024)", "val": 9},
    {"label": "XGA (1024x768)", "val": 8},
    {"label": "SVGA (800x600)", "val": 7},
    {"label": "VGA (640x480)", "val": 6},
    {"label": "CIF (400x296)", "val": 5},
    {"label": "QVGA (320x240)", "val": 4},
    {"label": "HQVGA (240x176)", "val": 3},
    {"label": "QQVGA (160x120)", "val": 0},
  ];

  final List<String> _specialEffectsList = [
    "No Effect", "Negative", "Grayscale", "Red Tint", "Green Tint", "Blue Tint", "Sepia"
  ];

  final List<String> _wbModesList = [
    "Auto", "Sunny", "Cloudy", "Office", "Home"
  ];

  final List<String> _gainCeilingList = [
    "2x", "4x", "8x", "16x", "32x", "64x", "128x"
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = Provider.of<RobotStateProvider>(context, listen: false);
      if (provider.esp32CamIp.isNotEmpty && provider.esp32CamIp != "Disconnected") {
        _ipController.text = provider.esp32CamIp;
      }
    });

    _frameTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => _fetchDirectFrame());
  }

  @override
  void dispose() {
    _frameTimer?.cancel();
    _ipController.dispose();
    super.dispose();
  }

  String get _currentIp => _ipController.text.trim();

  Future<void> _fetchDirectFrame() async {
    final ip = _currentIp;
    if (ip.isEmpty || _isFetchingFrame) return;
    _isFetchingFrame = true;

    try {
      final url = Uri.parse("http://$ip/capture");
      final response = await http.get(url).timeout(const Duration(milliseconds: 600));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        if (mounted) {
          setState(() {
            _directImageBytes = response.bodyBytes;
            _directConnected = true;
          });
        }
      }
    } catch (_) {
      // Retain last frame, fallback gracefully
    } finally {
      _isFetchingFrame = false;
    }
  }

  Future<void> _sendSetting(String varName, dynamic value) async {
    final ip = _currentIp;
    if (ip.isEmpty) return;

    final directUrl = Uri.parse("http://$ip/control?var=$varName&val=$value");
    setState(() {
      _isSending = true;
      _statusLog = "Sending $varName=$value to http://$ip/...";
    });

    try {
      final response = await http.get(directUrl).timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        setState(() {
          _statusLog = "SUCCESS (Direct): Updated $varName = $value";
        });
        return;
      }
    } catch (_) {
      // Direct HTTP timed out or failed (AP isolation / subnet mismatch). Try backend proxy relay.
      setState(() {
        _statusLog = "Direct HTTP timed out. Retrying via Backend Proxy...";
      });
      try {
        final proxyUrl = Uri.parse("http://127.0.0.1:8000/api/esp32cam/control?ip=$ip&var=$varName&val=$value");
        final proxyResponse = await http.get(proxyUrl).timeout(const Duration(seconds: 3));
        if (proxyResponse.statusCode == 200) {
          setState(() {
            _statusLog = "SUCCESS (Proxy Relay): Updated $varName = $value";
          });
          return;
        }
      } catch (proxyError) {
        setState(() {
          _statusLog = "Connection Error: Cannot reach ESP32 at $ip (Subnet Mismatch / AP Isolation)";
        });
      }
    } finally {
      setState(() {
        _isSending = false;
      });
    }
  }

  void _openWebPortalInBrowser() {
    final ip = _currentIp;
    if (ip.isEmpty) return;
    final url = "http://$ip/";
    try {
      if (Platform.isWindows) {
        Process.run('cmd', ['/c', 'start', url]);
      } else if (Platform.isMacOS) {
        Process.run('open', [url]);
      } else if (Platform.isLinux) {
        Process.run('xdg-open', [url]);
      }
      setState(() {
        _statusLog = "Opened $url in browser";
      });
    } catch (e) {
      setState(() {
        _statusLog = "Could not launch browser: $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RobotStateProvider>(context);
    final bool isConnected = provider.esp32CamConnected || _directConnected;
    final String frameB64 = provider.cameraFrame;

    final String activeIp = provider.esp32CamIp;
    if (activeIp.isNotEmpty && activeIp != "Disconnected" && (_ipController.text == "10.50.94.34" || _ipController.text.isEmpty)) {
      _ipController.text = activeIp;
    }

    Uint8List? imageBytes;
    if (frameB64.isNotEmpty) {
      try {
        imageBytes = base64Decode(frameB64);
      } catch (_) {}
    }
    imageBytes ??= _directImageBytes;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header Title Card ─────────────────────────────────────────────
          _buildHeaderCard(isConnected),
          const SizedBox(height: 20),

          // ── Connection & Web Portal Bar ───────────────────────────────────
          _buildConnectionBar(),
          const SizedBox(height: 20),

          // ── Main Body Split: Live Camera View + Camera Controls ─────────────
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > 900;
              return isWide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 5,
                          child: Column(
                            children: [
                              _buildLiveStreamBox(imageBytes, isConnected, provider),
                              const SizedBox(height: 16),
                              _buildStatusLogBox(),
                            ],
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          flex: 6,
                          child: _buildOv2640ControlsPanel(),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        _buildLiveStreamBox(imageBytes, isConnected, provider),
                        const SizedBox(height: 16),
                        _buildStatusLogBox(),
                        const SizedBox(height: 20),
                        _buildOv2640ControlsPanel(),
                      ],
                    );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderCard(bool isConnected) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: HudColors.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: HudColors.teal.withValues(alpha: 0.4), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: HudColors.teal.withValues(alpha: 0.05),
            blurRadius: 15,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: HudColors.teal.withValues(alpha: 0.15),
              shape: BoxShape.circle,
              border: Border.all(color: HudColors.teal),
            ),
            child: const Icon(Icons.videocam_rounded, color: HudColors.teal, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  "ESP32-CAM HARDWARE CONTROL & MANAGEMENT HUB",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    letterSpacing: 1.2,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  "Centralized Live Video Feed, Sensor Calibration, and OV2640 Camera Settings (http://10.225.36.236/)",
                  style: TextStyle(color: HudColors.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: (isConnected ? HudColors.teal : Colors.redAccent).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isConnected ? HudColors.teal : Colors.redAccent),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isConnected ? HudColors.teal : Colors.redAccent,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  isConnected ? "HARDWARE ONLINE" : "HARDWARE OFFLINE",
                  style: TextStyle(
                    color: isConnected ? HudColors.teal : Colors.redAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F151F),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          const Icon(Icons.wifi_tethering_rounded, color: HudColors.teal, size: 20),
          const SizedBox(width: 12),
          const Text(
            "ESP32-CAM IP:",
            style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 12),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 160,
            child: TextField(
              controller: _ipController,
              style: const TextStyle(color: HudColors.teal, fontWeight: FontWeight.bold, fontSize: 13, fontFamily: 'monospace'),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                filled: true,
                fillColor: Colors.black26,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: HudColors.teal),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: HudColors.teal.withValues(alpha: 0.5)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            onPressed: () => _sendSetting("status", "1"),
            icon: const Icon(Icons.sync_rounded, size: 16),
            label: const Text("Ping / Sync", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: HudColors.teal.withValues(alpha: 0.2),
              foregroundColor: HudColors.teal,
              side: const BorderSide(color: HudColors.teal),
            ),
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: _openWebPortalInBrowser,
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: Text("Open Portal ($_currentIp)", style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E293B),
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white30),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveStreamBox(Uint8List? imageBytes, bool isConnected, RobotStateProvider provider) {
    final detections = provider.visionDetections;

    return Container(
      decoration: BoxDecoration(
        color: HudColors.cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: HudColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              color: Color(0xFF0F151F),
              borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(
              children: [
                const Icon(Icons.videocam_outlined, color: HudColors.teal, size: 18),
                const SizedBox(width: 8),
                const Text(
                  "LIVE CAMERA STREAM & AI VISION DETECTIONS",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                ),
                const Spacer(),
                Text(
                  "${provider.esp32CamFps} FPS",
                  style: const TextStyle(color: HudColors.teal, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          Container(
            height: 320,
            width: double.infinity,
            color: Colors.black,
            child: imageBytes != null
                ? Stack(
                    children: [
                      Center(
                        child: Image.memory(
                          imageBytes,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                      ),
                      // Draw AI Bounding Boxes overlay
                      for (final det in detections) _buildDetectionOverlay(det),
                    ],
                  )
                : Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.videocam_off_rounded,
                          size: 48,
                          color: isConnected ? HudColors.teal : Colors.grey.shade700,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          isConnected
                              ? "Waiting for Camera Stream from http://$_currentIp/..."
                              : "ESP32-CAM Module Offline (http://$_currentIp/)",
                          style: TextStyle(
                            color: isConnected ? HudColors.teal : Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _flashLed = !_flashLed;
                    });
                    _sendSetting("flash", _flashLed ? "1" : "0");
                  },
                  icon: Icon(
                    _flashLed ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                    size: 16,
                    color: _flashLed ? Colors.amber : Colors.white70,
                  ),
                  label: Text(_flashLed ? "Flash LED ON" : "Flash LED OFF"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _flashLed ? Colors.amber.withValues(alpha: 0.2) : Colors.white10,
                    foregroundColor: _flashLed ? Colors.amber : Colors.white70,
                    side: BorderSide(color: _flashLed ? Colors.amber : Colors.white24),
                  ),
                ),
                Text(
                  "Resolution: ${provider.esp32CamResolution}",
                  style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetectionOverlay(Map<String, dynamic> det) {
    final String label = det["label"] ?? "Object";
    final double conf = (det["confidence"] as num?)?.toDouble() ?? 0.0;
    final List bbox = det["bbox"] as List? ?? [0, 0, 0, 0];

    if (bbox.length < 4) return const SizedBox.shrink();

    final double x = (bbox[0] as num).toDouble();
    final double y = (bbox[1] as num).toDouble();
    final double w = (bbox[2] as num).toDouble();
    final double h = (bbox[3] as num).toDouble();

    return Positioned(
      left: x * 320,
      top: y * 240,
      width: w * 320,
      height: h * 240,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: HudColors.teal, width: 2),
          color: HudColors.teal.withValues(alpha: 0.1),
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            color: HudColors.teal,
            child: Text(
              "$label ${(conf * 100).toStringAsFixed(0)}%",
              style: const TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusLogBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F151F),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          const Icon(Icons.terminal_rounded, color: HudColors.teal, size: 16),
          const SizedBox(width: 8),
          const Text("LOG:", style: TextStyle(color: HudColors.teal, fontWeight: FontWeight.bold, fontSize: 11)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _statusLog,
              style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_isSending)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: HudColors.teal),
            ),
        ],
      ),
    );
  }

  Widget _buildOv2640ControlsPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: HudColors.cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: HudColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.tune_rounded, color: HudColors.teal, size: 20),
              SizedBox(width: 10),
              Text(
                "OV2640 HARDWARE CAMERA SETTINGS",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
          const Divider(color: Colors.white12, height: 20),

          // Resolution Dropdown
          _buildDropdownRow("Resolution", _resolutions.map((r) => r["label"] as String).toList(), _resolutionIndex, (idx) {
            setState(() => _resolutionIndex = idx);
            _sendSetting("framesize", _resolutions[idx]["val"]);
          }),

          // Quality Slider
          _buildSliderRow("Quality (JPEG Compression)", _quality, 4, 63, (val) {
            setState(() => _quality = val);
            _sendSetting("quality", val.round());
          }),

          // Brightness Slider
          _buildSliderRow("Brightness", _brightness, -2, 2, (val) {
            setState(() => _brightness = val);
            _sendSetting("brightness", val.round());
          }),

          // Contrast Slider
          _buildSliderRow("Contrast", _contrast, -2, 2, (val) {
            setState(() => _contrast = val);
            _sendSetting("contrast", val.round());
          }),

          // Saturation Slider
          _buildSliderRow("Saturation", _saturation, -2, 2, (val) {
            setState(() => _saturation = val);
            _sendSetting("saturation", val.round());
          }),

          // Special Effect Dropdown
          _buildDropdownRow("Special Effect", _specialEffectsList, _specialEffect, (idx) {
            setState(() => _specialEffect = idx);
            _sendSetting("special_effect", idx);
          }),

          const SizedBox(height: 10),
          const Divider(color: Colors.white12),
          const SizedBox(height: 6),

          // Toggles Section
          Row(
            children: [
              Expanded(child: _buildSwitchRow("AWB (Auto White Bal)", _awb, (v) {
                setState(() => _awb = v);
                _sendSetting("awb", v ? "1" : "0");
              })),
              Expanded(child: _buildSwitchRow("AWB Gain", _awbGain, (v) {
                setState(() => _awbGain = v);
                _sendSetting("awb_gain", v ? "1" : "0");
              })),
            ],
          ),

          // WB Mode Dropdown
          _buildDropdownRow("WB Mode", _wbModesList, _wbMode, (idx) {
            setState(() => _wbMode = idx);
            _sendSetting("wb_mode", idx);
          }),

          Row(
            children: [
              Expanded(child: _buildSwitchRow("AEC Sensor", _aecSensor, (v) {
                setState(() => _aecSensor = v);
                _sendSetting("aec", v ? "1" : "0");
              })),
              Expanded(child: _buildSwitchRow("AEC DSP", _aecDsp, (v) {
                setState(() => _aecDsp = v);
                _sendSetting("aec2", v ? "1" : "0");
              })),
            ],
          ),

          _buildSliderRow("AE Level", _aeLevel, -2, 2, (val) {
            setState(() => _aeLevel = val);
            _sendSetting("ae_level", val.round());
          }),

          Row(
            children: [
              Expanded(child: _buildSwitchRow("AGC (Auto Gain)", _agc, (v) {
                setState(() => _agc = v);
                _sendSetting("agc", v ? "1" : "0");
              })),
              Expanded(child: _buildSwitchRow("Raw GMA", _rawGma, (v) {
                setState(() => _rawGma = v);
                _sendSetting("raw_gma", v ? "1" : "0");
              })),
            ],
          ),

          _buildDropdownRow("Gain Ceiling", _gainCeilingList, _gainCeiling, (idx) {
            setState(() => _gainCeiling = idx);
            _sendSetting("gainceiling", idx);
          }),

          Row(
            children: [
              Expanded(child: _buildSwitchRow("BPC (Black Pixel)", _bpc, (v) {
                setState(() => _bpc = v);
                _sendSetting("bpc", v ? "1" : "0");
              })),
              Expanded(child: _buildSwitchRow("WPC (White Pixel)", _wpc, (v) {
                setState(() => _wpc = v);
                _sendSetting("wpc", v ? "1" : "0");
              })),
            ],
          ),

          Row(
            children: [
              Expanded(child: _buildSwitchRow("Lens Correction", _lensCorrection, (v) {
                setState(() => _lensCorrection = v);
                _sendSetting("lenc", v ? "1" : "0");
              })),
              Expanded(child: _buildSwitchRow("DCW (Downsize EN)", _dcw, (v) {
                setState(() => _dcw = v);
                _sendSetting("dcw", v ? "1" : "0");
              })),
            ],
          ),

          Row(
            children: [
              Expanded(child: _buildSwitchRow("H-Mirror", _hMirror, (v) {
                setState(() => _hMirror = v);
                _sendSetting("hmirror", v ? "1" : "0");
              })),
              Expanded(child: _buildSwitchRow("V-Mirror", _vMirror, (v) {
                setState(() => _vMirror = v);
                _sendSetting("vflip", v ? "1" : "0");
              })),
            ],
          ),

          _buildSwitchRow("Color Bar Test Pattern", _colorBar, (v) {
            setState(() => _colorBar = v);
            _sendSetting("colorbar", v ? "1" : "0");
          }),
        ],
      ),
    );
  }

  Widget _buildSliderRow(String label, double val, double min, double max, ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
              Text(val.round().toString(), style: const TextStyle(color: HudColors.teal, fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'monospace')),
            ],
          ),
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              activeTrackColor: HudColors.teal,
              inactiveTrackColor: Colors.white12,
              thumbColor: HudColors.teal,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: val.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSwitchRow(String label, bool val, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11))),
          Switch(
            value: val,
            onChanged: onChanged,
            activeThumbColor: HudColors.teal,
            activeTrackColor: HudColors.teal.withValues(alpha: 0.3),
            inactiveThumbColor: Colors.grey,
            inactiveTrackColor: Colors.white10,
          ),
        ],
      ),
    );
  }

  Widget _buildDropdownRow(String label, List<String> options, int currentIdx, ValueChanged<int> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF0F151F),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: HudColors.border),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: currentIdx.clamp(0, options.length - 1),
                dropdownColor: const Color(0xFF0F151F),
                isDense: true,
                style: const TextStyle(color: HudColors.teal, fontSize: 11, fontWeight: FontWeight.bold),
                items: List.generate(options.length, (i) {
                  return DropdownMenuItem<int>(
                    value: i,
                    child: Text(options[i]),
                  );
                }),
                onChanged: (val) {
                  if (val != null) onChanged(val);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
