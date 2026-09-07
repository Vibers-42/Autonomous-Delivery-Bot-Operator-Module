import 'package:flutter/material.dart';

class HudColors {
  // Deep space-black base void backgrounds
  static const Color bg = Color(0xFF06080A);
  static const Color cardBg = Color(0xFF0C1017);
  static const Color border = Color(0xFF161F2B);
  
  // Neon visual indicators
  static const Color teal = Color(0xFF0DFFC8);       // nominal / active / connected
  static const Color magenta = Color(0xFFFF2E8A);    // critical alert / offline / E-STOP
  static const Color amber = Color(0xFFFFB02E);      // warning / manual override / slow
  
  // Secondary text and grid shades
  static const Color textMuted = Color(0xFF5A6F8F);
  static const Color gridLow = Color(0xFF0E151F);
  static const Color gridHigh = Color(0xFF1C2736);
  static const Color textDim = Color(0xFF8BA2C0);
}
