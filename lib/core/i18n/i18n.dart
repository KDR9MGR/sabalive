import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_language.dart';
import 'strings_ar.dart';
import 'strings_bn.dart';
import 'strings_fil.dart';
import 'strings_hi.dart';
import 'strings_ne.dart';
import 'strings_pt_br.dart';
import 'strings_ur.dart';

/// The app's translations.
///
/// English text in the code is the key: every `Text` (see text.dart) and every hint /
/// tooltip passes its English string through [tr], which returns the chosen
/// language's version, or the English itself when there isn't one (English, Nigerian
/// English, anything not translated yet, and text that comes from the database).
/// A string with live values in it ("Seat {0} is taken") is matched as a template and
/// the values are put back into the translation.
class I18n {
  I18n._();

  static const _prefKey = 'settings.language.code';

  static AppLanguage _current = languageByCode('en');
  static AppLanguage get current => _current;

  /// MaterialApp listens to this for its locale (which also flips right-to-left).
  static final ValueNotifier<AppLanguage> notifier = ValueNotifier(_current);

  static final Map<String, Map<String, String>> _tables = {
    'hi': hiStrings,
    'bn': bnStrings,
    'ne': neStrings,
    'ur': urStrings,
    'ar': arStrings,
    'fil': filStrings,
    'pt_BR': ptBrStrings,
  };

  static Map<String, String> _exact = const {};
  static List<_Template> _templates = const [];
  static final Map<String, String> _cache = {};

  /// Reads the saved language; call before runApp so the first frame is right.
  static Future<void> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      _apply(languageByCode(sp.getString(_prefKey)));
    } catch (_) {
      _apply(languageByCode('en'));
    }
    notifier.value = _current;
  }

  /// Switches the whole app to [language] right now and remembers it.
  static Future<void> set(AppLanguage language) async {
    _apply(language);
    notifier.value = language;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_prefKey, language.code);
    } catch (_) {}
    _rebuildEverything();
  }

  static void _apply(AppLanguage language) {
    _current = language;
    _cache.clear();
    final table = _tables[language.code] ?? const <String, String>{};
    _exact = {
      for (final e in table.entries)
        if (!_hasPlaceholder(e.key)) e.key: e.value,
    };
    _templates = [
      for (final e in table.entries)
        if (_hasPlaceholder(e.key)) _Template(e.key, e.value),
    ]..sort((a, b) => b.literalLength.compareTo(a.literalLength));
  }

  static bool _hasPlaceholder(String s) => _placeholder.hasMatch(s);
  static final _placeholder = RegExp(r'\{\d+\}');

  /// The text in the current language (see the class comment).
  static String tr(String english) {
    if (_exact.isEmpty && _templates.isEmpty) return english;
    final cached = _cache[english];
    if (cached != null) return cached;
    var out = _exact[english];
    if (out == null) {
      for (final t in _templates) {
        out = t.translate(english);
        if (out != null) break;
      }
    }
    out ??= english;
    if (_cache.length > 4000) _cache.clear();
    return _cache[english] = out;
  }

  /// Every widget reads its text again, without losing where the user is (the
  /// navigation, an open live, a half-typed message all stay as they were).
  static void _rebuildEverything() {
    void visit(Element e) {
      e.markNeedsBuild();
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
  }
}

/// `tr` as a plain function, for hints, tooltips and other text that isn't a `Text`.
String tr(String english) => I18n.tr(english);

class _Template {
  _Template(String key, this.translation)
      : literalLength = key.replaceAll(RegExp(r'\{\d+\}'), '').length,
        _regex = _compile(key);

  final String translation;
  final int literalLength;
  final RegExp _regex;

  static RegExp _compile(String key) {
    final b = StringBuffer('^');
    var last = 0;
    for (final m in RegExp(r'\{\d+\}').allMatches(key)) {
      b.write(RegExp.escape(key.substring(last, m.start)));
      // a value: short, never spans a line
      b.write(r'([^\n]{1,48}?)');
      last = m.end;
    }
    b.write(RegExp.escape(key.substring(last)));
    b.write(r'$');
    return RegExp(b.toString());
  }

  String? translate(String s) {
    final m = _regex.firstMatch(s);
    if (m == null) return null;
    return translation.replaceAllMapped(
      RegExp(r'\{(\d+)\}'),
      (p) {
        final i = int.parse(p.group(1)!);
        return i < m.groupCount ? (m.group(i + 1) ?? '') : '';
      },
    );
  }
}
