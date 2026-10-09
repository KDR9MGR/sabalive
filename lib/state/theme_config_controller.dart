import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';
import '../core/utils/rebuild_everything.dart';
import '../theme/app_colors.dart';
import '../theme/app_font.dart';
import '../theme/app_palette.dart';

/// The branding the admin panel sets (Site / Branding): brand colour, accent colour, font.
class Branding {
  const Branding({required this.brand, required this.accent, required this.font});

  final Color brand;
  final Color accent;
  final String font;

  static const Branding stock = Branding(
    brand: AppPalette.defaultBrand,
    accent: AppPalette.defaultAccent,
    font: AppFont.defaultFamily,
  );

  /// From an `app_config` row; anything missing or unreadable keeps [fallback]'s value.
  factory Branding.fromRow(Map<String, dynamic> row, {Branding fallback = stock}) {
    final font = (row['font_family'] as String?)?.trim();
    return Branding(
      brand: parseHex(row['brand_color'] as String?) ?? fallback.brand,
      accent: parseHex(row['accent_color'] as String?) ?? fallback.accent,
      font: font == null || font.isEmpty ? fallback.font : font,
    );
  }

  static Color? parseHex(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    final cleaned = hex.trim().replaceFirst('#', '');
    final padded = cleaned.length == 6 ? 'FF$cleaned' : cleaned;
    if (padded.length != 8) return null;
    final value = int.tryParse(padded, radix: 16);
    return value == null ? null : Color(value);
  }

  static String toHex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
}

/// Loads branding from the admin-panel-editable `app_config` singleton and keeps it live, so a change
/// made in the panel reaches running apps without a release.
///
/// What it drives:
///  * the brand colours and the dark backgrounds, through [AppColors.apply] (screens read `AppColors`
///    when they build, and everything is rebuilt when the palette changes);
///  * the font, through [AppFont] (the shared `Text` and the theme's text styles);
///  * the root MaterialApp theme.
///
/// The last branding is kept on the phone and applied before the first frame ([restore]), so the app
/// does not open in the stock colours and then change. It is re-read when the app returns to the
/// foreground and whenever the panel saves (Realtime; the `app_config` table is in the publication).
/// If the server can't be reached the app simply keeps what it has: a branding fetch never stops it.
class ThemeConfigController extends ChangeNotifier with WidgetsBindingObserver {
  ThemeConfigController() {
    WidgetsBinding.instance.addObserver(this);
    _load();
    _channel = supabase
        .channel('public:app_config:theme')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'app_config',
          callback: (_) => _load(),
        )
        .subscribe();
  }

  static const _kBrand = 'theme.brand';
  static const _kAccent = 'theme.accent';
  static const _kFont = 'theme.font';

  static Branding _current = Branding.stock;

  /// Applies the branding saved by the last run. Call once before `runApp`. Never throws.
  static Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = Branding.fromRow({
        'brand_color': prefs.getString(_kBrand),
        'accent_color': prefs.getString(_kAccent),
        'font_family': prefs.getString(_kFont),
      });
      _use(saved);
      _systemBarsFollowPalette();
    } catch (_) {}
  }

  /// Makes [b] the live branding. Returns whether the look changed.
  static bool _use(Branding b) {
    _current = b;
    final palette = AppPalette.fromBrand(b.brand, b.accent);
    final colorsChanged = palette != AppColors.palette;
    AppColors.apply(palette);
    final fontChanged = AppFont.use(b.font);
    return colorsChanged || fontChanged;
  }

  static void _systemBarsFollowPalette() {
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppColors.bg,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  }

  RealtimeChannel? _channel;
  bool _loading = false;

  Color get primary => AppColors.primary;
  Color get secondary => AppColors.magenta;
  String get fontFamily => AppFont.family;

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final row = await supabase
          .from('app_config')
          .select('brand_color, accent_color, font_family')
          .maybeSingle();
      if (row == null) return;
      final next = Branding.fromRow(row, fallback: _current);
      final changed = _use(next);
      unawaited(_remember(next));
      if (changed) {
        _systemBarsFollowPalette();
        notifyListeners();
        // screens read AppColors / the font as they build: have them all build again once the new
        // theme is in place
        WidgetsBinding.instance.addPostFrameCallback((_) => rebuildEverything());
      }
    } catch (_) {
      // Keep what is showing if app_config isn't reachable — the app
      // should never fail to start over a branding fetch.
    } finally {
      _loading = false;
    }
  }

  Future<void> _remember(Branding b) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kBrand, Branding.toHex(b.brand));
      await prefs.setString(_kAccent, Branding.toHex(b.accent));
      await prefs.setString(_kFont, b.font);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // a recolour made while the app was in the background (Realtime may have been asleep)
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _channel?.unsubscribe();
    super.dispose();
  }
}
