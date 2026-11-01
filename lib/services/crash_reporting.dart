import 'dart:async';
import 'dart:io' show ProcessInfo;

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/media/gift_movie_cache.dart';

/// One earlier end of this app's process, as Android itself recorded it (ApplicationExitInfo, Android 11 and newer).
///
/// This is what tells a crash from a freeze from the phone killing the app for memory: from the outside they all look like "the app closed".
class PreviousExit {
  const PreviousExit({
    required this.reason,
    required this.status,
    required this.importance,
    required this.timestamp,
    required this.rssKb,
    required this.description,
  });

  /// Reads one entry of the list MainActivity.kt returns; a missing or odd value never throws.
  factory PreviousExit.fromMap(Map<Object?, Object?> m) => PreviousExit(
        reason: (m['reason'] as num?)?.toInt() ?? 0,
        status: (m['status'] as num?)?.toInt() ?? 0,
        importance: (m['importance'] as num?)?.toInt() ?? 1000,
        timestamp: (m['timestamp'] as num?)?.toInt() ?? 0,
        rssKb: (m['rssKb'] as num?)?.toInt() ?? 0,
        description: (m['description'] as String?) ?? '',
      );

  final int reason;

  /// For a signal kill the signal number (9 = killed, 11 = segmentation fault, 6 = abort), otherwise the exit code.
  final int status;
  final int importance;

  /// Milliseconds since 1970.
  final int timestamp;
  final int rssKb;
  final String description;

  /// The names of ApplicationExitInfo.REASON_*.
  static const reasonNames = <int, String>{
    0: 'UNKNOWN',
    1: 'EXIT_SELF',
    2: 'SIGNALED',
    3: 'LOW_MEMORY',
    4: 'CRASH',
    5: 'CRASH_NATIVE',
    6: 'ANR',
    7: 'INITIALIZATION_FAILURE',
    8: 'PERMISSION_CHANGE',
    9: 'EXCESSIVE_RESOURCE_USAGE',
    10: 'USER_REQUESTED',
    11: 'USER_STOPPED',
    12: 'DEPENDENCY_DIED',
    13: 'OTHER',
    14: 'FREEZER',
    15: 'PACKAGE_STATE_CHANGE',
    16: 'PACKAGE_UPDATED',
  };

  static const _crashKinds = {4, 5, 6}; // crash, native crash, ANR: reported whatever the app was doing
  static const _badKinds = {0, 2, 3, 7, 9, 12, 13}; // reported when the person was using the app

  /// RunningAppProcessInfo.IMPORTANCE_PERCEPTIBLE and more important: on screen, visible, or playing sound.
  static const _inUse = 230;

  String get reasonName => reasonNames[reason] ?? 'REASON_$reason';

  String get importanceName => switch (importance) {
        <= 100 => 'FOREGROUND',
        <= 125 => 'FOREGROUND_SERVICE',
        <= 200 => 'VISIBLE',
        <= 230 => 'PERCEPTIBLE',
        <= 300 => 'SERVICE',
        <= 400 => 'CACHED',
        _ => 'GONE',
      };

  /// Is this a death worth a report? Quiet ends (the person swiped the app away, an update) are not, and neither is
  /// Android tidying up an app nobody was using.
  bool get worthReporting => _crashKinds.contains(reason) || (_badKinds.contains(reason) && importance <= _inUse);

  /// One line for the report: what ended the app, while doing what, and how big it was.
  String get summary {
    final size = rssKb > 0 ? ', ${(rssKb / 1024).round()} MB in memory' : '';
    final how = description.isEmpty ? '' : ' ($description)';
    return 'The app ended: $reasonName, while $importanceName$size, status $status$how';
  }

  /// A stack of one made-up frame named after the reason, so Crashlytics gathers the same kind of ending in one issue
  /// (it groups by stack, and a real stack would make every report its own issue).
  StackTrace get stack => StackTrace.fromString('#0      PreviousExit.$reasonName (previous_exit.dart:1:1)\n');
}

/// The part of [PreviousExit] that decides what to send, kept apart so it is tested without a phone.
class PreviousExits {
  PreviousExits._();

  /// The entries newer than [seenUpTo] (ms) that are worth a report, oldest first.
  static List<PreviousExit> toReport(Iterable<PreviousExit> all, {required int seenUpTo}) {
    final list = all.where((e) => e.timestamp > seenUpTo && e.worthReporting).toList()..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return list;
  }

  /// The newest timestamp among [all] (or [seenUpTo] when there is none): everything up to it has been looked at.
  static int newestSeen(Iterable<PreviousExit> all, {required int seenUpTo}) {
    var newest = seenUpTo;
    for (final e in all) {
      if (e.timestamp > newest) newest = e.timestamp;
    }
    return newest;
  }
}

/// Crash and freeze reports (Firebase Crashlytics), Android only for now.
///
/// What a report carries: the crash or freeze with its stack (native code too), the last lines passed to [log], the memory of
/// the app every 30 seconds ([startMemoryTrail]), and the visible app ID of the signed-in person ([setUser]) so a report can be
/// matched to the person who sent it. Why the app's last process ended is added on the next start ([reportPreviousExits]): a
/// phone killing the app for memory leaves no crash at all, only that record.
///
/// Every call is safe to make when reporting is off (iPhone, tests, a phone without Firebase): it does nothing.
class CrashReporting {
  CrashReporting._();

  static const MethodChannel _channel = MethodChannel('com.sabalive.in/exit_info');
  static const _seenKey = 'crash.exit.seen_up_to';
  static const _trailEvery = Duration(seconds: 30);

  static bool _on = false;
  static Timer? _trail;

  /// Reports are being sent.
  static bool get isOn => _on;

  /// Call from main() once Firebase is initialised ([firebaseReady]); never throws.
  static Future<void> start({required bool firebaseReady}) async {
    if (defaultTargetPlatform != TargetPlatform.android || !firebaseReady) return;
    try {
      final crashlytics = FirebaseCrashlytics.instance;
      await crashlytics.setCrashlyticsCollectionEnabled(!kDebugMode);
      // a framework error or an uncaught async error does not close the app in a release build, so it is sent as a non-fatal; the
      // default handling (printing) stays as it was
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        previous?.call(details);
        unawaited(crashlytics.recordFlutterError(details));
      };
      final previousAsync = PlatformDispatcher.instance.onError;
      PlatformDispatcher.instance.onError = (error, stack) {
        unawaited(crashlytics.recordError(error, stack));
        return previousAsync?.call(error, stack) ?? false;
      };
      _on = !kDebugMode;
    } catch (e) {
      debugPrint('Crash reporting could not start: $e');
    }
  }

  /// A line kept with the report, most recent last (Crashlytics keeps about 64 KB of them).
  static void log(String message) {
    if (!_on) return;
    try {
      unawaited(FirebaseCrashlytics.instance.log(message));
    } catch (_) {}
  }

  /// A value shown on every report from now on (the room, the screen, the memory).
  static void key(String name, Object value) {
    if (!_on) return;
    try {
      unawaited(FirebaseCrashlytics.instance.setCustomKey(name, value));
    } catch (_) {}
  }

  /// The person's visible app ID (the number on their profile), or null when signed out. Never a name, email or phone.
  static void setUser(String? displayId) {
    if (!_on) return;
    try {
      unawaited(FirebaseCrashlytics.instance.setUserIdentifier(displayId ?? ''));
    } catch (_) {}
  }

  /// Every 30 seconds: how big the app is, the decoded gift pictures, the picture cache. A crash report then shows the trend
  /// that led up to it. A line costs nothing worth measuring.
  static void startMemoryTrail() {
    if (!_on || _trail != null) return;
    _trail = Timer.periodic(_trailEvery, (_) {
      try {
        final rss = (ProcessInfo.currentRss / (1024 * 1024)).round();
        final gifts = (GiftMovieCache.instance.bytes / (1024 * 1024)).round();
        final images = ((PaintingBinding.instance.imageCache.currentSizeBytes) / (1024 * 1024)).round();
        key('rss_mb', rss);
        log('memory: app $rss MB, gift animations $gifts MB, pictures $images MB');
      } catch (_) {}
    });
  }

  /// Asks Android how the app's earlier processes ended and reports the ones that matter, once each. Android 11 and newer;
  /// on an older phone the native side answers with nothing. Never throws.
  static Future<void> reportPreviousExits() async {
    if (!_on) return;
    try {
      final raw = await _channel.invokeListMethod<Map<Object?, Object?>>('recent') ?? const [];
      final all = [for (final m in raw) PreviousExit.fromMap(m)];
      final prefs = await SharedPreferences.getInstance();
      final seenUpTo = prefs.getInt(_seenKey) ?? 0;
      for (final e in PreviousExits.toReport(all, seenUpTo: seenUpTo)) {
        await FirebaseCrashlytics.instance.recordError(
          PreviousExitError(e.summary),
          e.stack,
          reason: 'previous exit',
          information: [
            'at ${DateTime.fromMillisecondsSinceEpoch(e.timestamp).toUtc().toIso8601String()}',
            e.summary,
          ],
        );
      }
      await prefs.setInt(_seenKey, PreviousExits.newestSeen(all, seenUpTo: seenUpTo));
    } catch (e) {
      debugPrint('Could not read the earlier exits: $e');
    }
  }
}

/// What a report of an earlier ending is called in Crashlytics.
class PreviousExitError implements Exception {
  const PreviousExitError(this.message);
  final String message;

  @override
  String toString() => message;
}
