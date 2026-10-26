import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';
import '../core/utils/coalesced_runner.dart';
import '../core/utils/errors.dart';
import '../data/games_repository.dart';
import 'remote_config_controller.dart';

/// Starts listening for changes and returns the function that stops listening.
typedef GamesChangeFeed = void Function() Function(void Function() onChange);

/// The platform's game list, kept in step with the Tulasi panel: when someone presses "Sync Game List" there, the platform pushes
/// the list to our Edge Function, which writes `merchant_games`; this store hears that over Realtime and reloads, so every screen
/// that shows games (the Games tab, the Home strip, the in-room Games menu) changes at once, with no restart.
/// It also listens to `app_config`, so the panel's "Games" switch flips the app immediately, and reloads on return to the app.
class GamesStore extends ChangeNotifier with WidgetsBindingObserver {
  GamesStore({GamesRepository? repo, GamesChangeFeed? feed, Duration window = const Duration(milliseconds: 500), bool Function()? sudEnabled})
      : _repo = repo ?? GamesRepository(),
        _feed = feed ?? _supabaseFeed,
        _sudEnabled = sudEnabled ?? _sudSwitch {
    _runner = CoalescedRunner(() {
      if (_started) unawaited(refresh()); // an event that was already on its way when we stopped does nothing
    }, window: window);
  }

  /// The one the app's screens share.
  static final GamesStore instance = GamesStore();

  final GamesRepository _repo;
  final GamesChangeFeed _feed;
  final bool Function() _sudEnabled;

  /// The panel's "SUD games" switch (Release controls): off = the SUD games are not shown at all, whatever the list holds.
  static bool _sudSwitch() => RemoteConfigController.instance.flag('sud_games_enabled', defaultValue: false);
  late final CoalescedRunner _runner;

  List<MerchantGame>? _games;
  String? _error;
  bool _started = false;
  bool _loading = false;
  void Function()? _stopFeed;

  /// The enabled games (SUD's only while its switch is on), null until the first load finishes.
  List<MerchantGame>? get games {
    final all = _games;
    if (all == null) return null;
    return _sudEnabled() ? all : [for (final g in all) if (!g.isSud) g];
  }
  String? get error => _error;
  bool get started => _started;

  /// Begins listening and loads the list. Safe to call again.
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    try {
      _stopFeed = _feed(_runner.trigger);
    } catch (_) {
      // Realtime is a bonus: the list still loads, and reloads on return to the app
    }
    unawaited(refresh());
  }

  /// Reads the list again (the screens' "try again", a Realtime change, coming back to the app).
  Future<void> refresh() async {
    if (_loading) {
      _runner.trigger(); // a change arrived while one was loading: look once more
      return;
    }
    _loading = true;
    try {
      final g = await _repo.games();
      _games = g;
      _error = null;
    } catch (e) {
      _error = friendlyError(e);
    } finally {
      _loading = false;
    }
    notifyListeners();
  }

  void stop() {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    _runner.cancel();
    _stopFeed?.call();
    _stopFeed = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _started) unawaited(refresh());
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  static void Function() _supabaseFeed(void Function() onChange) {
    final channel = supabase
        .channel('merchant-games')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'merchant_games',
          callback: (_) => onChange(),
        )
        // the panel's Games switch lives in app_config: read it again now rather than at the next launch
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'app_config',
          callback: (_) => unawaited(RemoteConfigController.instance.refresh(force: true)),
        )
        .subscribe();
    // SUD's list has its OWN channel: if the table is not published yet (an older database) only this one fails, never Tulasi's list or the switch above
    final sud = supabase
        .channel('sud-games')
        .onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'sud_games', callback: (_) => onChange())
        .subscribe();
    return () {
      unawaited(channel.unsubscribe());
      unawaited(sud.unsubscribe());
    };
  }
}
