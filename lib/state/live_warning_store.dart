import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/supabase_client.dart';

/// The warning every new arrival sees in their own chat in a VIDEO live and in video PK (the rules of the house, like the "Welcome to the
/// room" notice other live apps open with). English is the key of the app's translations; a text typed in the panel is shown as written.
const String kDefaultLiveWarning =
    'Welcome to SABALIVE Live! Warning: no nudity, vulgarity, violence or children on camera or mic during a live. Lives are monitored and violations are punished!';

/// The longest text the panel accepts (the database refuses more).
const int kLiveWarningMaxChars = 600;

/// What the panel says about the welcome warning (Application Configuration -> Live welcome): on or off, and the text. [text] null =
/// the built-in, translated one.
@immutable
class LiveWarning {
  const LiveWarning({this.enabled = true, this.text});

  final bool enabled;
  final String? text;

  /// The text to show: the panel's, or the built-in one.
  String get shown => text ?? kDefaultLiveWarning;

  /// Reads an `app_config` row's two columns; anything missing or unreadable keeps the default (on, built-in text).
  factory LiveWarning.fromRow(Map<String, dynamic>? row) {
    if (row == null) return const LiveWarning();
    final raw = row['video_warning_text'];
    final text = raw is String ? raw.trim() : '';
    return LiveWarning(
      enabled: row['video_warning_enabled'] is bool ? row['video_warning_enabled'] as bool : true,
      text: text.isEmpty || text.length > kLiveWarningMaxChars ? null : text,
    );
  }

  Map<String, Object?> toJson() => {'video_warning_enabled': enabled, 'video_warning_text': text};

  @override
  bool operator ==(Object other) => other is LiveWarning && other.enabled == enabled && other.text == text;

  @override
  int get hashCode => Object.hash(enabled, text);
}

/// Holds the live [LiveWarning]. Applied from the phone's last copy before the first frame ([restore]) and re-read with the branding (launch,
/// resume, a panel save). FAILS OPEN: with no server, or a database that does not have the columns yet, the warning stays ON with the
/// built-in text: a house rule must not disappear because a settings read failed.
class LiveWarningStore extends ChangeNotifier {
  LiveWarningStore({Future<Map<String, dynamic>?> Function()? fetch}) : _fetch = fetch ?? _fetchFromServer;

  static final LiveWarningStore instance = LiveWarningStore();
  static const _kPrefs = 'live.warning.v1';

  final Future<Map<String, dynamic>?> Function() _fetch;
  LiveWarning _warning = const LiveWarning();
  bool _loading = false;

  LiveWarning get warning => _warning;

  /// Makes [next] the current warning. Returns whether anything changed.
  bool use(LiveWarning next) {
    if (next == _warning) return false;
    _warning = next;
    notifyListeners();
    return true;
  }

  /// Applies the copy saved by the last run. Never throws.
  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPrefs);
      if (raw != null) {
        final json = jsonDecode(raw);
        if (json is Map<String, dynamic>) use(LiveWarning.fromRow(json));
      }
    } catch (_) {}
  }

  /// Re-reads the panel's values. Never throws; a failed read keeps what is showing.
  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    try {
      final row = await _fetch();
      final next = LiveWarning.fromRow(row);
      use(next);
      unawaited(_remember(next));
    } catch (_) {
      // keep what is showing
    } finally {
      _loading = false;
    }
  }

  Future<void> _remember(LiveWarning w) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefs, jsonEncode(w.toJson()));
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> _fetchFromServer() =>
      supabase.from('app_config').select('video_warning_enabled, video_warning_text').maybeSingle();
}
