import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:navix_app/providers/robot_state_provider.dart';
import 'package:navix_app/utils/hud_colors.dart';
import 'package:navix_app/widgets/hud_background.dart';
import 'package:navix_app/widgets/hud_animations.dart';
import 'package:navix_app/widgets/toast_manager.dart';
import 'package:navix_app/widgets/keyboard_overlay.dart';
import 'package:navix_app/screens/home_screen.dart';
import 'package:navix_app/screens/mission_planner_screen.dart';
import 'package:navix_app/screens/manual_mode_screen.dart';
import 'package:navix_app/screens/map_designer_screen.dart';
import 'package:navix_app/screens/esp32_cam_control_screen.dart';
import 'package:navix_app/screens/delivery_management_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _activeTabIndex = 0;
  final FocusNode _focusNode = FocusNode();

  final List<String> _tabTitles = [
    "FLEET DASHBOARD",
    "MISSION PLANNER",
    "MANUAL OVERRIDE",
    "MAP DESIGNER",
    "ESP32-CAM CONTROL",
    "DELIVERY MGMT",
  ];

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<RobotStateProvider>(context);

    // List of screens to render in workspace
    final List<Widget> screens = [
      HomeScreen(onTabChange: (index) {
        setState(() {
          _activeTabIndex = index;
        });
      }),
      MissionPlannerScreen(
        onDesignMap: () {
          setState(() {
            _activeTabIndex = 3; // Navigate to Map Designer tab
          });
        },
      ),
      const ManualModeScreen(),
      MapDesignerScreen(
        onSelectForMission: () {
          setState(() {
            _activeTabIndex = 1; // Switch to Plan a Mission tab
          });
        },
      ),
      const Esp32CamControlScreen(),
      const DeliveryManagementScreen(),
    ];

    // Intercept keyboard controls globally in the shell, but ignore if the user is typing in a text field
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (FocusNode node, KeyEvent event) {
        if (event is KeyDownEvent) {
          final logicalKey = event.logicalKey;
          
          // Check if a TextField is currently focused
          final primary = FocusManager.instance.primaryFocus;
          bool isTyping = false;
          if (primary != null && primary.context != null) {
            isTyping = primary.context!.findAncestorWidgetOfExactType<EditableText>() != null;
          }

          if (isTyping) {
            return KeyEventResult.ignored;
          }

          if (logicalKey == LogicalKeyboardKey.keyW) {
            provider.triggerManualCommand("FORWARD");
            return KeyEventResult.handled;
          } else if (logicalKey == LogicalKeyboardKey.keyS) {
            provider.triggerManualCommand("BACKWARD");
            return KeyEventResult.handled;
          } else if (logicalKey == LogicalKeyboardKey.keyA) {
            provider.triggerManualCommand("LEFT");
            return KeyEventResult.handled;
          } else if (logicalKey == LogicalKeyboardKey.keyD) {
            provider.triggerManualCommand("RIGHT");
            return KeyEventResult.handled;
          } else if (logicalKey == LogicalKeyboardKey.space) {
            provider.emergencyStop();
            return KeyEventResult.handled;
          } else if (event.character == '?' || logicalKey == LogicalKeyboardKey.question) {
            KeyboardHelpDialog.show(context);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: HudColors.bg,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: _buildTopAppBar(provider),
        ),
        body: Stack(
          children: [
            // Cyberpunk animated scanline grid background
            const SizedBox.expand(
              child: ScanlineBackground(),
            ),

            // Actual layout content
            Positioned.fill(
              child: Row(
                children: [
                  // Persistent Sidebar
                  _buildSidebar(provider),
                  
                  // Main content screen area
                  Expanded(
                    child: screens[_activeTabIndex],
                  ),
                ],
              ),
            ),

            // Floating Keyboard controls instruction helper card
            const Positioned(
              bottom: 24,
              right: 24,
              child: KeyboardShortcutHint(),
            ),

            // Toast overlay stack
            const ToastOverlayStack(),
          ],
        ),
      ),
    );
  }

  // Top header status bar
  Widget _buildTopAppBar(RobotStateProvider provider) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: HudColors.cardBg,
        border: Border(bottom: BorderSide(color: HudColors.border, width: 1.5)),
      ),
      child: SafeArea(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Left menu / logo
            Row(
              children: [
                const Icon(Icons.precision_manufacturing_rounded, color: HudColors.teal, size: 24),
                const SizedBox(width: 8),
                Text(
                  "NAVIX // AMR",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                    shadows: [
                      Shadow(color: HudColors.teal.withValues(alpha: 0.3), blurRadius: 4)
                    ]
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: HudColors.gridLow,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: HudColors.teal.withValues(alpha: 0.5), width: 0.5),
                  ),
                  child: Text(
                    _tabTitles[_activeTabIndex],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: HudColors.teal,
                    ),
                  ),
                ),
              ],
            ),

            // Right: status badges
            Row(
              children: [
                // AI backend indicator
                _buildTopBadge(
                  label: "AI CORE",
                  connected: provider.aiBackendConnected,
                ),
                const SizedBox(width: 16),
                // ESP32 connectivity indicator
                _buildTopBadge(
                  label: "ESP32",
                  connected: provider.esp32Connected,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBadge({
    required String label,
    required bool connected,
  }) {
    final activeColor = connected ? HudColors.teal : HudColors.magenta;
    return Row(
      children: [
        PulsingGlowIndicator(color: activeColor, size: 8),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            color: connected ? Colors.white70 : HudColors.magenta,
            fontSize: 10,
            fontFamily: 'monospace',
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  // Sidebar for desktop screen
  Widget _buildSidebar(RobotStateProvider provider) {
    return Container(
      width: 220,
      decoration: const BoxDecoration(
        color: HudColors.cardBg,
        border: Border(right: BorderSide(color: HudColors.border, width: 1.5)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 16),
          _buildSidebarButton(0, Icons.dashboard_outlined, "Home Overview"),
          _buildSidebarButton(1, Icons.explore_outlined, "Plan a Mission"),
          _buildSidebarButton(2, Icons.settings_remote_outlined, "Manual Controls"),
          _buildSidebarButton(3, Icons.design_services_outlined, "Map Designer"),
          _buildSidebarButton(4, Icons.videocam_outlined, "ESP32-CAM Control"),
          _buildSidebarButton(5, Icons.local_shipping_outlined, "Delivery Mgmt"),
          const Spacer(),
          // Operator log footer
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: HudColors.bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: HudColors.border, width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "OPERATOR ACTIVE:",
                  style: TextStyle(color: HudColors.textMuted, fontSize: 8, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                ),
                const SizedBox(height: 2),
                const Text(
                  "SYS_ADMIN_ALPHA",
                  style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                ),
                const SizedBox(height: 8),
                GlitchWrapper(
                  value: provider.robotStatus == 'STOPPED',
                  child: Text(
                    "ESTOP STATE: ${provider.robotStatus == 'STOPPED' ? 'ENFORCED' : 'CLEAR'}",
                    style: TextStyle(
                      color: provider.robotStatus == 'STOPPED' ? HudColors.magenta : HudColors.teal,
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarButton(int index, IconData icon, String label) {
    final bool isSelected = _activeTabIndex == index;

    return InkWell(
      onTap: () {
        setState(() {
          _activeTabIndex = index;
        });
      },
      child: Container(
        height: 50,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: isSelected ? HudColors.teal.withValues(alpha: 0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? HudColors.teal.withValues(alpha: 0.4) : Colors.transparent,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected ? HudColors.teal : HudColors.textMuted,
              size: 20,
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : HudColors.textDim,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
