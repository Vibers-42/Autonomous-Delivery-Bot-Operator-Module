import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:navix_app/providers/robot_state_provider.dart';
import 'package:navix_app/widgets/generated_navigation_map.dart';
import 'package:navix_app/widgets/telemetry_card.dart';
import 'package:navix_app/utils/hud_colors.dart';

class MissionPlannerScreen extends StatefulWidget {
  /// Called when user taps "Design a Map" — should navigate to Map Designer tab.
  final VoidCallback onDesignMap;

  const MissionPlannerScreen({super.key, required this.onDesignMap});

  @override
  State<MissionPlannerScreen> createState() => _MissionPlannerScreenState();
}

class _MissionPlannerScreenState extends State<MissionPlannerScreen> {
  double _freeRoamTurnDuration = 1.5;

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RobotStateProvider>(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          const Text(
            "AUTONOMOUS MISSION PLANNER",
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.5,
            ),
          ),
          const Text(
            "Define navigation source and destination to compute optimal routes and command the AMR robot.",
            style: TextStyle(color: HudColors.textMuted, fontSize: 11, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),

          // ── Loaded Maps Panel ──────────────────────────────────────────────
          if (provider.loadedMaps.isNotEmpty) ...[
            _buildLoadedMapsPanel(context, provider),
            const SizedBox(height: 20),
          ],

          // ── No Map Loaded Warning ─────────────────────────────────────────
          if (!provider.mapLoaded)
            _buildNoMapWarning(context)
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: _buildNavigationMapPanel(provider, height: 600),
                ),
                const SizedBox(width: 24),
                Expanded(flex: 2, child: _buildControlPanel(context, provider)),
              ],
            ),
            if (provider.missionStatus != "NO ACTIVE MISSION") ...[
              const SizedBox(height: 24),
              _buildMissionMonitor(context, provider),
            ],
            const SizedBox(height: 24),
            const TelemetryCard(),
          ],

          // ── FREE ROAM — always visible regardless of map state ────────────
          const SizedBox(height: 24),
          _buildFreeRoamPanel(context, provider),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Loaded Maps horizontal scroll list
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildLoadedMapsPanel(BuildContext context, RobotStateProvider provider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Row(
              children: [
                Icon(Icons.map_outlined, color: HudColors.teal, size: 16),
                SizedBox(width: 8),
                Text(
                  "LOADED MAPS",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
            // Navigate to design map screen
            TextButton.icon(
              onPressed: widget.onDesignMap,
              icon: const Icon(Icons.design_services_outlined, size: 14, color: HudColors.teal),
              label: const Text(
                "DESIGN MAP",
                style: TextStyle(color: HudColors.teal, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 100,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: provider.loadedMaps.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, idx) {
              final map = provider.loadedMaps[idx];
              final bool isActive = provider.mapFileName == map.fileName;
              return _buildMapCard(context, provider, map, isActive);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMapCard(
    BuildContext context,
    RobotStateProvider provider,
    LoadedMap map,
    bool isActive,
  ) {
    final Color borderColor = isActive ? HudColors.teal : HudColors.border;
    final Color labelColor = isActive ? HudColors.teal : HudColors.textMuted;

    return GestureDetector(
      onTap: isActive ? null : () => provider.selectMap(map),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: 180,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isActive ? HudColors.gridLow : HudColors.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor, width: isActive ? 1.5 : 1),
          boxShadow: isActive
              ? [BoxShadow(color: HudColors.teal.withValues(alpha: 0.15), blurRadius: 12)]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.grid_4x4_rounded,
                  size: 14,
                  color: isActive ? HudColors.teal : const Color(0xFF3E5471),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    map.fileName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              "${map.checkpoints.length} checkpoints  •  ${map.connections.length} corridors",
              style: const TextStyle(color: HudColors.textMuted, fontSize: 9, fontFamily: 'monospace'),
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (isActive)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: HudColors.teal.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      "ACTIVE",
                      style: TextStyle(color: HudColors.teal, fontSize: 8, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                    ),
                  )
                else
                  Text(
                    "TAP TO USE",
                    style: TextStyle(color: labelColor, fontSize: 8, fontFamily: 'monospace', fontWeight: FontWeight.bold),
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 14, color: Colors.redAccent),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    provider.deleteMap(map.fileName);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // No Map Loaded Warning + Import Button (now with working navigation)
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildNoMapWarning(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: HudColors.cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: HudColors.amber.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Column(
        children: [
          const Icon(Icons.warning_amber_rounded, color: HudColors.amber, size: 48),
          const SizedBox(height: 16),
          const Text(
            "MAP NOT LOADED",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 1.5),
          ),
          const SizedBox(height: 8),
          const Text(
            "Upload or design an occupancy-grid map in the MAP DESIGNER to extract waypoints and build the navigation graph.",
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF6B7A90), fontSize: 12),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: widget.onDesignMap,  // ← Now navigates to Map Designer!
            icon: const Icon(Icons.design_services_outlined, color: Colors.black),
            style: ElevatedButton.styleFrom(
              backgroundColor: HudColors.amber,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            label: const Text(
              "DESIGN A MAP",
              style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationMapPanel(RobotStateProvider provider, {double height = 400}) {
    return SizedBox(
      height: height,
      child: const GeneratedNavigationMap(),
    );
  }

  Widget _buildControlPanel(BuildContext context, RobotStateProvider provider) {
    final checkpointKeys = provider.checkpoints.keys.toList();

    return Column(
      children: [
        // 1. Waypoint Selection Card
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: HudColors.cardBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: HudColors.border, width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "ROUTE CONFIGURATOR",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.2),
              ),
              const Divider(color: Color(0xFF1E2E43), height: 24),

              // Source / Destination Dropdowns
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("SOURCE NODE", style: TextStyle(color: HudColors.amber, fontSize: 10, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        _buildWaypointDropdown(
                          value: provider.sourceCheckpoint,
                          items: checkpointKeys,
                          onChanged: (val) { if (val != null) provider.setSource(val); },
                          color: HudColors.amber,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("DESTINATION NODE", style: TextStyle(color: HudColors.teal, fontSize: 10, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        _buildWaypointDropdown(
                          value: provider.destinationCheckpoint,
                          items: checkpointKeys,
                          onChanged: (val) { if (val != null) provider.setDestination(val); },
                          color: HudColors.teal,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text(
                "INTERMEDIATE WAYPOINTS",
                style: TextStyle(color: HudColors.textDim, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.0),
              ),
              const SizedBox(height: 8),
              StatefulBuilder(
                builder: (context, setPanelState) {
                  final availableKeys = checkpointKeys.where((k) =>
                    k != provider.sourceCheckpoint &&
                    k != provider.destinationCheckpoint &&
                    !provider.intermediateCheckpoints.contains(k)
                  ).toList();
                  
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: HudColors.bg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: HudColors.teal.withValues(alpha: 0.5), width: 1),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: null,
                        hint: const Text("Select Node to Add", style: TextStyle(color: Colors.white30, fontSize: 12)),
                        dropdownColor: HudColors.bg,
                        isExpanded: true,
                        style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontWeight: FontWeight.bold),
                        items: availableKeys.map((String key) => DropdownMenuItem<String>(value: key, child: Text("Node $key"))).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            provider.addIntermediate(val);
                            setPanelState(() {});
                          }
                        },
                      ),
                    ),
                  );
                }
              ),
              if (provider.intermediateCheckpoints.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8.0,
                  runSpacing: 8.0,
                  children: provider.intermediateCheckpoints.map((node) {
                    return Chip(
                      label: Text(
                        "Node $node",
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      backgroundColor: const Color(0xFF16222F),
                      deleteIcon: const Icon(Icons.cancel, size: 14, color: Colors.redAccent),
                      onDeleted: () {
                        provider.removeIntermediate(node);
                      },
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                        side: const BorderSide(color: HudColors.teal, width: 0.5),
                      ),
                    );
                  }).toList(),
                ),
              ],
              const SizedBox(height: 20),

              // Plan Route button
              ElevatedButton.icon(
                onPressed: provider.isPlanning ? null : () => provider.planMissionRoute(),
                icon: const Icon(Icons.psychology_outlined, color: Colors.black),
                label: const Text("PLAN MISSION", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: HudColors.teal,
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // 2. Calculated Route + Mission Controls
        if (provider.missionStatus != "NO ACTIVE MISSION")
          _buildMissionControlCard(context, provider),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Free Roam Panel — always rendered, no map required
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildFreeRoamPanel(BuildContext context, RobotStateProvider provider) {
    final bool isActive = provider.freeRoamActive;
    final String state = provider.freeRoamState;
    final double distCm = provider.distanceSensor;
    final bool obstacleNear = distCm <= 20.0;

    // Color theme for state
    Color activeAccent;
    switch (state) {
      case "BACKING":
        activeAccent = HudColors.amber;
        break;
      case "TURNING":
        activeAccent = HudColors.magenta;
        break;
      case "MOVING":
        activeAccent = HudColors.teal;
        break;
      default:
        activeAccent = const Color(0xFF3E5471);
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: HudColors.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? activeAccent.withValues(alpha: 0.7) : HudColors.border,
          width: isActive ? 1.5 : 1.0,
        ),
        boxShadow: isActive
            ? [BoxShadow(color: activeAccent.withValues(alpha: 0.12), blurRadius: 20, spreadRadius: 2)]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ─────────────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.explore_rounded,
                    color: isActive ? activeAccent : const Color(0xFF3E5471),
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    "FREE ROAM",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A1628),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFF1E2E43)),
                    ),
                    child: const Text(
                      "PROTOTYPE MODE",
                      style: TextStyle(
                        color: HudColors.textMuted,
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ],
              ),
              // Status chip
              _buildFreeRoamStateChip(state, isActive, activeAccent),
            ],
          ),

          const SizedBox(height: 4),
          const Text(
            "Robot wanders forward autonomously. On obstacle: backs up → turns left/right → resumes. No map required.",
            style: TextStyle(color: HudColors.textMuted, fontSize: 10, fontWeight: FontWeight.bold),
          ),

          const Divider(color: Color(0xFF1E2E43), height: 28),

          // ── Distance Sensor Bar ─────────────────────────────────────────
          Row(
            children: [
              const Icon(Icons.sensors, color: HudColors.textDim, size: 14),
              const SizedBox(width: 8),
              const Text(
                "FRONT SONAR",
                style: TextStyle(color: HudColors.textDim, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8),
              ),
              const Spacer(),
              Text(
                distCm >= 999 ? "CLEAR" : "${distCm.toStringAsFixed(0)} cm",
                style: TextStyle(
                  color: obstacleNear ? HudColors.magenta : HudColors.teal,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _buildDistanceSensorBar(distCm),

          const SizedBox(height: 20),

          // ── Behavior Description Cards ──────────────────────────────────
          Row(
            children: [
              Expanded(child: _buildBehaviorStep(
                icon: Icons.arrow_upward_rounded,
                label: "FORWARD",
                desc: "Moves straight until obstacle ≤ 20 cm",
                color: HudColors.teal,
                active: isActive && state == "MOVING",
              )),
              const SizedBox(width: 8),
              Expanded(child: _buildBehaviorStep(
                icon: Icons.arrow_downward_rounded,
                label: "REVERSE",
                desc: "Backs up 1.5 s to gain clearance",
                color: HudColors.amber,
                active: isActive && state == "BACKING",
              )),
              const SizedBox(width: 8),
              Expanded(child: _buildBehaviorStep(
                icon: Icons.rotate_right_rounded,
                label: "TURN",
                desc: "Random L/R turn, then resumes",
                color: HudColors.magenta,
                active: isActive && state == "TURNING",
              )),
            ],
          ),

          const SizedBox(height: 20),

          // ── Turn Duration Slider ────────────────────────────────────────
          Row(
            children: [
              const Icon(Icons.tune, color: HudColors.textDim, size: 14),
              const SizedBox(width: 8),
              Text(
                "TURN DURATION: ${_freeRoamTurnDuration.toStringAsFixed(1)}s",
                style: const TextStyle(color: HudColors.textDim, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8),
              ),
            ],
          ),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: HudColors.teal,
              inactiveTrackColor: HudColors.border,
              thumbColor: HudColors.teal,
              overlayColor: HudColors.teal.withValues(alpha: 0.2),
              trackHeight: 3,
            ),
            child: Slider(
              value: _freeRoamTurnDuration,
              min: 0.5,
              max: 3.0,
              divisions: 10,
              onChanged: isActive ? null : (val) {
                setState(() => _freeRoamTurnDuration = val);
              },
            ),
          ),

          const SizedBox(height: 16),

          // ── Action Buttons ──────────────────────────────────────────────
          if (!isActive)
            ElevatedButton.icon(
              onPressed: () => provider.startFreeRoam(),
              icon: const Icon(Icons.explore_rounded, color: Colors.black),
              label: const Text(
                "START FREE ROAM",
                style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, letterSpacing: 1),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: HudColors.teal,
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                elevation: 4,
                shadowColor: HudColors.teal.withValues(alpha: 0.4),
              ),
            )
          else
            Row(
              children: [
                // Animated status label
                Expanded(
                  child: Container(
                    height: 52,
                    decoration: BoxDecoration(
                      color: activeAccent.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: activeAccent.withValues(alpha: 0.4), width: 1),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: activeAccent,
                            shape: BoxShape.circle,
                            boxShadow: [BoxShadow(color: activeAccent, blurRadius: 6)],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _freeRoamStateLabel(state),
                          style: TextStyle(
                            color: activeAccent,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            letterSpacing: 1,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Stop button
                ElevatedButton.icon(
                  onPressed: () => provider.stopFreeRoam(),
                  icon: const Icon(Icons.stop_rounded, color: Colors.white),
                  label: const Text(
                    "STOP",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: HudColors.magenta,
                    minimumSize: const Size(120, 52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: 4,
                    shadowColor: HudColors.magenta.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildFreeRoamStateChip(String state, bool isActive, Color accent) {
    String label;
    IconData icon;
    switch (state) {
      case "MOVING":
        label = "MOVING";
        icon = Icons.arrow_upward_rounded;
        break;
      case "BACKING":
        label = "BACKING UP";
        icon = Icons.arrow_downward_rounded;
        break;
      case "TURNING":
        label = "TURNING";
        icon = Icons.rotate_right_rounded;
        break;
      default:
        label = "IDLE";
        icon = Icons.radio_button_unchecked;
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isActive ? accent.withValues(alpha: 0.15) : HudColors.bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isActive ? accent.withValues(alpha: 0.6) : HudColors.border,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: isActive ? accent : HudColors.textMuted),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: isActive ? accent : HudColors.textMuted,
              fontSize: 9,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDistanceSensorBar(double distCm) {
    // Cap at 150 cm for bar display
    final double capped = distCm.clamp(0, 150);
    final double fraction = 1.0 - (capped / 150.0); // 0 = far, 1 = very close
    Color barColor;
    if (capped <= 20) {
      barColor = HudColors.magenta;
    } else if (capped <= 50) {
      barColor = HudColors.amber;
    } else {
      barColor = HudColors.teal;
    }
    return LayoutBuilder(builder: (context, constraints) {
      return Container(
        height: 6,
        width: constraints.maxWidth,
        decoration: BoxDecoration(
          color: HudColors.bg,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Align(
          alignment: Alignment.centerRight,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 6,
            width: constraints.maxWidth * fraction,
            decoration: BoxDecoration(
              color: barColor,
              borderRadius: BorderRadius.circular(3),
              boxShadow: [BoxShadow(color: barColor.withValues(alpha: 0.5), blurRadius: 4)],
            ),
          ),
        ),
      );
    });
  }

  Widget _buildBehaviorStep({
    required IconData icon,
    required String label,
    required String desc,
    required Color color,
    required bool active,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: active ? color.withValues(alpha: 0.12) : HudColors.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? color.withValues(alpha: 0.6) : const Color(0xFF1E2E43),
          width: active ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: active ? color : HudColors.textMuted, size: 18),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: active ? color : HudColors.textDim,
              fontSize: 9,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 3),
          Text(
            desc,
            style: const TextStyle(color: HudColors.textMuted, fontSize: 8),
          ),
        ],
      ),
    );
  }

  String _freeRoamStateLabel(String state) {
    switch (state) {
      case "MOVING":  return "● MOVING FORWARD";
      case "BACKING": return "◀ BACKING UP...";
      case "TURNING": return "↺ TURNING...";
      default:        return "○ STANDBY";
    }
  }

  Widget _buildMissionControlCard(BuildContext context, RobotStateProvider provider) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: HudColors.cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: HudColors.border, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "ROUTE SOLUTIONS",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.2),
          ),
          const Divider(color: Color(0xFF1E2E43), height: 24),

          _buildMetricRow("Calculated Route Path", provider.calculatedPath.join(" → ")),
          _buildMetricRow("Total Graph Distance", "${provider.estimatedDistance.toStringAsFixed(2)} ${provider.detectedUnit}"),
          _buildMetricRow("Estimated Mission Time", "${provider.estimatedTime.toStringAsFixed(1)} s"),
          _buildMetricRow("Total Route Turns", "${provider.turnsCount}"),


          // ── Live Mission Progress (visible when RUNNING or COMPLETED) ──
          if (provider.missionStatus == "RUNNING" || provider.missionStatus == "COMPLETED" || provider.missionStatus == "PAUSED") ...[
            const SizedBox(height: 8),
            _buildMissionProgressBar(provider),
            const SizedBox(height: 12),
            _buildCheckpointProgressRow(provider),
          ],

          // Live direction indicator during RUNNING
          if (provider.missionStatus == "RUNNING") ...[
            const SizedBox(height: 12),
            _buildDirectionIndicator(provider.activeCommand),
          ],

          const SizedBox(height: 20),

          // ── Robot Connection Status ───────────────────────────────
          _buildConnectionStatus(context, provider),
          const SizedBox(height: 16),

          // State-machine action buttons
          if (provider.missionStatus == "PLANNED")
            ElevatedButton.icon(
              onPressed: provider.esp32Connected ? () => provider.startAutonomousMission() : null,
              icon: Icon(
                provider.esp32Connected ? Icons.play_arrow_rounded : Icons.lock_outline_rounded,
                color: provider.esp32Connected ? Colors.black : Colors.white38,
              ),
              label: Text(
                provider.esp32Connected ? "BEGIN TRIP" : "ROBOT NOT CONNECTED",
                style: TextStyle(
                  color: provider.esp32Connected ? Colors.black : Colors.white38,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: HudColors.teal,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            )
          else if (provider.missionStatus == "RUNNING")
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => provider.pauseMission(),
                    icon: const Icon(Icons.pause_rounded, color: Colors.amber),
                    label: const Text("PAUSE", style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.amber, width: 1.5),
                      minimumSize: const Size(0, 48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => provider.cancelMission(),
                    icon: const Icon(Icons.cancel_outlined, color: Colors.white),
                    label: const Text("ABORT", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: HudColors.magenta,
                      minimumSize: const Size(0, 48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              ],
            )
          else if (provider.missionStatus == "PAUSED")
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => provider.resumeMission(),
                    icon: const Icon(Icons.play_arrow_rounded, color: Colors.black),
                    label: const Text("RESUME", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: HudColors.teal,
                      minimumSize: const Size(0, 48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => provider.cancelMission(),
                    icon: const Icon(Icons.cancel_outlined, color: Colors.white),
                    label: const Text("CANCEL", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white54, width: 1.5),
                      minimumSize: const Size(0, 48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              ],
            )
          else if (provider.missionStatus == "COMPLETED")
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: HudColors.teal.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: HudColors.teal, width: 1.5),
              ),
              child: Column(
                children: [
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle_outline, color: HudColors.teal, size: 20),
                      SizedBox(width: 8),
                      Text(
                        "DELIVERY COMPLETED",
                        style: TextStyle(
                          color: HudColors.teal,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    "Ramp Deployed Successfully",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        "CURRENT RAMP STATUS: ",
                        style: TextStyle(
                          color: HudColors.textDim,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: provider.rampStatus == "OPEN"
                              ? HudColors.teal.withValues(alpha: 0.15)
                              : HudColors.magenta.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: provider.rampStatus == "OPEN"
                                ? HudColors.teal
                                : HudColors.magenta,
                            width: 1,
                          ),
                        ),
                        child: Text(
                          provider.rampStatus,
                          style: TextStyle(
                            color: provider.rampStatus == "OPEN"
                                ? HudColors.teal
                                : HudColors.magenta,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: () => provider.resetMission(),
                    icon: const Icon(Icons.refresh_rounded, color: Colors.black),
                    label: const Text("NEW MISSION", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, letterSpacing: 1)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: HudColors.teal,
                      minimumSize: const Size(double.infinity, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ),

          // Emergency Stop (always visible when mission is active)
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: () => provider.emergencyStop(),
            icon: const Icon(Icons.report_problem, color: Colors.white),
            label: const Text("EMERGENCY STOP (ESTOP)", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF1744),
              minimumSize: const Size(double.infinity, 50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              elevation: 5,
              shadowColor: const Color(0xFFFF1744).withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  /// Robot connection status badge + on-demand ping button.
  Widget _buildConnectionStatus(BuildContext context, RobotStateProvider provider) {
    final bool connected = provider.esp32Connected;
    final Color statusColor = connected ? HudColors.teal : HudColors.magenta;
    final Color bgColor = connected
        ? HudColors.teal.withValues(alpha: 0.07)
        : HudColors.magenta.withValues(alpha: 0.07);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: statusColor.withValues(alpha: 0.4), width: 1),
      ),
      child: Row(
        children: [
          // Pulsing dot
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: statusColor, blurRadius: 6, spreadRadius: 1)],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  connected ? "ROBOT REACHABLE" : "ROBOT UNREACHABLE",
                  style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1),
                ),
                Text(
                  connected
                      ? "ESP32 is online at ${provider.esp32Ip} — Ready to begin trip"
                      : "Connect to ESP32 WiFi (${provider.esp32Ip}) then tap TEST",
                  style: const TextStyle(color: HudColors.textMuted, fontSize: 9),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Test connection button
          OutlinedButton(
            onPressed: provider.isPlanning ? null : () => provider.pingEsp32(),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: statusColor.withValues(alpha: 0.6), width: 1),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            child: Text(
              "TEST",
              style: TextStyle(color: statusColor, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1),
            ),
          ),
        ],
      ),
    );
  }

  /// Live direction card shown during autonomous movement.
  Widget _buildDirectionIndicator(String command) {
    final Map<String, Map<String, dynamic>> commandMap = {
      "FORWARD":  {"icon": Icons.arrow_upward_rounded,   "color": HudColors.teal,  "label": "MOVING FORWARD"},
      "BACKWARD": {"icon": Icons.arrow_downward_rounded,  "color": Colors.amber,             "label": "REVERSING"},
      "LEFT":     {"icon": Icons.arrow_back_rounded,      "color": const Color(0xFF00E5FF),  "label": "TURNING LEFT"},
      "RIGHT":    {"icon": Icons.arrow_forward_rounded,   "color": const Color(0xFF00E5FF),  "label": "TURNING RIGHT"},
      "STOP":     {"icon": Icons.stop_rounded,            "color": HudColors.magenta,  "label": "STOPPED"},
    };
    final info = commandMap[command] ?? commandMap["STOP"]!;
    final Color c = info["color"] as Color;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.4), width: 1),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: c.withValues(alpha: 0.15), shape: BoxShape.circle),
            child: Icon(info["icon"] as IconData, color: c, size: 22),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("CURRENT DIRECTION", style: TextStyle(color: HudColors.textMuted, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1)),
              Text(
                info["label"] as String,
                style: TextStyle(color: c, fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Animated progress bar with ETA countdown shown during mission.
  Widget _buildMissionProgressBar(RobotStateProvider provider) {
    final double progress = provider.missionProgress / 100.0;
    final double elapsedFraction = progress.clamp(0.0, 1.0);
    final double remainingSec = provider.estimatedTime * (1.0 - elapsedFraction);
    final bool isCompleted = provider.missionStatus == "COMPLETED";
    final Color barColor = isCompleted ? HudColors.teal : HudColors.teal;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              "MISSION PROGRESS",
              style: const TextStyle(color: HudColors.textMuted, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1),
            ),
            Row(
              children: [
                if (!isCompleted && provider.missionStatus == "RUNNING") ...[ 
                  const Icon(Icons.timer_outlined, size: 12, color: HudColors.teal),
                  const SizedBox(width: 4),
                  Text(
                    "ETA: ${remainingSec.toStringAsFixed(0)}s",
                    style: const TextStyle(color: HudColors.teal, fontFamily: 'monospace', fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 12),
                ],
                Text(
                  "${provider.missionProgress.toStringAsFixed(1)}%",
                  style: TextStyle(color: barColor, fontFamily: 'monospace', fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: elapsedFraction,
            backgroundColor: HudColors.border,
            valueColor: AlwaysStoppedAnimation<Color>(barColor),
            minHeight: 7,
          ),
        ),
      ],
    );
  }

  /// Shows current checkpoint → next checkpoint progress chip row.
  Widget _buildCheckpointProgressRow(RobotStateProvider provider) {
    final String current = provider.currentCheckpoint;
    final String next = provider.nextCheckpoint;
    final String command = provider.activeCommand;
    final bool isTurning = command == "LEFT" || command == "RIGHT";

    return Row(
      children: [
        // Current checkpoint badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: HudColors.amber.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: HudColors.amber, width: 1),
          ),
          child: Text(
            current.isEmpty ? "—" : "AT: $current",
            style: const TextStyle(color: HudColors.amber, fontFamily: 'monospace', fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 8),
        // Arrow indicator
        Icon(
          isTurning ? Icons.rotate_right_rounded : Icons.arrow_forward_rounded,
          color: isTurning ? const Color(0xFF00E5FF) : HudColors.teal,
          size: 16,
        ),
        const SizedBox(width: 8),
        // Next checkpoint badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: HudColors.teal.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: HudColors.teal, width: 1),
          ),
          child: Text(
            next.isEmpty ? "DESTINATION" : "→ $next",
            style: const TextStyle(color: HudColors.teal, fontFamily: 'monospace', fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  Widget _buildWaypointDropdown({
    required String value,
    required List<String> items,
    required void Function(String?) onChanged,
    required Color color,
  }) {
    String? selected = value.isNotEmpty && items.contains(value) ? value : null;
    if (selected == null && items.isNotEmpty) selected = items.first;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: HudColors.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: selected,
          dropdownColor: HudColors.bg,
          isExpanded: true,
          style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontWeight: FontWeight.bold),
          items: items.map((String key) => DropdownMenuItem<String>(value: key, child: Text("Node $key"))).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildMetricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: HudColors.textMuted, fontSize: 10, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Active Mission Monitor
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildMissionMonitor(BuildContext context, RobotStateProvider provider) {
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
      } else if (status == "RECOVER_BACKING") {
        statusColor = HudColors.magenta;
        actionStr = "BACKING FOR SPACE";
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
          Container(width: 1, height: 80, color: HudColors.border),
          const SizedBox(width: 24),
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
