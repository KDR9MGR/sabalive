import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stops screenshots and screen recordings of the app, when the admin panel switches it on
/// (Application Config -> Release controls -> "Block screenshots and screen recording").
///
/// On Android this sets the window's FLAG_SECURE (MainActivity.kt): screenshots, screen recorders, casting and the
/// recent-apps picture then show black. An iPhone gives apps no way to block screenshots, so there it does nothing.
/// The last choice is kept on the phone and applied before the first screen, so the app is protected from the moment
/// it opens. A phone without the native side (iOS, tests) just ignores the call.
class ScreenProtection {
  ScreenProtection._();

  static const MethodChannel _channel = MethodChannel('com.sabalive.in/screen_protection');
  static const _prefKey = 'screen_protection.on';

  static bool _on = false;

  /// Protection is on right now.
  static bool get isOn => _on;

  /// Applies what the last run saved. Call once before `runApp`. Never throws.
  static Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _apply(prefs.getBool(_prefKey) ?? false);
    } catch (_) {}
  }

  /// Turns protection on or off (and remembers it). Does nothing if it is already so. Never throws.
  static Future<void> set(bool on) async {
    if (on == _on) return;
    await _apply(on);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, on);
    } catch (_) {}
  }

  static Future<void> _apply(bool on) async {
    try {
      await _channel.invokeMethod<void>('setSecure', {'on': on});
      _on = on;
    } on MissingPluginException {
      // iOS (cannot block screenshots) or a test: nothing to switch
    } catch (e) {
      debugPrint('screen protection failed: $e');
    }
  }

  /// For tests: forget what was applied.
  static void resetForTest() => _on = false;
}
