import 'package:flutter/painting.dart';
import 'package:google_fonts/google_fonts.dart';

/// The font family the admin panel chose (Site / Branding -> Font). 'Poppins' is bundled with the app
/// and is the default; any other Google Fonts family is fetched on first use.
///
/// A name that is not a real Google font (a typo in the panel) never reaches the font loader, which
/// throws for those and used to take the whole app down: it quietly keeps Poppins instead.
class AppFont {
  AppFont._();

  static const String defaultFamily = 'Poppins';

  static String _family = defaultFamily;
  static Map<String, String>? _known; // lower-case -> real family name

  /// The family in use (always a real one).
  static String get family => _family;

  /// A font other than the bundled default is in use.
  static bool get isCustom => _family != defaultFamily;

  /// The real family name for what the panel typed ("open sans" -> "Open Sans"), or null when
  /// there is no such Google font.
  static String? resolve(String? typed) {
    final name = typed?.trim();
    if (name == null || name.isEmpty) return null;
    if (name.toLowerCase() == defaultFamily.toLowerCase()) return defaultFamily;
    final known = _known ??= {for (final k in GoogleFonts.asMap().keys) k.toLowerCase(): k};
    return known[name.toLowerCase()];
  }

  /// Use [typed] from now on. Returns whether it changed anything. Unknown or empty -> Poppins.
  static bool use(String? typed) {
    final next = resolve(typed) ?? defaultFamily;
    if (next == _family) return false;
    _family = next;
    return true;
  }

  /// [base] in the chosen family (weight, size and colour kept). With the default font it is returned as
  /// it is, so the app looks exactly as it always has.
  static TextStyle style(TextStyle base) {
    if (!isCustom) return base;
    try {
      return GoogleFonts.getFont(_family, textStyle: base);
    } catch (_) {
      return base;
    }
  }
}
