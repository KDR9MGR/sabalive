import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/supabase_client.dart';

/// Which kind of live a warning is for: VIDEO lives (and video PK) or AUDIO lives (and audio PK). Each has its own text, its own on / off switch and its own
/// built-in wording, all set from the panel.
enum LiveWarningKind { video, audio }

/// The warning every new arrival sees in their own chat (the rules of the house, like the "Welcome to the room" notice other live apps open with). English
/// is the key of the app's translations; a text typed in the panel is shown as written.
const String kDefaultVideoWarning =
    'Welcome to SABALIVE Live! Warning: no nudity, vulgarity, violence or children on camera or mic during a live. Lives are monitored and violations are punished!';

/// The audio version: no camera in a voice room, so it is about what is said.
const String kDefaultAudioWarning =
    'Welcome to the SABALIVE audio room! Please be respectful: no abuse, vulgarity, hate speech or harassment, and no children on the mic. Rooms are monitored and violations are punished!';

String defaultLiveWarning(LiveWarningKind kind) => kind == LiveWarningKind.video ? kDefaultVideoWarning : kDefaultAudioWarning;

/// The longest text the panel accepts (the database refuses more).
const int kLiveWarningMaxChars = 600;

/// What the panel says about one warning (Application Configuration -> Live welcome): on or off, and the text. [text] null = the built-in,
/// translated one for this [kind].
@immutable
class LiveWarning {
  const LiveWarning({this.enabled = true, this.text, this.kind = LiveWarningKind.video});

  final bool enabled;
  final String? text;
  final LiveWarningKind kind;

  /// The text to show: the panel's, or the built-in one.
  String get shown => text ?? defaultLiveWarning(kind);

  /// Reads an `app_config` row's two columns for [kind] (`video_warning_*` or `audio_warning_*`); anything missing or unreadable keeps the
  /// default (on, built-in text).
  factory LiveWarning.fromRow(Map<String, dynamic>? row, {LiveWarningKind kind = LiveWarningKind.video}) {
    if (row == null) return LiveWarning(kind: kind);
    final raw = row['${kind.name}_warning_text'];
    final text = raw is String ? raw.trim() : '';
    final enabled = row['${kind.name}_warning_enabled'];
    return LiveWarning(
      enabled: enabled is bool ? enabled : true,
      text: text.isEmpty || text.length > kLiveWarningMaxChars ? null : text,
      kind: kind,
    );
  }

  @override
  bool operator ==(Object other) => other is LiveWarning && other.enabled == enabled && other.text == text && other.kind == kind;

  @override
  int get hashCode => Object.hash(enabled, text, kind);
}

/// Holds the live warnings, one per kind. Applied from the phone's last copy before the first frame ([restore]) and re-read with the branding (launch,
/// resume, a panel save). FAILS OPEN: with no server, or a database that does not have the columns yet, both warnings stay ON with the built-in text: a
/// house rule must not disappear because a settings read failed.
class LiveWarningStore extends ChangeNotifier {
  LiveWarningStore({Future<Map<String, dynamic>?> Function()? fetch}) : _fetch = fetch ?? _fetchFromServer;

  static final LiveWarningStore instance = LiveWarningStore();
  static const _kPrefs = 'live.warning.v2';

  final Future<Map<String, dynamic>?> Function() _fetch;
  LiveWarning _video = const LiveWarning();
  LiveWarning _audio = const LiveWarning(kind: LiveWarningKind.audio);
  bool _loading = false;

  LiveWarning get video => _video;
  LiveWarning get audio => _audio;
  LiveWarning warningFor(LiveWarningKind kind) => kind == LiveWarningKind.video ? _video : _audio;

  /// Makes these the current warnings. Returns whether anything changed.
  bool use({LiveWarning? video, LiveWarning? audio}) {
    final nextVideo = video ?? _video;
    final nextAudio = audio ?? _audio;
    if (nextVideo == _video && nextAudio == _audio) return false;
    _video = nextVideo;
    _audio = nextAudio;
    notifyListeners();
    return true;
  }

  void _useRow(Map<String, dynamic>? row) =>
      use(video: LiveWarning.fromRow(row), audio: LiveWarning.fromRow(row, kind: LiveWarningKind.audio));

  /// Applies the copy saved by the last run. Never throws.
  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPrefs);
      if (raw != null) {
        final json = jsonDecode(raw);
        if (json is Map<String, dynamic>) _useRow(json);
      }
    } catch (_) {}
  }

  /// Re-reads the panel's values. Never throws; a failed read keeps what is showing.
  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    try {
      final row = await _fetch();
      _useRow(row);
      unawaited(_remember(row));
    } catch (_) {
      // keep what is showing
    } finally {
      _loading = false;
    }
  }

  Future<void> _remember(Map<String, dynamic>? row) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // only the four columns, so what is kept on the phone is exactly what the panel set
      final keep = <String, Object?>{
        for (final k in const ['video_warning_enabled', 'video_warning_text', 'audio_warning_enabled', 'audio_warning_text']) k: row?[k],
      };
      await prefs.setString(_kPrefs, jsonEncode(keep));
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> _fetchFromServer() => supabase
      .from('app_config')
      .select('video_warning_enabled, video_warning_text, audio_warning_enabled, audio_warning_text')
      .maybeSingle();
}
