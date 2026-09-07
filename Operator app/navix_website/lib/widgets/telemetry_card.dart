import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:navix_app/providers/robot_state_provider.dart';
import 'package:navix_app/utils/hud_colors.dart';
import 'package:navix_app/widgets/hud_animations.dart';

class TelemetryCard extends StatelessWidget {
  const TelemetryCard({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RobotStateProvider>(context);
    
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: HudColors.cardBg.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: HudColors.border,
              width: 1.5,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.analytics_outlined, color: HudColors.teal, size: 18),
                      SizedBox(width: 8),
                      Text(
                        "SYSTEM TELEMETRY STATUS",
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  // Connection badge using PulsingGlow
                  Row(
                    children: [
                      PulsingGlowIndicator(
                        color: provider.esp32Connected ? HudColors.teal : HudColors.magenta,
                        size: 6,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        provider.esp32Connected ? "ESP32: ON" : "ESP32: OFF",
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: provider.esp32Connected ? HudColors.teal : HudColors.magenta,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const Divider(color: HudColors.border, height: 20, thickness: 1),

              // Progress bar for active mission
              if (provider.missionStatus == "RUNNING" || provider.missionStatus == "COMPLETED" || provider.missionStatus == "PAUSED") ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "MISSION PROGRESS: ${provider.missionProgress.toStringAsFixed(1)}%",
                      style: const TextStyle(
                        color: HudColors.textMuted,
                        fontSize: 10,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      provider.missionStatus,
                      style: TextStyle(
                        color: provider.missionStatus == "RUNNING" 
                            ? HudColors.teal 
                            : provider.missionStatus == "COMPLETED" 
                                ? HudColors.teal 
                                : HudColors.amber,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: provider.missionProgress / 100.0,
                    minHeight: 4,
                    backgroundColor: HudColors.bg,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      provider.missionStatus == "RUNNING" 
                          ? HudColors.teal 
                          : provider.missionStatus == "COMPLETED" 
                              ? HudColors.teal 
                              : HudColors.amber,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // Wrap parameters (5 compact columns for a neat desktop row)
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.start,
                children: [
                  // Mode
                  SizedBox(
                    width: 150,
                    height: 50,
                    child: _buildTelemetryItem(
                      label: "DRIVE MODE",
                      value: provider.robotMode.toUpperCase(),
                      icon: provider.robotMode == "auto" ? Icons.smart_toy_outlined : Icons.settings_remote_outlined,
                      color: provider.robotMode == "auto" ? HudColors.teal : HudColors.amber,
                    ),
                  ),
                  // Current Checkpoint
                  SizedBox(
                    width: 150,
                    height: 50,
                    child: _buildTelemetryItem(
                      label: "CURRENT NODE",
                      value: provider.currentCheckpoint.isNotEmpty ? provider.currentCheckpoint : "STANDBY",
                      icon: Icons.location_on_outlined,
                      color: HudColors.teal,
                    ),
                  ),
                  // Next Checkpoint
                  SizedBox(
                    width: 150,
                    height: 50,
                    child: _buildTelemetryItem(
                      label: "NEXT WAYPOINT",
                      value: provider.nextCheckpoint.isNotEmpty ? provider.nextCheckpoint : "END",
                      icon: Icons.navigation_outlined,
                      color: provider.nextCheckpoint.isNotEmpty ? HudColors.teal : HudColors.textMuted,
                    ),
                  ),
                  // Speed
                  SizedBox(
                    width: 150,
                    height: 50,
                    child: _buildTelemetryItem(
                      label: "MOTOR SPEED",
                      value: "${provider.robotSpeed} / 255",
                      icon: Icons.speed,
                      color: HudColors.teal,
                    ),
                  ),
                  // Last Command
                  SizedBox(
                    width: 150,
                    height: 50,
                    child: _buildTelemetryItem(
                      label: "ACTIVE COMMAND",
                      value: provider.activeCommand,
                      icon: Icons.terminal,
                      color: provider.activeCommand == "STOP" ? HudColors.magenta : HudColors.teal,
                    ),
                  ),
                ],
              ),
              if (provider.purePursuitEnabled) ...[
                const SizedBox(height: 12),
                const Divider(color: HudColors.border, height: 10, thickness: 1),
                const SizedBox(height: 6),
                const Row(
                  children: [
                    Icon(Icons.alt_route_rounded, color: HudColors.teal, size: 14),
                    SizedBox(width: 8),
                    Text(
                      "PURE PURSUIT NAVIGATION TELEMETRY",
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.0,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.start,
                  children: [
                    // Pure Pursuit Status
                    SizedBox(
                      width: 150,
                      height: 50,
                      child: _buildTelemetryItem(
                        label: "TRACKER STATUS",
                        value: provider.purePursuitStatus,
                        icon: Icons.track_changes_rounded,
                        color: provider.purePursuitStatus == "RUNNING"
                            ? HudColors.teal
                            : provider.purePursuitStatus == "PAUSED"
                                ? HudColors.amber
                                : HudColors.textMuted,
                      ),
                    ),
                    // Trajectory Progress
                    SizedBox(
                      width: 150,
                      height: 50,
                      child: _buildTelemetryItem(
                        label: "TRAJECTORY PROGRESS",
                        value: "${provider.trajectoryProgress.toStringAsFixed(1)}%",
                        icon: Icons.donut_large_rounded,
                        color: HudColors.teal,
                      ),
                    ),
                    // Look Ahead Point
                    SizedBox(
                      width: 150,
                      height: 50,
                      child: _buildTelemetryItem(
                        label: "LOOK-AHEAD POINT",
                        value: "(${provider.lookAheadPoint["x"]?.toStringAsFixed(1) ?? '0.0'}, ${provider.lookAheadPoint["y"]?.toStringAsFixed(1) ?? '0.0'})",
                        icon: Icons.gps_fixed_rounded,
                        color: HudColors.teal,
                      ),
                    ),
                    // Heading & Desired Heading
                    SizedBox(
                      width: 150,
                      height: 50,
                      child: _buildTelemetryItem(
                        label: "HEADING (CURR/DES)",
                        value: "${(provider.robotHeading * 180 / math.pi).toStringAsFixed(0)}° / ${(provider.desiredHeading * 180 / math.pi).toStringAsFixed(0)}°",
                        icon: Icons.compass_calibration_rounded,
                        color: HudColors.teal,
                      ),
                    ),
                    // Heading Error
                    SizedBox(
                      width: 150,
                      height: 50,
                      child: _buildTelemetryItem(
                        label: "HEADING ERROR",
                        value: "${(provider.headingError * 180 / math.pi).toStringAsFixed(1)}°",
                        icon: Icons.error_outline_rounded,
                        color: provider.headingError.abs() * 180 / math.pi < 5.0
                            ? HudColors.teal
                            : (provider.headingError.abs() * 180 / math.pi < 15.0 ? HudColors.amber : HudColors.magenta),
                      ),
                    ),
                    // Cross Track Error
                    SizedBox(
                      width: 150,
                      height: 50,
                      child: _buildTelemetryItem(
                        label: "CROSS TRACK ERROR",
                        value: "${(provider.crossTrackError * 100).toStringAsFixed(1)} cm",
                        icon: Icons.sync_alt_rounded,
                        color: provider.crossTrackError < 0.1
                            ? HudColors.teal
                            : (provider.crossTrackError < 0.25 ? HudColors.amber : HudColors.magenta),
                      ),
                    ),
                    // Curve Radius
                    SizedBox(
                      width: 150,
                      height: 50,
                      child: _buildTelemetryItem(
                        label: "CURVE RADIUS",
                        value: provider.curveRadius > 990
                            ? "∞ (Straight)"
                            : "${provider.curveRadius.toStringAsFixed(2)} m",
                        icon: Icons.radar_rounded,
                        color: HudColors.teal,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),

              // Bottom status bar / telemetry logs
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: HudColors.bg,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: HudColors.border, width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "ESP32 TELEMETRY OUTPUT:",
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: HudColors.textMuted,
                          ),
                        ),
                        Text(
                          "COORD: (${provider.robotX.toStringAsFixed(0)}, ${provider.robotY.toStringAsFixed(0)})",
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: HudColors.teal,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      provider.lastApiResponse,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: HudColors.teal,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTelemetryItem({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: HudColors.bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: HudColors.border,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: color.withValues(alpha: 0.8), size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: HudColors.textMuted,
                    fontSize: 7,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    shadows: [
                      Shadow(
                        color: color.withValues(alpha: 0.3),
                        blurRadius: 4,
                      )
                    ]
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
