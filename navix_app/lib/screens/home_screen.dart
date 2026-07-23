// ignore_for_file: unused_element
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:navix_app/providers/robot_state_provider.dart';
import 'package:navix_app/utils/hud_colors.dart';
import 'package:navix_app/widgets/hud_animations.dart';
import 'package:navix_app/widgets/rolling_sparkline.dart';
import 'package:navix_app/widgets/polar_radar_widget.dart';

class HomeScreen extends StatelessWidget {
  final Function(int) onTabChange;

  const HomeScreen({super.key, required this.onTabChange});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RobotStateProvider>(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Hero Header ─────────────────────────────────────────────────
          _buildHeroHeader(),
          const SizedBox(height: 20),

          // ── Live Telemetry Strip with Rolling Sparklines & Polar Radar ────
          _buildTelemetryStrip(provider),
          const SizedBox(height: 24),

          // ── Mission Wizard ───────────────────────────────────────────────
          _buildMissionWizard(provider),
          const SizedBox(height: 24),

          // ── Obstacle Avoidance Settings Panel ────────────────────────────
          ObstacleAvoidancePanel(provider: provider),
          const SizedBox(height: 24),

          // ── Quick Access Row ─────────────────────────────────────────────
          _buildQuickAccessRow(),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildHeroHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: HudColors.cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: HudColors.border, width: 1.5),
        boxShadow: [
          BoxShadow(color: HudColors.teal.withValues(alpha: 0.02), blurRadius: 20, spreadRadius: 1),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: HudColors.teal.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: HudColors.teal, width: 1),
            ),
            child: const Icon(Icons.precision_manufacturing_rounded, color: HudColors.teal, size: 28),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "NAVIX OPERATOR CONSOLE",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  "Smart Autonomous Mobile Robot (AMR) – Mission Control",
                  style: TextStyle(
                    color: HudColors.textDim,
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

  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildTelemetryStrip(RobotStateProvider provider) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left part: the three sparkline widgets
        Expanded(
          flex: 3,
          child: Row(
            children: [
              Expanded(
                child: _buildTelemetryCard(
                  title: "MOTOR PWM (AVG)",
                  valueWidget: Row(
                    children: [
                      OdometerText(
                        value: (provider.pwmLeft + provider.pwmRight) / 2.0,
                        style: const TextStyle(
                          color: HudColors.teal,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        "duty",
                        style: TextStyle(color: HudColors.textMuted, fontSize: 10, fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                  sparklineVal: (provider.pwmLeft + provider.pwmRight) / 2.0,
                  sparklineColor: HudColors.teal,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildTelemetryCard(
                  title: "BATTERY VOLTAGE",
                  valueWidget: Row(
                    children: [
                      OdometerText(
                        value: provider.battery,
                        decimals: 2,
                        style: TextStyle(
                          color: provider.battery < 11.5 ? HudColors.magenta : HudColors.teal,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        "V",
                        style: TextStyle(color: HudColors.textMuted, fontSize: 10, fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                  sparklineVal: provider.battery,
                  sparklineColor: provider.battery < 11.5 ? HudColors.magenta : HudColors.teal,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildTelemetryCard(
                  title: "RAW GYRO Z",
                  valueWidget: Row(
                    children: [
                      OdometerText(
                        value: provider.gyroZ,
                        decimals: 2,
                        style: const TextStyle(
                          color: HudColors.amber,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        "°/s",
                        style: TextStyle(color: HudColors.textMuted, fontSize: 10, fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                  sparklineVal: provider.gyroZ,
                  sparklineColor: HudColors.amber,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        
        // Right part: the polar radar obstacle sensor
        PolarRadarWidget(distance: provider.distanceSensor),
      ],
    );
  }

  Widget _buildTelemetryCard({
    required String title,
    required Widget valueWidget,
    required double sparklineVal,
    required Color sparklineColor,
  }) {
    return Container(
      height: 120,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: HudColors.cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: HudColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: HudColors.textMuted,
              fontSize: 9,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
          ),
          valueWidget,
          const SizedBox(height: 8),
          Expanded(
            child: Align(
              alignment: Alignment.bottomLeft,
              child: RollingSparkline(
                value: sparklineVal,
                color: sparklineColor,
                width: double.infinity,
                height: 30,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Mission Wizard – the main CTA of the Home screen
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildMissionWizard(RobotStateProvider provider) {
    final bool step1Done = provider.loadedMaps.isNotEmpty || provider.mapLoaded;
    final bool step2Done = provider.mapLoaded && provider.sourceCheckpoint.isNotEmpty;
    final bool step3Done = provider.missionStatus != "NO ACTIVE MISSION";

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: HudColors.cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: HudColors.border, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: HudColors.teal.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(Icons.rocket_launch_rounded, color: HudColors.teal, size: 18),
              ),
              const SizedBox(width: 12),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "START A MISSION",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: 1.5),
                  ),
                  Text(
                    "Follow the 3-step wizard to launch autonomous navigation",
                    style: TextStyle(color: HudColors.textMuted, fontSize: 10),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Step 1 – Design / Choose Map
          _buildWizardStep(
            stepNumber: 1,
            title: "DESIGN OR SELECT FACTORY MAP",
            description: "Build an occupancy-grid map or pick a saved layout to compile waypoints.",
            icon: Icons.map_outlined,
            color: HudColors.teal,
            isDone: step1Done,
            isActive: !step1Done,
            buttonLabel: step1Done ? "MAP COMPILED ✓" : "DESIGN A MAP",
            onTap: step1Done ? null : () => onTabChange(3), // Map Designer tab
          ),

          _buildStepConnector(done: step1Done),

          // Step 2 – Select Checkpoints
          _buildWizardStep(
            stepNumber: 2,
            title: "SELECT CHECKPOINTS",
            description: "Choose a source node and destination node from the loaded map's waypoints.",
            icon: Icons.location_on_outlined,
            color: HudColors.amber,
            isDone: step2Done,
            isActive: step1Done && !step2Done,
            buttonLabel: step2Done
                ? "${provider.sourceCheckpoint} → ${provider.destinationCheckpoint}"
                : "OPEN MISSION PLANNER",
            onTap: step1Done ? () => onTabChange(1) : null, // Mission Planner tab
          ),

          _buildStepConnector(done: step2Done),

          // Step 3 – Begin Trip
          _buildWizardStep(
            stepNumber: 3,
            title: "BEGIN TRIP",
            description: "Calculate the Dijkstra shortest path and launch the autonomous robot navigation.",
            icon: Icons.play_circle_outline_rounded,
            color: HudColors.teal,
            isDone: step3Done,
            isActive: step2Done,
            buttonLabel: step3Done
                ? "MISSION ${provider.missionStatus}"
                : "PLAN & LAUNCH",
            onTap: step2Done ? () => onTabChange(1) : null,
          ),
        ],
      ),
    );
  }

  Widget _buildWizardStep({
    required int stepNumber,
    required String title,
    required String description,
    required IconData icon,
    required Color color,
    required bool isDone,
    required bool isActive,
    required String buttonLabel,
    VoidCallback? onTap,
  }) {
    final Color effectiveColor = isDone ? HudColors.teal : isActive ? color : HudColors.textMuted;
    final Color textColor = isDone || isActive ? Colors.white : HudColors.textMuted;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isActive
            ? color.withValues(alpha: 0.04)
            : isDone
                ? HudColors.teal.withValues(alpha: 0.02)
                : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isActive
              ? color.withValues(alpha: 0.3)
              : isDone
                  ? HudColors.teal.withValues(alpha: 0.2)
                  : HudColors.border,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          // Step indicator circle
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: effectiveColor.withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border: Border.all(color: effectiveColor.withValues(alpha: 0.5), width: 1.5),
            ),
            child: Center(
              child: isDone
                  ? const Icon(Icons.check_rounded, color: HudColors.teal, size: 16)
                  : Text(
                      "$stepNumber",
                      style: TextStyle(
                        color: effectiveColor,
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                        fontFamily: 'monospace',
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 16),

          // Step description
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, color: effectiveColor, size: 13),
                    const SizedBox(width: 6),
                    Text(
                      title,
                      style: TextStyle(
                        color: textColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(description, style: const TextStyle(color: HudColors.textDim, fontSize: 10)),
              ],
            ),
          ),
          const SizedBox(width: 12),

          // Action button
          if (onTap != null)
            GestureDetector(
              onTap: onTap,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: effectiveColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: effectiveColor.withValues(alpha: 0.4), width: 1),
                ),
                child: Text(
                  buttonLabel.toUpperCase(),
                  style: TextStyle(
                    color: effectiveColor,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            )
          else if (isDone)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: HudColors.teal.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: HudColors.teal.withValues(alpha: 0.2), width: 1),
              ),
              child: Text(
                buttonLabel,
                style: const TextStyle(
                  color: HudColors.teal,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStepConnector({required bool done}) {
    return Padding(
      padding: const EdgeInsets.only(left: 18, top: 4, bottom: 4),
      child: Row(
        children: [
          Container(
            width: 1.5,
            height: 16,
            color: done ? HudColors.teal.withValues(alpha: 0.3) : HudColors.border,
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Active Mission Monitor
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildMissionMonitor(RobotStateProvider provider) {
    final Color statusColor = _missionStatusColor(provider.missionStatus);
    
    // Determine the current action string & color
    String actionStr = "Idle";
    Color actionColor = HudColors.textMuted;
    
    if (provider.missionStatus == "COMPLETED") {
      if (provider.rampStatus == "CLOSED") {
        actionStr = "Mission Completed";
        actionColor = HudColors.teal;
      } else if (provider.rampStatus == "CLOSING") {
        actionStr = "Closing Ramp";
        actionColor = HudColors.amber;
      } else if (provider.rampStatus == "OPEN") {
        actionStr = "Ramp Open";
        actionColor = HudColors.teal;
      } else if (provider.rampStatus == "OPENING") {
        actionStr = "Opening Ramp";
        actionColor = HudColors.amber;
      }
    } else if (provider.distanceSensor <= 20.0) {
      actionStr = "Obstacle Detected";
      actionColor = HudColors.magenta;
    } else if (provider.robotStatus == "WAITING" || provider.lastApiResponse.contains("WAITING")) {
      actionStr = "Obstacle Avoidance";
      actionColor = Colors.orange;
    } else if (provider.activeCommand == "FORWARD") {
      actionStr = "Heading Straight";
      actionColor = Colors.blue;
    } else if (provider.activeCommand == "LEFT") {
      actionStr = "Turning Left";
      actionColor = HudColors.amber;
    } else if (provider.activeCommand == "RIGHT") {
      actionStr = "Turning Right";
      actionColor = HudColors.amber;
    } else if (provider.rampStatus == "OPENING") {
      actionStr = "Opening Ramp";
      actionColor = HudColors.amber;
    } else if (provider.rampStatus == "OPEN") {
      actionStr = "Ramp Open";
      actionColor = HudColors.teal;
    } else if (provider.rampStatus == "CLOSING") {
      actionStr = "Closing Ramp";
      actionColor = HudColors.amber;
    } else if (provider.activeCommand == "STOP") {
      actionStr = "Waiting";
      actionColor = Colors.orange;
    }

    // Dynamic Mission ID
    final String missionId = "MSN-2026-${provider.sourceCheckpoint}${provider.destinationCheckpoint}".toUpperCase();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: HudColors.cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: statusColor.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 3,
                    height: 16,
                    color: statusColor,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    "AMR MISSION CONTROL CENTER // REAL-TIME EXECUTION",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1.2),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: statusColor.withValues(alpha: 0.5), width: 1),
                ),
                child: Text(
                  provider.missionStatus,
                  style: TextStyle(color: statusColor, fontSize: 9, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // First Layout Row: Mission Info & Progress Bar
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("MISSION DETAILS", style: TextStyle(color: HudColors.textMuted, fontSize: 9, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    _buildTelemetryValueRow("Mission ID", missionId),
                    const SizedBox(height: 4),
                    _buildTelemetryValueRow("Source Checkpoint", provider.sourceCheckpoint),
                    const SizedBox(height: 4),
                    _buildTelemetryValueRow("Destination Checkpoint", provider.destinationCheckpoint),
                    const SizedBox(height: 4),
                    _buildTelemetryValueRow("Current Node", provider.currentCheckpoint),
                    const SizedBox(height: 4),
                    _buildTelemetryValueRow("Next Target Node", provider.nextCheckpoint.isEmpty ? "—" : provider.nextCheckpoint),
                  ],
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildMissionProgressBar(provider),
                    const SizedBox(height: 14),
                    const Text("PATH VISUALIZER", style: TextStyle(color: HudColors.textMuted, fontSize: 9, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    _buildPathVisualizer(provider),
                  ],
                ),
              ),
            ],
          ),
          const Divider(color: HudColors.border, height: 24),

          // Second Layout Row: Robot Status Badge & Obstacle Sonar & Battery Status
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Robot Status
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("ROBOT STATUS", style: TextStyle(color: HudColors.textMuted, fontSize: 9, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: actionColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: actionColor.withValues(alpha: 0.6), width: 1.5),
                          ),
                          child: Text(
                            actionStr.toUpperCase(),
                            style: TextStyle(color: actionColor, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text("SERVO & DELIVERY STATUS", style: TextStyle(color: HudColors.textMuted, fontSize: 9, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    _buildTelemetryValueRow("Ramp State", provider.rampStatus),
                    const SizedBox(height: 4),
                    _buildTelemetryValueRow("Delivery Complete", provider.deliveryComplete ? "✓ YES" : "NO"),
                  ],
                ),
              ),
              const SizedBox(width: 16),

              // Obstacle Detection
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("OBSTACLE DETECTION", style: TextStyle(color: HudColors.textMuted, fontSize: 9, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    _buildObstacleAvoidanceCard(provider),
                  ],
                ),
              ),
              const SizedBox(width: 16),

              // Battery & Power
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("POWER SYSTEM", style: TextStyle(color: HudColors.textMuted, fontSize: 9, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    _buildPowerSystemCard(provider),
                  ],
                ),
              ),
            ],
          ),
          const Divider(color: HudColors.border, height: 24),

          // Third Layout Row: PID monitor & Turn execution
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("CLOSED-LOOP PID MOTION MONITOR", style: TextStyle(color: HudColors.textMuted, fontSize: 9, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    _buildPidMonitor(provider),
                  ],
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("TURNING CONTROLLER", style: TextStyle(color: HudColors.textMuted, fontSize: 9, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    _buildTurnExecution(provider),
                    const SizedBox(height: 12),
                    const Text("ODOMETRY & KINEMATICS", style: TextStyle(color: HudColors.textMuted, fontSize: 9, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    _buildOdometryGrid(provider),
                  ],
                ),
              ),
            ],
          ),
          const Divider(color: HudColors.border, height: 24),

          // Fourth Layout Row: Real-time Mission log
          const Text("LIVE MISSION LOGS", style: TextStyle(color: HudColors.textMuted, fontSize: 9, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Container(
            height: 120,
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: HudColors.bg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: HudColors.border),
            ),
            child: provider.missionLogs.isEmpty
                ? const Center(
                    child: Text(
                      "NO LOGS RECORDED YET",
                      style: TextStyle(color: HudColors.textMuted, fontSize: 9, fontFamily: 'monospace'),
                    ),
                  )
                : MissionLogViewer(logs: provider.missionLogs),
          ),

          const SizedBox(height: 16),
          // View Mission button
          OutlinedButton.icon(
            onPressed: () => onTabChange(1),
            icon: const Icon(Icons.open_in_full_rounded, size: 14, color: HudColors.teal),
            label: const Text("VIEW FULL MISSION PLANNER", style: TextStyle(color: HudColors.teal, fontSize: 11, fontWeight: FontWeight.bold)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: HudColors.teal, width: 1),
              minimumSize: const Size(double.infinity, 40),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTelemetryValueRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: HudColors.textDim, fontSize: 10)),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  Widget _buildPathVisualizer(RobotStateProvider provider) {
    final path = provider.calculatedPath;
    final current = provider.currentCheckpoint;
    if (path.isEmpty) return const Text("—", style: TextStyle(color: HudColors.textMuted));

    List<Widget> children = [];
    for (int i = 0; i < path.length; i++) {
      final node = path[i];
      final isCurrent = node == current;
      children.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isCurrent ? HudColors.teal.withValues(alpha: 0.15) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: isCurrent ? HudColors.teal : Colors.transparent,
              width: 1,
            ),
          ),
          child: Text(
            node,
            style: TextStyle(
              color: isCurrent ? HudColors.teal : HudColors.textDim,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              fontSize: 11,
            ),
          ),
        ),
      );

      if (i < path.length - 1) {
        children.add(
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Icon(Icons.chevron_right_rounded, size: 14, color: HudColors.textMuted),
          ),
        );
      }
    }

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 2,
      runSpacing: 4,
      children: children,
    );
  }

  Widget _buildMissionProgressBar(RobotStateProvider provider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              "MISSION DISPATCH PROGRESS",
              style: TextStyle(color: HudColors.textMuted, fontSize: 9, fontWeight: FontWeight.bold),
            ),
            Text(
              "${provider.missionProgress.toStringAsFixed(1)}%",
              style: TextStyle(color: _missionStatusColor(provider.missionStatus), fontSize: 10, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: HudColors.bg,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: HudColors.border),
          ),
          child: Center(
            child: Text(
              formatProgressBar(provider.missionProgress),
              style: TextStyle(
                color: _missionStatusColor(provider.missionStatus),
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }

  String formatProgressBar(double progress) {
    const totalBlocks = 16;
    final filledBlocks = ((progress / 100.0) * totalBlocks).round().clamp(0, totalBlocks);
    final emptyBlocks = totalBlocks - filledBlocks;
    final bar = "█" * filledBlocks + "░" * emptyBlocks;
    return "$bar ${progress.toStringAsFixed(0)}%";
  }

  Widget _buildObstacleAvoidanceCard(RobotStateProvider provider) {
    if (provider.obstacleAvoidanceEnabled) {
      final status = provider.obstacleAvoidanceStatus;
      Color statusColor;
      String actionStr;
      
      if (status == "NORMAL") {
        statusColor = HudColors.teal;
        actionStr = "NORMAL CRUISE";
      } else if (status == "STOPPING") {
        statusColor = HudColors.magenta;
        actionStr = "EMERGENCY STOP";
      } else if (status == "ROTATING") {
        statusColor = HudColors.amber;
        actionStr = "ROTATING TO BYPASS";
      } else if (status == "CLEARANCE") {
        statusColor = Colors.blue;
        actionStr = "DRIVING BYPASS";
      } else if (status == "RETURNING") {
        statusColor = HudColors.amber;
        actionStr = "ALIGNING HEADING";
      } else if (status == "VERIFYING") {
        statusColor = Colors.blue;
        actionStr = "VERIFYING PATH";
      } else if (status == "FAILED") {
        statusColor = HudColors.magenta;
        actionStr = "STUCK / FAILSAFE";
      } else {
        statusColor = HudColors.teal;
        actionStr = "BYPASS ACTIVE";
      }

      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: HudColors.bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: HudColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTelemetryValueRow("Sonar Distance", "${provider.distanceSensor.toStringAsFixed(0)} cm", valueColor: statusColor),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Sonar Status", style: TextStyle(color: HudColors.textDim, fontSize: 10)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: statusColor.withValues(alpha: 0.5), width: 1),
                  ),
                  child: Text(
                    "OBSTACLE DETECTED",
                    style: TextStyle(color: statusColor, fontSize: 8, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _buildTelemetryValueRow("Bypass Action", actionStr, valueColor: statusColor),
            if (status != "NORMAL") ...[
              const SizedBox(height: 6),
              _buildTelemetryValueRow("Orig Heading", "${provider.originalHeading.toStringAsFixed(1)}°"),
              const SizedBox(height: 6),
              _buildTelemetryValueRow("Bypass Angle", "${provider.currentAvoidanceAngle.toStringAsFixed(0)}°"),
            ],
            if (status == "CLEARANCE") ...[
              const SizedBox(height: 6),
              _buildTelemetryValueRow("Clearance Rem", "${provider.clearanceRemaining.toStringAsFixed(0)} cm", valueColor: Colors.blue),
            ],
          ],
        ),
      );
    }

    final isClose = provider.distanceSensor <= 20.0;
    final Color warningColor = isClose ? HudColors.magenta : (provider.distanceSensor <= 50.0 ? HudColors.amber : HudColors.teal);
    final String statusStr = isClose ? "OBSTACLE DETECTED" : (provider.distanceSensor <= 50.0 ? "WARNING" : "CLEAR");
    
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: HudColors.bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: HudColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Sonar Distance", style: TextStyle(color: HudColors.textDim, fontSize: 10)),
              Text(
                "${provider.distanceSensor.toStringAsFixed(0)} cm",
                style: TextStyle(color: warningColor, fontSize: 11, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Sonar Status", style: TextStyle(color: HudColors.textDim, fontSize: 10)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: warningColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: warningColor.withValues(alpha: 0.5), width: 1),
                ),
                child: Text(
                  statusStr,
                  style: TextStyle(color: warningColor, fontSize: 8, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Robot Action", style: TextStyle(color: HudColors.textDim, fontSize: 10)),
              Text(
                isClose ? "STOPPING" : "NORMAL CRUISE",
                style: TextStyle(
                  color: isClose ? HudColors.magenta : HudColors.teal,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPowerSystemCard(RobotStateProvider provider) {
    final double battPct = ((provider.battery - 9.0) / (12.2 - 9.0) * 100.0).clamp(0.0, 100.0);
    final isLow = provider.battery < 11.5;
    final warningColor = isLow ? HudColors.magenta : HudColors.teal;
    
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: HudColors.bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: HudColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Battery Level", style: TextStyle(color: HudColors.textDim, fontSize: 10)),
              Text(
                "${battPct.toStringAsFixed(0)}%",
                style: TextStyle(color: warningColor, fontSize: 11, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Voltage", style: TextStyle(color: HudColors.textDim, fontSize: 10)),
              Text(
                "${provider.battery.toStringAsFixed(2)} V",
                style: TextStyle(color: warningColor, fontSize: 11, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Power Status", style: TextStyle(color: HudColors.textDim, fontSize: 10)),
              Text(
                isLow ? "LOW BATTERY" : "NOMINAL",
                style: TextStyle(
                  color: isLow ? HudColors.magenta : HudColors.teal,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPidMonitor(RobotStateProvider provider) {
    final errColor = provider.yawError.abs() < 1.0
        ? HudColors.teal
        : (provider.yawError.abs() < 3.0 ? HudColors.amber : HudColors.magenta);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: HudColors.bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: HudColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // PID inputs & output text values
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTelemetryValueRow("Target Heading", "${provider.targetYaw.toStringAsFixed(1)}°"),
                const SizedBox(height: 6),
                _buildTelemetryValueRow("Current Heading", "${provider.yaw.toStringAsFixed(1)}°"),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Heading Error", style: TextStyle(color: HudColors.textDim, fontSize: 10)),
                    Text(
                      "${provider.yawError.toStringAsFixed(1)}°",
                      style: TextStyle(color: errColor, fontSize: 10, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _buildTelemetryValueRow("PID Output", provider.pidOutput.toStringAsFixed(1), valueColor: HudColors.teal),
              ],
            ),
          ),
          const SizedBox(width: 24),
          // Vertical Divider
          Container(width: 1, height: 80, color: HudColors.border),
          const SizedBox(width: 24),
          // PWM details & bar
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTelemetryValueRow("Left PWM", "${provider.pwmLeft} / 255"),
                const SizedBox(height: 6),
                _buildTelemetryValueRow("Right PWM", "${provider.pwmRight} / 255"),
                const SizedBox(height: 10),
                const Text("STABILIZATION DELTA", style: TextStyle(color: HudColors.textMuted, fontSize: 8, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: (provider.pwmLeft + provider.pwmRight > 0)
                        ? (provider.pwmLeft - provider.pwmRight).abs() / 255.0
                        : 0.0,
                    minHeight: 4,
                    backgroundColor: HudColors.cardBg,
                    valueColor: AlwaysStoppedAnimation<Color>(errColor),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTurnExecution(RobotStateProvider provider) {
    final isTurning = provider.activeCommand == "LEFT" || provider.activeCommand == "RIGHT";
    
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: HudColors.bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: HudColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isTurning) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "Turning ${provider.activeCommand == 'LEFT' ? 'Left' : 'Right'}",
                  style: const TextStyle(color: HudColors.amber, fontSize: 11, fontWeight: FontWeight.bold),
                ),
                Text(
                  "Target: ${provider.targetYaw.toStringAsFixed(0)}°",
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Current Angle", style: TextStyle(color: HudColors.textDim, fontSize: 10)),
                Text(
                  "${provider.yaw.toStringAsFixed(1)}°",
                  style: const TextStyle(color: HudColors.teal, fontSize: 11, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: (provider.targetYaw != 0) ? (provider.yaw.abs() / provider.targetYaw.abs()).clamp(0.0, 1.0) : 0.0,
                minHeight: 4,
                backgroundColor: HudColors.cardBg,
                valueColor: const AlwaysStoppedAnimation<Color>(HudColors.amber),
              ),
            ),
          ] else ...[
            Row(
              children: [
                Icon(Icons.check_circle_rounded, size: 14, color: HudColors.teal),
                const SizedBox(width: 6),
                const Text(
                  "Turn Completed",
                  style: TextStyle(color: HudColors.teal, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              "Target Heading: ${provider.targetYaw.toStringAsFixed(0)}°",
              style: const TextStyle(color: HudColors.textMuted, fontSize: 9),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOdometryGrid(RobotStateProvider provider) {
    final double traveled = (provider.missionProgress / 100.0) * provider.estimatedDistance;
    final stabilityText = provider.yawError.abs() < 1.0
        ? "STABLE"
        : (provider.yawError.abs() < 3.0 ? "DRIFT CORRECTING" : "ACTIVE ALIGNING");
    final stabilityColor = provider.yawError.abs() < 1.0
        ? HudColors.teal
        : (provider.yawError.abs() < 3.0 ? HudColors.amber : HudColors.magenta);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: HudColors.bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: HudColors.border),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Speed Limit (Cruise)", style: TextStyle(color: HudColors.textDim, fontSize: 10)),
              Text(
                "${provider.tunedSpeed} PWM",
                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Est Distance Traveled", style: TextStyle(color: HudColors.textDim, fontSize: 10)),
              Text(
                "${traveled.toStringAsFixed(2)} / ${provider.estimatedDistance.toStringAsFixed(1)} m",
                style: const TextStyle(color: HudColors.teal, fontSize: 10, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Stability Index", style: TextStyle(color: HudColors.textDim, fontSize: 10)),
              Text(
                stabilityText,
                style: TextStyle(color: stabilityColor, fontSize: 9, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _missionStatusColor(String status) {
    switch (status.toUpperCase()) {
      case "COMPLETED":
        return HudColors.teal;
      case "RUNNING":
      case "PLANNED":
        return Colors.blue;
      case "PAUSED":
        return HudColors.amber;
      case "NO ACTIVE MISSION":
      default:
        return HudColors.textMuted;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Quick Access Row
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildQuickAccessRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "QUICK ACCESS CONSOLE BYPASS",
          style: TextStyle(color: HudColors.textMuted, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _buildQuickTile("MANUAL DRIVING INTERRUPT", Icons.sports_esports_outlined, HudColors.amber, 2)),
            const SizedBox(width: 12),
            Expanded(child: _buildQuickTile("VECTOR MAP DESIGNER", Icons.design_services_outlined, HudColors.teal, 3)),
          ],
        ),
      ],
    );
  }

  Widget _buildQuickTile(String label, IconData icon, Color color, int tabIndex) {
    return InkWell(
      onTap: () => onTabChange(tabIndex),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.2), width: 1),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 6),
            Text(label, textAlign: TextAlign.center, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
          ],
        ),
      ),
    );
  }
}

class MissionLogViewer extends StatefulWidget {
  final List<LogEntry> logs;
  const MissionLogViewer({super.key, required this.logs});

  @override
  State<MissionLogViewer> createState() => _MissionLogViewerState();
}

class _MissionLogViewerState extends State<MissionLogViewer> {
  final ScrollController _scrollController = ScrollController();

  @override
  void didUpdateWidget(covariant MissionLogViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.logs.length != oldWidget.logs.length) {
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scrollController,
      itemCount: widget.logs.length,
      itemBuilder: (context, index) {
        final log = widget.logs[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "[${log.timestamp}]",
                style: const TextStyle(
                  color: HudColors.textMuted,
                  fontFamily: 'monospace',
                  fontSize: 10,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  log.message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class ObstacleAvoidancePanel extends StatefulWidget {
  final RobotStateProvider provider;

  const ObstacleAvoidancePanel({super.key, required this.provider});

  @override
  State<ObstacleAvoidancePanel> createState() => _ObstacleAvoidancePanelState();
}

class _ObstacleAvoidancePanelState extends State<ObstacleAvoidancePanel> {
  late bool _enabled;
  late double _avoidanceAngle;
  late double _clearanceDistance;
  late double _verificationDistance;
  late double _maxAvoidanceAngle;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _syncFromProvider();
  }

  void _syncFromProvider() {
    _enabled = widget.provider.obstacleAvoidanceEnabled;
    _avoidanceAngle = widget.provider.avoidanceAngle;
    _clearanceDistance = widget.provider.clearanceDistance;
    _verificationDistance = widget.provider.verificationDistance;
    _maxAvoidanceAngle = widget.provider.maxAvoidanceAngle;
  }

  @override
  void didUpdateWidget(ObstacleAvoidancePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider.obstacleAvoidanceEnabled != widget.provider.obstacleAvoidanceEnabled ||
        oldWidget.provider.avoidanceAngle != widget.provider.avoidanceAngle ||
        oldWidget.provider.clearanceDistance != widget.provider.clearanceDistance ||
        oldWidget.provider.verificationDistance != widget.provider.verificationDistance ||
        oldWidget.provider.maxAvoidanceAngle != widget.provider.maxAvoidanceAngle) {
      _syncFromProvider();
    }
  }

  Future<void> _saveSettings() async {
    setState(() {
      _isSaving = true;
    });
    final success = await widget.provider.updateAvoidanceSettings(
      enabled: _enabled,
      avoidanceAngle: _avoidanceAngle,
      clearanceDistance: _clearanceDistance,
      verificationDistance: _verificationDistance,
      maxAvoidanceAngle: _maxAvoidanceAngle,
    );
    setState(() {
      _isSaving = false;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success 
              ? "Obstacle Avoidance configuration saved & synced!" 
              : "Failed to sync settings with robot."),
          backgroundColor: success ? HudColors.teal : HudColors.magenta,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: HudColors.cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: HudColors.border, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: HudColors.teal.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Icon(Icons.shield_outlined, color: HudColors.teal, size: 18),
                  ),
                  const SizedBox(width: 12),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "OBSTACLE AVOIDANCE SYSTEM",
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: 1.5),
                      ),
                      Text(
                        "Configure parameters for autonomous mission bypass routing",
                        style: TextStyle(color: HudColors.textMuted, fontSize: 10),
                      ),
                    ],
                  ),
                ],
              ),
              Switch(
                value: _enabled,
                activeThumbColor: HudColors.teal,
                activeTrackColor: HudColors.teal.withValues(alpha: 0.2),
                inactiveThumbColor: HudColors.textMuted,
                inactiveTrackColor: HudColors.border,
                onChanged: (val) {
                  setState(() {
                    _enabled = val;
                  });
                },
              ),
            ],
          ),
          const Divider(color: HudColors.border, height: 32),

          _buildSliderRow(
            title: "AVOIDANCE INCREMENT ANGLE",
            subtitle: "Degree step to turn left until clearance is detected",
            value: _avoidanceAngle,
            min: 5.0,
            max: 30.0,
            divisions: 5,
            valueSuffix: "°",
            onChanged: _enabled
                ? (val) => setState(() => _avoidanceAngle = val)
                : null,
          ),
          const SizedBox(height: 16),
          _buildSliderRow(
            title: "CLEARANCE BYPASS DISTANCE",
            subtitle: "Distance to travel forward once path is clear",
            value: _clearanceDistance,
            min: 20.0,
            max: 100.0,
            divisions: 16,
            valueSuffix: " cm",
            onChanged: _enabled
                ? (val) => setState(() => _clearanceDistance = val)
                : null,
          ),
          const SizedBox(height: 16),
          _buildSliderRow(
            title: "PATH VERIFICATION DISTANCE",
            subtitle: "Straight line test before returning to Dijkstra route",
            value: _verificationDistance,
            min: 10.0,
            max: 50.0,
            divisions: 8,
            valueSuffix: " cm",
            onChanged: _enabled
                ? (val) => setState(() => _verificationDistance = val)
                : null,
          ),
          const SizedBox(height: 16),
          _buildSliderRow(
            title: "MAXIMUM AVOIDANCE ANGLE",
            subtitle: "Fail-safe limit; pauses mission if exceeded",
            value: _maxAvoidanceAngle,
            min: 30.0,
            max: 90.0,
            divisions: 12,
            valueSuffix: "°",
            onChanged: _enabled
                ? (val) => setState(() => _maxAvoidanceAngle = val)
                : null,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _isSaving ? null : _saveSettings,
            icon: _isSaving 
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Icon(Icons.sync_rounded, color: Colors.black, size: 18),
            label: Text(
              _isSaving ? "SYNCING..." : "SAVE & SYNC TO BOT",
              style: const TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
                fontSize: 12,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: HudColors.teal,
              disabledBackgroundColor: HudColors.border,
              minimumSize: const Size(double.infinity, 44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSliderRow({
    required String title,
    required String subtitle,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String valueSuffix,
    required ValueChanged<double>? onChanged,
  }) {
    final active = onChanged != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: active ? Colors.white : HudColors.textMuted,
                    fontWeight: FontWeight.bold,
                    fontSize: 10,
                    letterSpacing: 0.8,
                  ),
                ),
                Text(subtitle, style: const TextStyle(color: HudColors.textDim, fontSize: 9)),
              ],
            ),
            Text(
              "${value.toStringAsFixed(0)}$valueSuffix",
              style: TextStyle(
                color: active ? HudColors.teal : HudColors.textMuted,
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: HudColors.teal,
            inactiveTrackColor: HudColors.border,
            thumbColor: HudColors.teal,
            overlayColor: HudColors.teal.withValues(alpha: 0.15),
            trackHeight: 2,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
