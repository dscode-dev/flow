import 'package:flutter/material.dart';

abstract final class FlowColors {
  static const blue = Color(0xFF2556D8),
      purple = Color(0xFF7445C8),
      pink = Color(0xFFC53568);
  static const light = Color(0xFFF8F9FE), dark = Color(0xFF10121C);
  // Decorativo; textos usam cores semânticas do ColorScheme.
  static const accent = LinearGradient(colors: [blue, purple, pink]);
}

abstract final class FlowSpace {
  static const xs = 4.0, sm = 8.0, md = 16.0, lg = 24.0, xl = 32.0;
}

abstract final class FlowRadius {
  static const control = 12.0, card = 20.0, sheet = 28.0;
}

abstract final class FlowMotion {
  static const quick = Duration(milliseconds: 160),
      standard = Duration(milliseconds: 240);
  static const curve = Curves.easeOutCubic;
}

abstract final class FlowTypography {
  static const title = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w700,
    height: 1.25,
  );
  static const body = TextStyle(fontSize: 16, height: 1.5);
  static const label = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.4,
  );
}
