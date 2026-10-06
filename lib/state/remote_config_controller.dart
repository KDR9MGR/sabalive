import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../config/supabase_client.dart';

/// What the server tells every app build, from the `app_config` row the admin panel edits.
class ReleaseConfig {
  const ReleaseConfig({
    this.minAndroid = 0,
    this.minIos = 0,
    this.message = '',
    this.androidStoreUrl = '',
    this.iosStoreUrl = '',
    this.flags = const {},
  });

  /// Builds below this show the "Update required" screen. 0 = no minimum.
  final int minAndroid;
  final int minIos;
  final String message;
  final String androidStoreUrl;
  final String iosStoreUrl;

  /// Server-side switches: `{"animated_frames": false}`. An absent key keeps the app's default.
  final Map<String, bool> flags;

  factory ReleaseConfig.fromRow(Map<String, dynamic> row) {
    int number(Object? v) => v is num ? v.toInt() : (int.tryParse('$v') ?? 0);
    final raw = row['feature_flags'];
    return ReleaseConfig(
      minAndroid: number(row['min_android_version_code']),
      minIos: number(row['min_ios_build']),
      message: (row['update_message'] as String?)?.trim() ?? '',
      androidStoreUrl: (row['android_store_url'] as String?)?.trim() ?? '',
      iosStoreUrl: (row['ios_store_url'] as String?)?.trim() ?? '',
      flags: {
        if (raw is Map)
          for (final e in raw.entries)
            if (e.value is bool) '${e.key}': e.value as bool,
      },
    );
  }

  /// True when this build is older than the minimum for its platform. A build number that could not be
  /// read (0) is never blocked: when in doubt the app must keep working.
  bool requiresUpdate({required int buildNumber, required bool isIos}) {
    final min = isIos ? minIos : minAndroid;
    return min > 0 && buildNumber > 0 && buildNumber < min;
  }

  String storeUrl({required bool isIos}) => isIos ? iosStoreUrl : androidStoreUrl;
}

/// Reads [ReleaseConfig] once at launch and again when the app comes back to the foreground, and answers
/// two questions: "must this build update?" and "is this switch on?".
///
/// It FAILS OPEN: if the server cannot be reached, or the columns are not there yet (the migration has not
/// been applied), nothing is blocked and every switch keeps its default. A release control must never be able
/// to take the app down by itself. It uses no Realtime channel and no polling: one small read per launch/resume
/// (the database allows only 60 connections).
class RemoteConfigController extends ChangeNotifier with WidgetsBindingObserver {
  RemoteConfigController({
    Future<Map<String, dynamic>?> Function()? fetch,
    Future<int> Function()? buildNumber,
    bool? isIos,
    this.minGap = const Duration(minutes: 5),
    DateTime Function()? clock,
  })  : _fetch = fetch ?? _fetchFromServer,
        _buildNumber = buildNumber ?? _readBuildNumber,
        _isIos = isIos ?? _platformIsIos(),
        _clock = clock ?? DateTime.now;

  static final RemoteConfigController instance = RemoteConfigController();

  final Future<Map<String, dynamic>?> Function() _fetch;
  final Future<int> Function() _buildNumber;
  final bool _isIos;
  final Duration minGap;
  final DateTime Function() _clock;

  ReleaseConfig _config = const ReleaseConfig();
  int _build = 0;
  DateTime? _lastFetch;
  bool _started = false;

  ReleaseConfig get config => _config;
  int get buildNumber => _build;
  bool get isIos => _isIos;
  bool get updateRequired => _config.requiresUpdate(buildNumber: _build, isIos: _isIos);
  String get storeUrl => _config.storeUrl(isIos: _isIos);

  /// Is the server-side switch [key] on? [defaultValue] is used until the server says otherwise.
  bool flag(String key, {bool defaultValue = true}) => _config.flags[key] ?? defaultValue;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    try {
      _build = await _buildNumber();
    } catch (_) {
      _build = 0; // unknown: never block
    }
    await refresh(force: true);
  }

  /// Re-reads the config. Skipped if it was read less than [minGap] ago, unless [force].
  Future<void> refresh({bool force = false}) async {
    final last = _lastFetch;
    if (!force && last != null && _clock().difference(last) < minGap) return;
    _lastFetch = _clock();
    try {
      final row = await _fetch();
      if (row == null) return;
      final before = (_config.minAndroid, _config.minIos, _config.message, _config.androidStoreUrl, _config.iosStoreUrl);
      final next = ReleaseConfig.fromRow(row);
      final same = before == (next.minAndroid, next.minIos, next.message, next.androidStoreUrl, next.iosStoreUrl) &&
          _sameFlags(_config.flags, next.flags);
      _config = next;
      if (!same) notifyListeners();
    } catch (_) {
      // unreachable, or the columns do not exist yet: keep what we had (by default: no minimum, defaults on)
    }
  }

  static bool _sameFlags(Map<String, bool> a, Map<String, bool> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  static bool _platformIsIos() {
    try {
      return Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  static Future<int> _readBuildNumber() async {
    final info = await PackageInfo.fromPlatform();
    return int.tryParse(info.buildNumber) ?? 0;
  }

  static Future<Map<String, dynamic>?> _fetchFromServer() => supabase
      .from('app_config')
      .select('min_android_version_code, min_ios_build, update_message, android_store_url, ios_store_url, feature_flags')
      .eq('id', true)
      .maybeSingle()
      .timeout(const Duration(seconds: 4));
}
