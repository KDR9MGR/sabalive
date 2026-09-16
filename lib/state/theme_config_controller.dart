import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';

/// Loads branding (primary/accent colour, font family) from the admin-panel
/// -editable `app_config` singleton and keeps it live via Realtime, so a
/// change made in the admin panel reaches running apps without a release —
/// no app-store update needed for a recolour.
///
/// This is the *foundation*: it drives the root MaterialApp theme (default
/// Material component styling, Theme.of(context).textTheme). Most screens
/// in this app hardcode `AppColors.xxx` directly rather than reading from
/// the ambient theme, so they won't visually change until migrated onto
/// this controller — a separate, larger follow-up.
class ThemeConfigController extends ChangeNotifier {
  ThemeConfigController() {
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

  Color _primary = const Color(0xFF7C3AED);
  Color _secondary = const Color(0xFFF5279B);
  String _fontFamily = 'Poppins';
  RealtimeChannel? _channel;

  Color get primary => _primary;
  Color get secondary => _secondary;
  String get fontFamily => _fontFamily;

  Future<void> _load() async {
    try {
      final row = await supabase
          .from('app_config')
          .select('brand_color, accent_color, font_family')
          .maybeSingle();
      if (row == null) return;
      _primary = _parseColor(row['brand_color'] as String?) ?? _primary;
      _secondary = _parseColor(row['accent_color'] as String?) ?? _secondary;
      final font = (row['font_family'] as String?)?.trim();
      if (font != null && font.isNotEmpty) _fontFamily = font;
      notifyListeners();
    } catch (_) {
      // Keep the built-in defaults if app_config isn't reachable — the app
      // should never fail to start over a branding fetch.
    }
  }

  static Color? _parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    final cleaned = hex.trim().replaceFirst('#', '');
    final padded = cleaned.length == 6 ? 'FF$cleaned' : cleaned;
    final value = int.tryParse(padded, radix: 16);
    return value == null ? null : Color(value);
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }
}
