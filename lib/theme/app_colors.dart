import 'package:flutter/material.dart';

/// SABALIVE palette — dark theme with purple / pink / gold brand accents.
class AppColors {
  AppColors._();

  // Backgrounds
  static const Color bg = Color(0xFF0B0716);
  static const Color bgElevated = Color(0xFF130C24);
  static const Color surface = Color(0xFF1A1230);
  static const Color surfaceAlt = Color(0xFF221743);
  static const Color card = Color(0xFF1E1638);
  static const Color stroke = Color(0xFF2E2352);
  static const Color strokeSoft = Color(0x1AFFFFFF);

  // Brand
  static const Color primary = Color(0xFF9B3DF5);
  static const Color primaryDeep = Color(0xFF6D28D9);
  static const Color primaryBright = Color(0xFFB25CFF);
  static const Color magenta = Color(0xFFF5279B);
  static const Color pink = Color(0xFFEC4899);
  static const Color gold = Color(0xFFFFC93C);
  static const Color goldDeep = Color(0xFFF5A623);

  // Semantic
  static const Color live = Color(0xFFFF2D55);
  static const Color success = Color(0xFF32D583);
  static const Color danger = Color(0xFFFF4D4F);
  static const Color diamond = Color(0xFF43B0FF);
  static const Color coin = Color(0xFFFFC93C);

  // Text
  static const Color textPrimary = Color(0xFFF6F3FF);
  static const Color textSecondary = Color(0xFFB6A8DB);
  static const Color textMuted = Color(0xFF7E719F);
  static const Color textOnPrimary = Color(0xFFFFFFFF);

  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFFB25CFF), Color(0xFF7C3AED)],
  );

  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF7C3AED), Color(0xFFC026D3), Color(0xFFF5279B)],
  );

  static const LinearGradient goldGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFFE08A), Color(0xFFFFC93C), Color(0xFFF5A623)],
  );

  static const LinearGradient liveGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFFFF2D55), Color(0xFFF5279B)],
  );

  static const RadialGradient heroGlow = RadialGradient(
    center: Alignment(0, -0.4),
    radius: 1.1,
    colors: [Color(0xFF2A1755), Color(0xFF0B0716)],
  );

  /// Palette used to derive deterministic avatar / thumbnail gradients.
  static const List<List<Color>> tints = [
    [Color(0xFF7C3AED), Color(0xFFF5279B)],
    [Color(0xFFF5279B), Color(0xFFFFA63C)],
    [Color(0xFF3AA0FF), Color(0xFF7C3AED)],
    [Color(0xFF32D583), Color(0xFF3AA0FF)],
    [Color(0xFFFF5C7A), Color(0xFFB25CFF)],
    [Color(0xFFFFC93C), Color(0xFFF5279B)],
    [Color(0xFF8B5CF6), Color(0xFF22D3EE)],
    [Color(0xFFEC4899), Color(0xFF8B5CF6)],
  ];
}
