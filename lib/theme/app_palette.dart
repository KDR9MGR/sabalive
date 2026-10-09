
import 'package:flutter/painting.dart';

/// The colours that follow the brand set in the admin panel (Site / Branding): the purple the app is
/// built around, the pink next to it, and the dark backgrounds, which are the brand's hue turned down
/// to almost black.
///
/// [AppPalette.stock] is exactly the original hand-picked set, so an app whose panel still has the
/// default brand looks the way it always has. Any other brand colour or accent derives a whole new set
/// with [AppPalette.fromBrand].
class AppPalette {
  const AppPalette({
    required this.bg,
    required this.bgElevated,
    required this.surface,
    required this.surfaceAlt,
    required this.card,
    required this.stroke,
    required this.primary,
    required this.primaryDeep,
    required this.primaryBright,
    required this.magenta,
    required this.heroGlowTop,
    required this.roomTop,
  });

  final Color bg;
  final Color bgElevated;
  final Color surface;
  final Color surfaceAlt;
  final Color card;
  final Color stroke;
  final Color primary;
  final Color primaryDeep;
  final Color primaryBright;

  /// The second brand colour (the panel's "accent"): buttons' pink, the live gradient's end.
  final Color magenta;

  /// The lighter end of the hero background glow.
  final Color heroGlowTop;

  /// The top of the audio room's backdrop (it fades down to [bg]).
  final Color roomTop;

  /// The original palette.
  static const AppPalette stock = AppPalette(
    bg: Color(0xFF0B0716),
    bgElevated: Color(0xFF130C24),
    surface: Color(0xFF1A1230),
    surfaceAlt: Color(0xFF221743),
    card: Color(0xFF1E1638),
    stroke: Color(0xFF2E2352),
    primary: Color(0xFF9B3DF5),
    primaryDeep: Color(0xFF6D28D9),
    primaryBright: Color(0xFFB25CFF),
    magenta: Color(0xFFF5279B),
    heroGlowTop: Color(0xFF2A1755),
    roomTop: Color(0xFF1B1140),
  );

  /// The brand and accent the panel ships with. Seeing these means "nothing was customised", so the
  /// stock palette (whose purple is a touch brighter than this one) is used as it is.
  static const Color defaultBrand = Color(0xFF7C3AED);
  static const Color defaultAccent = Color(0xFFF5279B);

  /// A whole palette from the panel's two colours.
  factory AppPalette.fromBrand(Color brand, Color accent) {
    if (_same(brand, defaultBrand) && _same(accent, defaultAccent)) return stock;
    final h = HSLColor.fromColor(brand);
    // the brand has to read on a near-black background: keep it out of the very dark and very pale
    final l = h.lightness.clamp(0.45, 0.66).toDouble();
    // a grey or white brand has no hue to tint with: its backgrounds stay neutral instead of turning red
    final s = h.saturation < 0.1 ? h.saturation : h.saturation.clamp(0.45, 1.0).toDouble();
    final hue = h.hue;
    final tintK = (h.saturation / 0.4).clamp(0.0, 1.0).toDouble();
    Color tint(double sat, double light) => HSLColor.fromAHSL(1, hue, sat * tintK, light).toColor();
    return AppPalette(
      // the stock backgrounds are this hue at these saturations / lightnesses
      bg: tint(0.52, 0.057),
      bgElevated: tint(0.55, 0.095),
      surface: tint(0.45, 0.13),
      surfaceAlt: tint(0.49, 0.176),
      card: tint(0.44, 0.153),
      stroke: tint(0.34, 0.23),
      primary: HSLColor.fromAHSL(1, hue, s, l).toColor(),
      primaryDeep: HSLColor.fromAHSL(1, hue, s, (l - 0.1).clamp(0.3, 0.6).toDouble()).toColor(),
      primaryBright: HSLColor.fromAHSL(1, hue, s, (l + 0.08).clamp(0.5, 0.78).toDouble()).toColor(),
      magenta: accent,
      heroGlowTop: tint(0.6, 0.2),
      roomTop: tint(0.6, 0.165),
    );
  }

  static bool _same(Color a, Color b) => (a.toARGB32() & 0xFFFFFF) == (b.toARGB32() & 0xFFFFFF);

  @override
  bool operator ==(Object other) =>
      other is AppPalette &&
      other.bg == bg &&
      other.bgElevated == bgElevated &&
      other.surface == surface &&
      other.surfaceAlt == surfaceAlt &&
      other.card == card &&
      other.stroke == stroke &&
      other.primary == primary &&
      other.primaryDeep == primaryDeep &&
      other.primaryBright == primaryBright &&
      other.magenta == magenta &&
      other.heroGlowTop == heroGlowTop &&
      other.roomTop == roomTop;

  @override
  int get hashCode => Object.hash(bg, bgElevated, surface, surfaceAlt, card, stroke, primary, primaryDeep,
      primaryBright, magenta, heroGlowTop, roomTop);
}
