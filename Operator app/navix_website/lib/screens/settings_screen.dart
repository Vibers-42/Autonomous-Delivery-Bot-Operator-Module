import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:navix_app/providers/robot_state_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _esp32IpController;
  late TextEditingController _backendIpController;
  late TextEditingController _wifiSsidController;
  late TextEditingController _wifiPassController;
  late double _calibrationOffset;
  late int _tunedSpeed;
  late bool _isDarkTheme;

  @override
  void initState() {
    super.initState();
    // Fetch values from provider on load
    final provider = Provider.of<RobotStateProvider>(context, listen: false);
    _esp32IpController = TextEditingController(text: provider.esp32Ip);
    _backendIpController = TextEditingController(text: provider.backendIp);
    _wifiSsidController = TextEditingController(text: "Navix_RoboNet");
    _wifiPassController = TextEditingController(text: "AMR_Pass123");
    _calibrationOffset = provider.calibrationOffset;
    _tunedSpeed = provider.tunedSpeed;
    _isDarkTheme = provider.isDarkTheme;
  }

  @override
  void dispose() {
    _esp32IpController.dispose();
    _backendIpController.dispose();
    _wifiSsidController.dispose();
    _wifiPassController.dispose();
    super.dispose();
  }

  void _saveSettings(BuildContext context) {
    if (_formKey.currentState!.validate()) {
      final provider = Provider.of<RobotStateProvider>(context, listen: false);
      provider.updateSettings(
        esp32Ip: _esp32IpController.text,
        backendIp: _backendIpController.text,
        calibrationOffset: _calibrationOffset,
        tunedSpeed: _tunedSpeed,
        isDarkTheme: _isDarkTheme,
      );



      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Console configuration saved and synced!"),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            const Text(
              "CONSOLE CONFIGURATION",
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
              ),
            ),
            const Text(
              "Calibrate motor parameters, wireless connection nodes, and dashboard cosmetics.",
              style: TextStyle(
                color: Color(0xFF5A6F8F),
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),

            LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth > 800;
                return Column(
                  children: [
                    isWide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _buildNetworkCard()),
                              const SizedBox(width: 24),
                              Expanded(child: _buildCalibrationCard()),
                            ],
                          )
                        : Column(
                            children: [
                              _buildNetworkCard(),
                              const SizedBox(height: 24),
                              _buildCalibrationCard(),
                            ],
                          ),
                    const SizedBox(height: 24),
                    _buildCosmeticsCard(),
                    const SizedBox(height: 24),

                    const SizedBox(height: 32),

                    // Save Button
                    ElevatedButton.icon(
                      onPressed: () => _saveSettings(context),
                      icon: const Icon(Icons.save_rounded, color: Colors.black),
                      label: const Text(
                        "SAVE & SYNC CONFIGURATION",
                        style: TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00FFCC),
                        minimumSize: const Size(double.infinity, 50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNetworkCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF131B26),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E2E43), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.settings_ethernet_rounded,
                color: Color(0xFF00FFCC),
                size: 18,
              ),
              SizedBox(width: 8),
              Text(
                "HARDWARE IP CONNECTIONS",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const Divider(color: Color(0xFF1E2E43), height: 24),

          // ESP32 IP
          _buildTextField(
            label: "Robot ESP32 Base IP Address",
            controller: _esp32IpController,
            hint: "e.g., 192.168.4.1",
            validator: (val) {
              if (val == null || val.isEmpty) return "IP address is required";
              return null;
            },
          ),
          const SizedBox(height: 16),

          // Backend IP
          _buildTextField(
            label: "FastAPI AI Backend Address",
            controller: _backendIpController,
            hint: "e.g., 127.0.0.1:8000",
            validator: (val) {
              if (val == null || val.isEmpty) {
                return "Backend address is required";
              }
              return null;
            },
          ),
          const SizedBox(height: 16),

          // Wifi SSID
          _buildTextField(
            label: "Robot WiFi Access Point SSID",
            controller: _wifiSsidController,
            hint: "SSID network name",
          ),
          const SizedBox(height: 16),

          // Wifi Pass
          _buildTextField(
            label: "Robot WiFi AP WPA2 Password",
            controller: _wifiPassController,
            hint: "WiFi Password",
            obscure: true,
          ),
        ],
      ),
    );
  }

  Widget _buildCalibrationCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF131B26),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E2E43), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.build_circle_outlined,
                color: Color(0xFF00FF66),
                size: 18,
              ),
              SizedBox(width: 8),
              Text(
                "ROBOT STEERING & MOTOR TUNING",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const Divider(color: Color(0xFF1E2E43), height: 24),

          // Tuned Speed
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Motor Cruise Velocity Limit",
                style: TextStyle(color: Color(0xFF8F9BB3), fontSize: 11),
              ),
              Text(
                "$_tunedSpeed / 255 PWM",
                style: const TextStyle(
                  color: Color(0xFF00FFCC),
                  fontFamily: 'monospace',
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          Slider(
            value: _tunedSpeed.toDouble(),
            min: 0,
            max: 255,
            divisions: 255,
            activeColor: const Color(0xFF00FFCC),
            inactiveColor: const Color(0xFF0C1017),
            onChanged: (val) {
              setState(() {
                _tunedSpeed = val.round();
              });
            },
          ),
          const SizedBox(height: 20),

          // Calibration Offset
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Wheel Alignment Offset Bias",
                style: TextStyle(color: Color(0xFF8F9BB3), fontSize: 11),
              ),
              Text(
                "${_calibrationOffset.toStringAsFixed(1)}° skew",
                style: const TextStyle(
                  color: Color(0xFF00FF66),
                  fontFamily: 'monospace',
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          Slider(
            value: _calibrationOffset,
            min: -15.0,
            max: 15.0,
            divisions: 30,
            activeColor: const Color(0xFF00FF66),
            inactiveColor: const Color(0xFF0C1017),
            onChanged: (val) {
              setState(() {
                _calibrationOffset = val;
              });
            },
          ),
          const SizedBox(height: 16),
          const Text(
            "TUNE BIAS ASSISTANCE:",
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 9,
              color: Color(0xFF5A6F8F),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            "Skew offset adjusts individual wheel rotation speeds. If the AMR drifts left during FORWARD, adjust offset to the positive range (+ skew).",
            style: TextStyle(color: Color(0xFF6B7A90), fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildCosmeticsCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF131B26),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E2E43), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.palette_outlined, color: Color(0xFFCC00FF), size: 18),
              SizedBox(width: 8),
              Text(
                "CONSOLE COSMETIC THEMING",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const Divider(color: Color(0xFF1E2E43), height: 24),

          // Theme Switch
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "High-Contrast Industrial Dark Mode",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    "Renders neon UI vectors on deep carbon black backgrounds.",
                    style: TextStyle(color: Color(0xFF5A6F8F), fontSize: 10),
                  ),
                ],
              ),
              Switch(
                value: _isDarkTheme,
                activeThumbColor: const Color(0xFFCC00FF),
                activeTrackColor: const Color(0xFFCC00FF).withValues(alpha: 0.3),
                inactiveThumbColor: const Color(0xFF1E2E43),
                inactiveTrackColor: const Color(0xFF0F141C),
                onChanged: (val) {
                  setState(() {
                    _isDarkTheme = val;
                  });
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    required String hint,
    String? Function(String?)? validator,
    bool obscure = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF8F9BB3),
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          obscureText: obscure,
          validator: validator,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontFamily: 'monospace',
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF3E4E63), fontSize: 12),
            filled: true,
            fillColor: const Color(0xFF0C1017),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            enabledBorder: OutlineInputBorder(
              borderSide: const BorderSide(
                color: Color(0xFF1E2E43),
                width: 1.5,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: const BorderSide(
                color: Color(0xFF00FFCC),
                width: 1.5,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            errorBorder: OutlineInputBorder(
              borderSide: const BorderSide(
                color: Color(0xFFFF3366),
                width: 1.5,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderSide: const BorderSide(
                color: Color(0xFFFF3366),
                width: 2.0,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ],
    );
  }
}
