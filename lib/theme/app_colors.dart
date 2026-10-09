import 'package:flutter/material.dart';

import 'app_palette.dart';

/// SABALIVE palette — dark theme with purple / pink / gold brand accents.
class AppColors {
  AppColors._();

  /// The brand-driven colours (backgrounds, the purples, the accent) come from the panel's
  /// Site / Branding settings through [apply]; everything else below stays fixed. Read them when a
  /// widget builds, not in a `const` expression, so a recolour reaches a running app.
  static AppPalette _palette = AppPalette.stock;
  static AppPalette get palette => _palette;

  /// Switch to a new palette. Callers rebuild the UI afterwards (see ThemeConfigController).
  static void apply(AppPalette palette) => _palette = palette;

  // Backgrounds (the brand's hue, turned down to near-black)
  static Color get bg => _palette.bg;
  static Color get bgElevated => _palette.bgElevated;
  static Color get surface => _palette.surface;
  static Color get surfaceAlt => _palette.surfaceAlt;
  static Color get card => _palette.card;
  static Color get stroke => _palette.stroke;
  static const Color strokeSoft = Color(0x1AFFFFFF);

  /// The top of the audio room's backdrop; it fades down to [bg].
  static Color get roomTop => _palette.roomTop;

  // Brand
  static Color get primary => _palette.primary;
  static Color get primaryDeep => _palette.primaryDeep;
  static Color get primaryBright => _palette.primaryBright;
  static Color get magenta => _palette.magenta;
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
  static LinearGradient get primaryGradient => LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [primaryBright, identical(_palette, AppPalette.stock) ? const Color(0xFF7C3AED) : _palette.primaryDeep],
  );

  static LinearGradient get brandGradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: identical(_palette, AppPalette.stock)
        ? const [Color(0xFF7C3AED), Color(0xFFC026D3), Color(0xFFF5279B)]
        : [_palette.primaryDeep, Color.lerp(_palette.primary, _palette.magenta, 0.5)!, _palette.magenta],
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

  static RadialGradient get heroGlow => RadialGradient(
    center: const Alignment(0, -0.4),
    radius: 1.1,
    colors: [_palette.heroGlowTop, _palette.bg],
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
