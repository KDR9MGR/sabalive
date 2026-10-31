
import 'package:flutter/painting.dart';

/// How dark the backgrounds are (the panel's Site / Branding "Background tone"). The text is light and fixed, so every tone stays dark
/// enough to read it; they differ in how much COLOUR the background carries.
///  * [deep]: the brand's hue turned down to almost black (how the app looked until 2026-10-31).
///  * [rich]: clearly coloured, no longer black (the default).
///  * [soft]: the lightest the fixed text can sit on.
enum BackgroundTone {
  deep,
  rich,
  soft;

  /// From the panel's `brand_tone` value; anything missing or unknown is [rich].
  static BackgroundTone parse(String? value) => switch (value?.trim().toLowerCase()) {
        'deep' => BackgroundTone.deep,
        'soft' => BackgroundTone.soft,
        _ => BackgroundTone.rich,
      };
}

/// The colours that follow the brand set in the admin panel (Site / Branding): the purple the app is
/// built around, the pink next to it, and the backgrounds, which are the brand's hue at the brightness of the chosen
/// [BackgroundTone].
///
/// [AppPalette.stock] is exactly the original hand-picked set (the default brand with the [BackgroundTone.deep] tone). The default
/// brand with any other tone keeps the original purples and pink and tints the backgrounds. Any other brand colour or accent derives
/// a whole new set with [AppPalette.fromBrand].
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
    this.stockBrand = false,
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

  /// Is this the panel's default brand + accent (the app's original violet and pink)? Their gradients keep the original look.
  final bool stockBrand;

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
    stockBrand: true,
  );

  /// What the app wears before the panel's branding has been read (and for ever when it cannot be): the default brand with the default tone.
  static final AppPalette initial = AppPalette.fromBrand(defaultBrand, defaultAccent);

  /// The brand and accent the panel ships with. Seeing these means "nothing was customised", so the
  /// stock palette (whose purple is a touch brighter than this one) is used as it is.
  static const Color defaultBrand = Color(0xFF7C3AED);
  static const Color defaultAccent = Color(0xFFF5279B);

  /// A whole palette from the panel's two colours and the background [tone].
  factory AppPalette.fromBrand(Color brand, Color accent, {BackgroundTone tone = BackgroundTone.rich}) {
    final isDefault = _same(brand, defaultBrand) && _same(accent, defaultAccent);
    if (isDefault && tone == BackgroundTone.deep) return stock;
    final h = HSLColor.fromColor(brand);
    // the brand has to read on a dark background: keep it out of the very dark and very pale
    final l = h.lightness.clamp(0.45, 0.66).toDouble();
    // a grey or white brand has no hue to tint with: its backgrounds stay neutral instead of turning red
    final s = h.saturation < 0.1 ? h.saturation : h.saturation.clamp(0.45, 1.0).toDouble();
    final hue = h.hue;
    final tintK = (h.saturation / 0.4).clamp(0.0, 1.0).toDouble();
    Color tint(double sat, double light) => HSLColor.fromAHSL(1, hue, sat * tintK, light).toColor();
    // rich / soft: the lightness is chosen so every hue has the same BRIGHTNESS (relative luminance), because a green and a violet at the
    // same HSL lightness are far apart to the eye, and the text on top is fixed
    Color shade(double sat, double luminance) => _atLuminance(hue, sat * tintK, luminance);
    final deep = tone == BackgroundTone.deep;
    final soft = tone == BackgroundTone.soft;
    double y(double rich, double softer) => soft ? softer : rich;
    final stockBrandColours = isDefault ? stock : null;
    return AppPalette(
      // deep: the stock backgrounds, which are this hue at these saturations / lightnesses
      bg: deep ? tint(0.52, 0.057) : shade(0.55, y(0.026, 0.06)),
      bgElevated: deep ? tint(0.55, 0.095) : shade(0.55, y(0.034, 0.072)),
      surface: deep ? tint(0.45, 0.13) : shade(0.50, y(0.043, 0.085)),
      surfaceAlt: deep ? tint(0.49, 0.176) : shade(0.52, y(0.056, 0.105)),
      card: deep ? tint(0.44, 0.153) : shade(0.50, y(0.049, 0.092)),
      stroke: deep ? tint(0.34, 0.23) : shade(0.42, y(0.078, 0.14)),
      primary: stockBrandColours?.primary ?? HSLColor.fromAHSL(1, hue, s, l).toColor(),
      primaryDeep: stockBrandColours?.primaryDeep ?? HSLColor.fromAHSL(1, hue, s, (l - 0.1).clamp(0.3, 0.6).toDouble()).toColor(),
      primaryBright: stockBrandColours?.primaryBright ?? HSLColor.fromAHSL(1, hue, s, (l + 0.08).clamp(0.5, 0.78).toDouble()).toColor(),
      magenta: accent,
      heroGlowTop: deep ? tint(0.6, 0.2) : shade(0.60, y(0.075, 0.13)),
      roomTop: deep ? tint(0.6, 0.165) : shade(0.60, y(0.062, 0.11)),
      stockBrand: isDefault,
    );
  }

  /// The colour of [hue] and [saturation] whose relative luminance (WCAG) is [target]: the HSL lightness found by halving, which is exact
  /// enough (24 steps) and the same search the panel's preview runs (sabaliveadmin/src/lib/appPalette.js).
  static Color _atLuminance(double hue, double saturation, double target) {
    var lo = 0.0, hi = 0.9;
    for (var i = 0; i < 24; i++) {
      final mid = (lo + hi) / 2;
      if (HSLColor.fromAHSL(1, hue, saturation, mid).toColor().computeLuminance() < target) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return HSLColor.fromAHSL(1, hue, saturation, (lo + hi) / 2).toColor();
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
      other.roomTop == roomTop &&
      other.stockBrand == stockBrand;

  @override
  int get hashCode => Object.hash(bg, bgElevated, surface, surfaceAlt, card, stroke, primary, primaryDeep,
      primaryBright, magenta, heroGlowTop, roomTop, stockBrand);
}
