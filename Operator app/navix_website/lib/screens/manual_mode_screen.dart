import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:navix_app/providers/robot_state_provider.dart';
import 'package:navix_app/utils/hud_colors.dart';
import 'package:navix_app/widgets/generated_navigation_map.dart';
import 'package:navix_app/widgets/telemetry_card.dart';

class ManualModeScreen extends StatelessWidget {
  const ManualModeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RobotStateProvider>(context);
    final isManual = provider.robotMode == "manual";

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "MANUAL OVERRIDE BAY",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                    ),
                  ),
                  Text(
                    "Direct hardware bypass: steering commands route directly to the actuators.",
                    style: TextStyle(
                      color: HudColors.textDim,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),

              // Override Toggle
              Row(
                children: [
                  Text(
                    isManual ? "MANUAL OVERRIDE: ON" : "MANUAL OVERRIDE: OFF",
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: isManual ? HudColors.amber : HudColors.textMuted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    value: isManual,
                    activeThumbColor: HudColors.amber,
                    activeTrackColor: HudColors.amber.withValues(alpha: 0.3),
                    inactiveThumbColor: HudColors.textMuted,
                    inactiveTrackColor: HudColors.bg,
                    onChanged: (val) {
                      provider.switchMode(val ? "manual" : "auto");
                    },
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Layout splits control pad and live status map (always side-by-side for desktop)
          Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: _buildMapSection(provider, height: 480),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    flex: 2,
                    child: _buildControlSection(provider, isManual),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildRampControlSection(context, provider),
              const SizedBox(height: 16),
              const TelemetryCard(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMapSection(RobotStateProvider provider, {double height = 450}) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: HudColors.cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: HudColors.border, width: 1.5),
      ),
      child: const ClipRRect(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(8),
          topRight: Radius.circular(8),
        ),
        child: GeneratedNavigationMap(),
      ),
    );
  }

  Widget _buildControlSection(RobotStateProvider provider, bool isManual) {
    return Stack(
      children: [
        // Joystick & Slider controls
        Container(
          padding: const EdgeInsets.all(20),
          height: 480,
          decoration: BoxDecoration(
            color: HudColors.cardBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isManual ? HudColors.amber.withValues(alpha: 0.5) : HudColors.border,
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "STEERING INTERRUPT CONTROLLER",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 1.2,
                ),
              ),
              const Divider(color: HudColors.border, height: 16),

              // 1. Driving Grid (Cross D-Pad)
              Expanded(
                child: Center(
                  child: _buildSteeringPad(provider),
                ),
              ),
              const Divider(color: HudColors.border, height: 16),

              // 2. Speed Slider
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "MOTOR OUTPUT SETPOINT",
                        style: TextStyle(
                          color: HudColors.textDim,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        "${provider.robotSpeed} / 255",
                        style: const TextStyle(
                          color: HudColors.teal,
                          fontFamily: 'monospace',
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Slider(
                    value: provider.robotSpeed.toDouble(),
                    min: 0,
                    max: 255,
                    divisions: 255,
                    activeColor: HudColors.amber,
                    inactiveColor: HudColors.bg,
                    onChanged: isManual
                        ? (val) => provider.adjustSpeed(val.round())
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ),

        // Lock Overlay if not in manual mode
        if (!isManual)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: HudColors.bg.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: HudColors.border),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.lock_outline_rounded,
                    color: HudColors.amber,
                    size: 32,
                  ),
                  SizedBox(height: 12),
                  Text(
                    "OVERRIDE OFFLINE",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      letterSpacing: 1.5,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    "Engage override switch to acquire manual controls.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: HudColors.textMuted, fontSize: 10),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSteeringPad(RobotStateProvider provider) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Calculate the maximum possible size for the square D-pad container
        final double maxAvailable = constraints.maxWidth < constraints.maxHeight
            ? constraints.maxWidth
            : constraints.maxHeight;

        // Scale between 180.0 and 340.0 depending on constraints, defaulting to 300.0 if not constrained
        final double size = maxAvailable.isInfinite || maxAvailable <= 0
            ? 300.0
            : maxAvailable.clamp(180.0, 340.0);

        // Proportional sizing based on the total D-pad size
        final double buttonSize = size / 3.3;
        final double gap = buttonSize * 0.15;
        final double borderRadius = buttonSize * 0.15;
        final double iconSize = buttonSize * 0.55;

        return SizedBox(
          width: size,
          height: size,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Row 1: Forward
              _buildSteeringButton(
                icon: Icons.keyboard_arrow_up_rounded,
                direction: "FORWARD",
                activeCommand: provider.activeCommand,
                onPressed: () => provider.triggerManualCommand("FORWARD"),
                size: buttonSize,
                borderRadius: borderRadius,
                iconSize: iconSize,
              ),
              SizedBox(height: gap),
              // Row 2: Left, Stop, Right
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildSteeringButton(
                    icon: Icons.keyboard_arrow_left_rounded,
                    direction: "LEFT",
                    activeCommand: provider.activeCommand,
                    onPressed: () => provider.triggerManualCommand("LEFT"),
                    size: buttonSize,
                    borderRadius: borderRadius,
                    iconSize: iconSize,
                  ),
                  SizedBox(width: gap),
                  _buildSteeringButton(
                    icon: Icons.stop_circle_rounded,
                    direction: "STOP",
                    activeCommand: provider.activeCommand,
                    onPressed: () => provider.triggerManualCommand("STOP"),
                    isStop: true,
                    size: buttonSize,
                    borderRadius: borderRadius,
                    iconSize: iconSize,
                  ),
                  SizedBox(width: gap),
                  _buildSteeringButton(
                    icon: Icons.keyboard_arrow_right_rounded,
                    direction: "RIGHT",
                    activeCommand: provider.activeCommand,
                    onPressed: () => provider.triggerManualCommand("RIGHT"),
                    size: buttonSize,
                    borderRadius: borderRadius,
                    iconSize: iconSize,
                  ),
                ],
              ),
              SizedBox(height: gap),
              // Row 3: Backward
              _buildSteeringButton(
                icon: Icons.keyboard_arrow_down_rounded,
                direction: "BACKWARD",
                activeCommand: provider.activeCommand,
                onPressed: () => provider.triggerManualCommand("BACKWARD"),
                size: buttonSize,
                borderRadius: borderRadius,
                iconSize: iconSize,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSteeringButton({
    required IconData icon,
    required String direction,
    required String activeCommand,
    required VoidCallback onPressed,
    bool isStop = false,
    required double size,
    required double borderRadius,
    required double iconSize,
  }) {
    final bool isActive = activeCommand == direction;
    final Color activeColor = isStop ? HudColors.magenta : HudColors.amber;

    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(borderRadius),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: isActive
              ? activeColor.withValues(alpha: 0.15)
              : HudColors.bg,
          borderRadius: BorderRadius.circular(borderRadius),
          border: Border.all(
            color: isActive ? activeColor : HudColors.border,
            width: 2.0,
          ),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: activeColor.withValues(alpha: 0.15),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Icon(
          icon,
          color: isActive ? activeColor : HudColors.textDim,
          size: iconSize,
        ),
      ),
    );
  }

  Widget _buildRampControlSection(BuildContext context, RobotStateProvider provider) {
    final bool isOpen = provider.rampStatus == "OPEN";
    
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: HudColors.cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: HudColors.border,
          width: 1.5,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.unfold_more, color: HudColors.teal, size: 16),
              const SizedBox(width: 8),
              const Text(
                "DELIVERY RAMP DIRECTIVITY",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
          
          Row(
            children: [
              // Small cute buttons
              SizedBox(
                width: 115,
                height: 32,
                child: ElevatedButton(
                  onPressed: () => provider.openRamp(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: HudColors.teal,
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                  ),
                  child: const Text(
                    "OPEN RAMP",
                    style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 115,
                height: 32,
                child: OutlinedButton(
                  onPressed: () => provider.closeRamp(),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: HudColors.border, width: 1),
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                  ),
                  child: const Text(
                    "CLOSE RAMP",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              const Text(
                "STATE: ",
                style: TextStyle(color: HudColors.textMuted, fontSize: 9, fontWeight: FontWeight.bold),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isOpen ? HudColors.teal.withValues(alpha: 0.1) : HudColors.magenta.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                    color: isOpen ? HudColors.teal : HudColors.magenta,
                    width: 0.8,
                  ),
                ),
                child: Text(
                  isOpen ? "DEPLOYED" : "LOCKED",
                  style: TextStyle(
                    color: isOpen ? HudColors.teal : HudColors.magenta,
                    fontSize: 8,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
