import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/system_status_repository.dart';

/// The app's view of maintenance mode.
///
/// It reads the status at launch, whenever the app comes back from the
/// background, every [pollEvery] while open, and the moment the server changes
/// it (Realtime) or refuses a request with MAINTENANCE_MODE. All of those, so
/// that no single one failing can leave someone looking at a stale answer.
///
/// The countdown is worked out from the SERVER's clock: each reading notes how far
/// the phone's clock is from the server's, and [serverNow] applies that.
class MaintenanceController extends ChangeNotifier with WidgetsBindingObserver {
  MaintenanceController({
    SystemStatusRepository? repo,
    DateTime Function()? clock,
    this.pollEvery = const Duration(seconds: 30),
  }) : _repo = repo ?? SystemStatusRepository(),
       _clock = clock ?? DateTime.now;

  /// The one the running app uses (also reachable from the HTTP client, which has
  /// no BuildContext).
  static final MaintenanceController instance = MaintenanceController();

  final SystemStatusRepository _repo;
  final DateTime Function() _clock;
  final Duration pollEvery;

  SystemStatus _status = SystemStatus.online;
  Duration _offset = Duration.zero;
  Timer? _poll;
  RealtimeChannel? _channel;
  bool _started = false;
  bool _disposed = false;

  SystemStatus get status => _status;

  /// The whole app is closed right now.
  bool get locked => _status.locksApp;

  /// Signing in / up is closed right now.
  bool get loginsBlocked => _status.blocksLogins;

  /// The server's idea of now.
  DateTime serverNow() => _clock().toUtc().add(_offset);

  /// Time to go before maintenance is expected to end, or null if no end time is
  /// set (or it is a lockdown). Zero once the time has passed.
  Duration? remaining() {
    final end = _status.endsAt;
    if (end == null || _status.isLockdown) return null;
    final left = end.difference(serverNow());
    return left.isNegative ? Duration.zero : left;
  }

  /// Time until a scheduled maintenance begins, or null.
  Duration? untilStart() {
    final start = _status.startsAt;
    if (_status.status != 'upcoming' || start == null) return null;
    final left = start.difference(serverNow());
    return left.isNegative ? Duration.zero : left;
  }

  /// The end time has passed but maintenance is still on.
  bool get overdue {
    final end = _status.endsAt;
    return _status.status == 'maintenance' &&
        end != null &&
        !serverNow().isBefore(end);
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _poll = Timer.periodic(pollEvery, (_) => refresh());
    try {
      _channel = _repo.watch(() => unawaited(refresh()));
    } catch (_) {
      // Realtime is the quick path, not the only one: polling still runs
    }
    await refresh();
  }

  /// Re-reads the status. If the server can't be reached the last known status
  /// stays — a phone that goes offline during maintenance is still in maintenance.
  Future<void> refresh() async {
    try {
      final fresh = await _repo.fetch();
      apply(fresh);
    } catch (_) {}
  }

  /// Takes a status as the truth (from a read, or from a refused request).
  void apply(SystemStatus next) {
    if (_disposed) return;
    // a status that carries no server time (the empty default) says nothing about the clock
    if (next.serverTime.year > 2000) {
      _offset = next.serverTime.difference(_clock().toUtc());
    }
    final changed = !_same(next, _status);
    _status = next;
    if (changed) notifyListeners();
  }

  /// A request came back 503 MAINTENANCE_MODE: lock now, then confirm.
  void reportRefused(Map<dynamic, dynamic> details) {
    apply(SystemStatus.fromGateDetails(details));
    unawaited(refresh());
  }

  static bool _same(SystemStatus a, SystemStatus b) =>
      a.status == b.status &&
      a.title == b.title &&
      a.message == b.message &&
      a.imageUrl == b.imageUrl &&
      a.startsAt == b.startsAt &&
      a.endsAt == b.endsAt &&
      a.lockApp == b.lockApp &&
      a.blockLogins == b.blockLogins &&
      a.appSessionVersion == b.appSessionVersion;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _channel?.unsubscribe();
    if (_started) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// `01:02:03` (hours, minutes, seconds), never negative.
String formatCountdown(Duration d) {
  final total = d.isNegative ? 0 : d.inSeconds;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(total ~/ 3600)}:${two((total % 3600) ~/ 60)}:${two(total % 60)}';
}

/// "6:30 AM", or "4 Oct, 6:30 AM" when it isn't today ([now] is the user's local
/// time).
String formatExpectedCompletion(DateTime end, DateTime now) {
  final local = end.toLocal();
  final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final m = local.minute.toString().padLeft(2, '0');
  final clock = '$h:$m ${local.hour < 12 ? 'AM' : 'PM'}';
  final today = now.toLocal();
  if (local.year == today.year && local.month == today.month && local.day == today.day) {
    return clock;
  }
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${local.day} ${months[local.month - 1]}, $clock';
}
