import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/supabase_client.dart';
import '../theme/app_colors.dart';

/// The two sides of a PK battle: [mine] is the host of the live being looked at (the red side by default), [theirs] the other host.
enum PkTeam { mine, theirs }

/// The style of the badge a host sees when they lose: the shield (`LOSE`, like the WIN and DRAW badges) or the crying face.
enum PkLoseStyle { shield, emoji }

/// How PK looks, as the admin panel sets it (PK Battles -> Look and colours; the `app_config.pk_theme` JSON):
///  * the colour of each side and an accent (the clock pill, the labels);
///  * the two colours of the gradient behind the VIDEO PK stage (it used to be plain black);
///  * whether the PK animations play at all (off = the plain bars and text; for weak phones);
///  * an optional big full-screen intro behind the 3-2-1;
///  * the style of the lose badge.
/// Every part is optional: whatever is missing or unreadable keeps the built-in look (the default [PkTheme] IS the look the app had
/// before the panel could change it).
@immutable
class PkTheme {
  const PkTheme({
    this.mine = defaultMine,
    this.theirs = defaultTheirs,
    this.accent = defaultAccent,
    this.bgTop = defaultBgTop,
    this.bgBottom = defaultBgBottom,
    this.animations = true,
    this.heroIntro = false,
    this.loseStyle = PkLoseStyle.shield,
  });

  static const Color defaultMine = Color(0xFFFF2D55);
  static const Color defaultTheirs = Color(0xFF2D6BFF);
  static const Color defaultAccent = AppColors.gold;

  /// The gradient behind the video PK stage, top to bottom: a deep violet into a dark navy, so the two red / blue frames stand out.
  static const Color defaultBgTop = Color(0xFF33104F);
  static const Color defaultBgBottom = Color(0xFF0B1636);

  /// The hue (degrees) of the red and of the blue animation art in `assets/pk/` (measured; `tool/pk_assets/README.md`). A side
  /// colour is shown by turning that hue to the chosen colour's hue.
  static const double mineArtHue = 3;
  static const double theirsArtHue = 203;

  final Color mine;
  final Color theirs;
  final Color accent;
  final Color bgTop;
  final Color bgBottom;
  final bool animations;
  final bool heroIntro;
  final PkLoseStyle loseStyle;

  /// Reads the panel's JSON. Anything that is not understood keeps the default, so a half-saved or hand-edited value can't break PK.
  factory PkTheme.fromJson(Object? json) {
    if (json is! Map) return const PkTheme();
    Color colour(String key, Color fallback) {
      final raw = json[key];
      if (raw is! String) return fallback;
      final hex = raw.trim().replaceFirst('#', '');
      if (hex.length != 6) return fallback;
      final v = int.tryParse(hex, radix: 16);
      return v == null ? fallback : Color(0xFF000000 | v);
    }

    return PkTheme(
      mine: colour('mine', defaultMine),
      theirs: colour('theirs', defaultTheirs),
      accent: colour('accent', defaultAccent),
      bgTop: colour('bg_top', defaultBgTop),
      bgBottom: colour('bg_bottom', defaultBgBottom),
      animations: json['animations'] is bool ? json['animations'] as bool : true,
      heroIntro: json['hero_intro'] is bool ? json['hero_intro'] as bool : false,
      loseStyle: json['lose_style'] == 'emoji' ? PkLoseStyle.emoji : PkLoseStyle.shield,
    );
  }

  static String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  Map<String, Object> toJson() => {
    'mine': _hex(mine),
    'theirs': _hex(theirs),
    'accent': _hex(accent),
    'bg_top': _hex(bgTop),
    'bg_bottom': _hex(bgBottom),
    'animations': animations,
    'hero_intro': heroIntro,
    'lose_style': loseStyle.name,
  };

  Color colorOf(PkTeam team) => team == PkTeam.mine ? mine : theirs;

  /// What fills the screen behind the video PK stage.
  LinearGradient get backdrop => LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [bgTop, bgBottom]);

  /// The two colours of a side's half of the audio arena, top and bottom. The built-in colours are kept exactly as they were; a
  /// chosen colour gets a deep and a darker shade of its own hue.
  List<Color> halfColors(PkTeam team) {
    final colour = colorOf(team);
    if (team == PkTeam.mine && colour == defaultMine) return const [Color(0xFFB1122B), Color(0xFF3A0A16)];
    if (team == PkTeam.theirs && colour == defaultTheirs) return const [Color(0xFF11489B), Color(0xFF0A1B3A)];
    final hsl = HSLColor.fromColor(colour);
    final s = hsl.saturation.clamp(0.0, 0.85);
    return [hsl.withSaturation(s).withLightness(0.36).toColor(), hsl.withSaturation(s * 0.85).withLightness(0.12).toColor()];
  }

  /// A side's bar colours for the plain (no animation) bars: light to full.
  List<Color> barColors(PkTeam team) {
    final colour = colorOf(team);
    if (team == PkTeam.mine && colour == defaultMine) return const [Color(0xFFFF2D55), Color(0xFFFF7A9C)];
    if (team == PkTeam.theirs && colour == defaultTheirs) return const [Color(0xFF9CC6FF), Color(0xFF2D6BFF)];
    final light = Color.lerp(colour, Colors.white, 0.45)!;
    return team == PkTeam.mine ? [colour, light] : [light, colour];
  }

  /// The gradient of the clock pill and the labels: the built-in gold unless the accent was changed.
  Gradient get accentGradient {
    if (accent == defaultAccent) return AppColors.goldGradient;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color.lerp(accent, Colors.white, 0.4)!, accent, Color.lerp(accent, Colors.black, 0.22)!],
    );
  }

  /// Degrees to turn the hue of a side's animation art so it shows this theme's colour; 0 while the colour is the built-in one.
  double hueShift(PkTeam team) {
    final colour = colorOf(team);
    if (colour == (team == PkTeam.mine ? defaultMine : defaultTheirs)) return 0;
    var delta = HSVColor.fromColor(colour).hue - (team == PkTeam.mine ? mineArtHue : theirsArtHue);
    delta = (delta + 540) % 360 - 180; // into -180..180: the short way round
    return delta;
  }

  @override
  bool operator ==(Object other) =>
      other is PkTheme &&
      other.mine == mine &&
      other.theirs == theirs &&
      other.accent == accent &&
      other.bgTop == bgTop &&
      other.bgBottom == bgBottom &&
      other.animations == animations &&
      other.heroIntro == heroIntro &&
      other.loseStyle == loseStyle;

  @override
  int get hashCode => Object.hash(mine, theirs, accent, bgTop, bgBottom, animations, heroIntro, loseStyle);
}

/// The 4 x 5 colour matrix that turns every colour by [degrees] around the colour wheel (the SVG `hueRotate`), for a
/// `ColorFilter.matrix`.
List<double> pkHueMatrix(double degrees) {
  final r = degrees * math.pi / 180;
  final c = math.cos(r);
  final s = math.sin(r);
  return [
    0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928, 0, 0, //
    0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283, 0, 0, //
    0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072, 0, 0, //
    0, 0, 0, 1, 0,
  ];
}

/// Holds the live [PkTheme]. The look saved by the last run is applied before the first frame ([restore]); it is re-read from
/// `app_config.pk_theme` whenever branding is (launch, resume, a panel save: see `ThemeConfigController`). It FAILS OPEN like the
/// branding does: if the server can't be reached, or the column is not there yet (the migration has not been applied), the app
/// keeps what it has. Nothing here can stop PK or the app from starting.
class PkThemeStore extends ChangeNotifier {
  PkThemeStore({Future<Object?> Function()? fetch}) : _fetch = fetch ?? _fetchFromServer;

  static final PkThemeStore instance = PkThemeStore();
  static const _kPrefs = 'pk.theme.v1';

  final Future<Object?> Function() _fetch;
  PkTheme _theme = const PkTheme();
  bool _loading = false;

  PkTheme get theme => _theme;

  /// Makes [next] the look. Returns whether anything changed (listeners are told only then).
  bool use(PkTheme next) {
    if (next == _theme) return false;
    _theme = next;
    notifyListeners();
    return true;
  }

  /// Applies the look saved by the last run. Never throws.
  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPrefs);
      if (raw != null) use(PkTheme.fromJson(jsonDecode(raw)));
    } catch (_) {}
  }

  /// Re-reads the panel's value. Never throws; a failed read keeps the current look.
  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    try {
      final json = await _fetch();
      final next = PkTheme.fromJson(json); // null (nothing saved) = the built-in look
      use(next);
      unawaited(_remember(next));
    } catch (_) {
      // keep what is showing
    } finally {
      _loading = false;
    }
  }

  Future<void> _remember(PkTheme t) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefs, jsonEncode(t.toJson()));
    } catch (_) {}
  }

  static Future<Object?> _fetchFromServer() async {
    final row = await supabase.from('app_config').select('pk_theme').maybeSingle();
    return row?['pk_theme'];
  }
}
