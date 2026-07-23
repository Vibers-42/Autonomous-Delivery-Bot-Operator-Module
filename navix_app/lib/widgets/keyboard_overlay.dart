import 'package:flutter/material.dart';
import 'package:navix_app/utils/hud_colors.dart';
import 'package:navix_app/widgets/hud_animations.dart';

class KeyboardShortcutHint extends StatelessWidget {
  const KeyboardShortcutHint({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: HudColors.cardBg.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: HudColors.teal.withValues(alpha: 0.3), width: 1),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PulsingGlowIndicator(color: HudColors.teal, size: 6),
          SizedBox(width: 8),
          Text(
            "PRESS [ ? ] FOR KEYBOARD CONTROLS",
            style: TextStyle(
              color: HudColors.teal,
              fontSize: 9,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class KeyboardHelpDialog extends StatelessWidget {
  const KeyboardHelpDialog({super.key});

  static void show(BuildContext context) {
    showDialog(
      context: context,
      barrierColor: HudColors.bg.withValues(alpha: 0.85),
      builder: (context) => const KeyboardHelpDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: GlitchWrapper(
        value: "keyboard_help",
        child: Container(
          width: 500,
          decoration: BoxDecoration(
            color: HudColors.cardBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: HudColors.teal, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: HudColors.teal.withValues(alpha: 0.15),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: HudColors.border, width: 1.5),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.keyboard, color: HudColors.teal, size: 20),
                        SizedBox(width: 10),
                        Text(
                          "SYSTEM DIRECTIVES / SHORTCUTS",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: HudColors.textMuted, size: 18),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              
              // Body Table
              Padding(
                padding: const EdgeInsets.all(20),
                child: Table(
                  columnWidths: const {
                    0: FixedColumnWidth(100),
                    1: FlexColumnWidth(),
                  },
                  border: TableBorder.all(color: HudColors.border, width: 1),
                  children: [
                    _buildHeaderRow(),
                    _buildRow("W", "FORWARD STEERING / ACCELERATE"),
                    _buildRow("S", "BACKWARD STEERING / REVERSE"),
                    _buildRow("A", "PIVOT LEFT / YAW COUNTER-CLOCKWISE"),
                    _buildRow("D", "PIVOT RIGHT / YAW CLOCKWISE"),
                    _buildRow("SPACE", "EMERGENCY HALT (STOP ALL MOTORS)"),
                    _buildRow("?", "TOGGLE THIS UTILITY OVERLAY"),
                  ],
                ),
              ),

              // Footer
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: const BoxDecoration(
                  color: HudColors.bg,
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(8),
                    bottomRight: Radius.circular(8),
                  ),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "STATUS: MANUAL INTERRUPT LISTENERS ACTIVE",
                      style: TextStyle(
                        color: HudColors.amber,
                        fontSize: 9,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      "v1.0.0-HUD",
                      style: TextStyle(
                        color: HudColors.textMuted,
                        fontSize: 9,
                        fontFamily: 'monospace',
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

  TableRow _buildHeaderRow() {
    return TableRow(
      decoration: const BoxDecoration(color: HudColors.bg),
      children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            "INPUT KEY",
            style: TextStyle(
              color: HudColors.textDim,
              fontSize: 10,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            "COMMAND FUNCTION",
            style: TextStyle(
              color: HudColors.textDim,
              fontSize: 10,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  TableRow _buildRow(String key, String description) {
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: HudColors.bg,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: HudColors.textMuted, width: 0.5),
              ),
              child: Text(
                key,
                style: const TextStyle(
                  color: HudColors.teal,
                  fontSize: 10,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              description,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ],
    );
  }
}
