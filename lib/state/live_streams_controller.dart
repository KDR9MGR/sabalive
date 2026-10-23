import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/feature_flags.dart';
import '../config/supabase_client.dart';
import '../core/utils/throttled_runner.dart';
import '../data/models.dart';
import 'blocks_controller.dart';

/// Real live streams — a thin layer over the `live_streams` table. This is
/// deliberately additive to (not a replacement for) the app's demo/mock
/// content: it only ever surfaces streams someone actually started for real.
///
/// COST CONTROL. Every heartbeat, join, leave, like and gift changes a live_streams row, and Realtime sends that row to EVERY phone listening to the
/// table. So this controller
///  - reloads at most once every [reloadGap] however many events arrive (it used to reload up to 40 times a minute on a busy evening: a full download,
///    a JSON parse and a Home rebuild each time),
///  - listens only while the list can be seen: not while the app is in the background and not while a live is open full-screen ([setInLiveRoom]),
///    and reads once, fresh, when it starts listening again.
/// Nothing is lost: the list is the same, at most [reloadGap] behind during a burst, and exact the moment the user comes back to it.
class LiveStreamsController extends ChangeNotifier with WidgetsBindingObserver {
  LiveStreamsController({
    this.reloadGap = const Duration(seconds: 8),
    @visibleForTesting Future<List<LiveStream>> Function()? fetch,
    @visibleForTesting Future<void> Function() Function(void Function() onChange)? listen,
    @visibleForTesting BlocksController? blocks,
  })  : _fetch = fetch ?? _fetchFromServer,
        _listen = listen ?? _listenToServer,
        _blocks = blocks ?? BlocksController.instance {
    _reload = ThrottledRunner(_load, minGap: reloadGap);
    WidgetsBinding.instance.addObserver(this);
    _load();
    _start();
    // blocking or unblocking someone changes whose lives are shown
    _blocks.addListener(notifyListeners);
  }

  /// The most often the list is re-read because of Realtime events.
  final Duration reloadGap;
  final Future<List<LiveStream>> Function() _fetch;
  final Future<void> Function() Function(void Function() onChange) _listen;
  final BlocksController _blocks;

  late final ThrottledRunner _reload;
  List<LiveStream> _streams = const [];
  bool _loading = true;
  Future<void> Function()? _stopListening;
  bool _inBackground = false;
  bool _inLiveRoom = false;
  bool _disposed = false;

  /// Live now, minus lives hosted by someone the user has blocked — the most
  /// watched first (ties: the one that went live most recently).
  List<LiveStream> get streams {
    final list = _blocks.withoutBlocked(_streams, (s) => s.host.id).toList();
    list.sort((a, b) {
      final byViews = b.viewers.compareTo(a.viewers);
      if (byViews != 0) return byViews;
      final aStart = a.startedAt, bStart = b.startedAt;
      if (aStart == null || bStart == null) return 0;
      return bStart.compareTo(aStart);
    });
    return List.unmodifiable(list);
  }

  bool get loading => _loading;

  /// Is the controller listening to Realtime right now?
  bool get listening => _stopListening != null;

  Future<void> refresh() => _load();

  /// A live is open full-screen over the app (not minimized): the list is not on screen, so stop listening. When it closes or is minimized the list
  /// is read once, fresh, and listening starts again.
  void setInLiveRoom(bool inRoom) {
    if (inRoom == _inLiveRoom) return;
    _inLiveRoom = inRoom;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final background = state == AppLifecycleState.paused || state == AppLifecycleState.detached || state == AppLifecycleState.hidden;
    if (background == _inBackground) return;
    _inBackground = background;
    _sync();
  }

  void _sync() {
    if (_disposed) return;
    final wantListening = !_inBackground && !_inLiveRoom;
    if (wantListening && _stopListening == null) {
      _start();
      _reload.runNow(); // whatever changed while we were not listening
    } else if (!wantListening && _stopListening != null) {
      _stop();
    }
  }

  void _start() => _stopListening ??= _listen(_reload.trigger);

  void _stop() {
    final stop = _stopListening;
    _stopListening = null;
    _reload.cancel();
    if (stop != null) unawaited(stop());
  }

  static Future<void> Function() _listenToServer(void Function() onChange) {
    final channel = supabase
        .channel('public:live_streams:list')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'live_streams',
          callback: (_) => onChange(),
        )
        .subscribe();
    return () async {
      await supabase.removeChannel(channel);
    };
  }

  static Future<List<LiveStream>> _fetchFromServer() async {
    final rows = await supabase
        .from('live_streams')
        .select('*, profiles!live_streams_host_id_fkey(*)')
        .eq('status', 'live')
        .order('viewer_count', ascending: false)
        .order('started_at', ascending: false);
    final streams = [
      for (final row in rows)
        LiveStream.fromRow(row, AppUser.fromRow(row['profiles'] as Map<String, dynamic>)),
    ];
    await _markBattles(streams);
    return streams;
  }

  Future<void> _load() async {
    try {
      final streams = await _fetch();
      if (_disposed) return;
      _streams = streams;
    } catch (_) {
      // keep the list we have (and the spinner, if there was never one); the next event, a refresh or coming back reads again
      return;
    }
    if (_disposed) return;
    _loading = false;
    notifyListeners();
  }

  /// Lives that are in a PK battle right now show under the PK filter. One small query per reload, and none while PK is off.
  static Future<void> _markBattles(List<LiveStream> streams) async {
    if (!FeatureFlags.pkBattleEnabled) return;
    try {
      final rows = await supabase.from('pk_battles').select('stream_a_id, stream_b_id').eq('status', 'live');
      final ids = <String>{for (final r in rows) ...[r['stream_a_id'] as String, r['stream_b_id'] as String]};
      for (final s in streams) {
        s.inBattle = ids.contains(s.id);
      }
    } catch (_) {
      // the filter just misses the battles this time
    }
  }

  Future<LiveStream> createStream({
    required String title,
    required String category,
    required LiveMode mode,
  }) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw Exception('You must be signed in to go live');

    final row = await supabase
        .from('live_streams')
        .insert({
          'host_id': uid,
          'title': title,
          'category': category,
          'mode': mode.name,
          // an audio room opens with two full rows of 4 seats (the host can go from 4 to 16); 8 is valid on every
          // database, old or updated. Video lives keep the default.
          if (mode == LiveMode.audio) 'seat_count': 8,
        })
        .select()
        .single();
    final profileRow = await supabase.from('profiles').select().eq('id', uid).single();
    return LiveStream.fromRow(row, AppUser.fromRow(profileRow));
  }

  /// Keeps a stream from being auto-ended by `end_stale_live_streams` —
  /// call every ~30s while actually broadcasting. A host that force-quits
  /// or loses connection stops sending these, so the stream gets cleaned up
  /// within ~90s instead of sitting at status='live' forever.
  Future<void> heartbeat(String id) async {
    try {
      await supabase.rpc('heartbeat_stream', params: {'p_stream_id': id});
    } catch (_) {/* best-effort; a missed beat or two is fine */}
  }

  Future<void> endStream(String id) async {
    await supabase.from('live_streams').update({
      'status': 'ended',
      'ended_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', id);
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    _blocks.removeListener(notifyListeners);
    super.dispose();
  }
}
