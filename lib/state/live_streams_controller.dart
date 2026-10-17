import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/feature_flags.dart';
import '../config/supabase_client.dart';
import '../core/utils/coalesced_runner.dart';
import '../data/models.dart';
import 'blocks_controller.dart';

/// Real live streams — a thin layer over the `live_streams` table. This is
/// deliberately additive to (not a replacement for) the app's demo/mock
/// content: it only ever surfaces streams someone actually started for real.
class LiveStreamsController extends ChangeNotifier {
  LiveStreamsController() {
    _load();
    _channel = supabase
        .channel('public:live_streams:list')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'live_streams',
          // Every heartbeat and every viewer join/leave changes a live_streams row; reloading
          // the whole list (and rebuilding Home) for each one is what made busy evenings
          // heavy on every phone. One reload per burst is enough.
          callback: (_) => _reload.trigger(),
        )
        .subscribe();
    // blocking or unblocking someone changes whose lives are shown
    BlocksController.instance.addListener(notifyListeners);
  }

  late final _reload = CoalescedRunner(_load);
  List<LiveStream> _streams = const [];
  bool _loading = true;
  RealtimeChannel? _channel;

  /// Live now, minus lives hosted by someone the user has blocked — the most
  /// watched first (ties: the one that went live most recently).
  List<LiveStream> get streams {
    final list = BlocksController.instance
        .withoutBlocked(_streams, (s) => s.host.id)
        .toList();
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

  Future<void> refresh() => _load();

  Future<void> _load() async {
    final rows = await supabase
        .from('live_streams')
        .select('*, profiles!live_streams_host_id_fkey(*)')
        .eq('status', 'live')
        .order('viewer_count', ascending: false)
        .order('started_at', ascending: false);
    _streams = [
      for (final row in rows)
        LiveStream.fromRow(row, AppUser.fromRow(row['profiles'] as Map<String, dynamic>)),
    ];
    await _markBattles();
    _loading = false;
    notifyListeners();
  }

  /// Lives that are in a PK battle right now show under the PK filter. One small query per reload, and none while PK is off.
  Future<void> _markBattles() async {
    if (!FeatureFlags.pkBattleEnabled) return;
    try {
      final rows = await supabase.from('pk_battles').select('stream_a_id, stream_b_id').eq('status', 'live');
      final ids = <String>{for (final r in rows) ...[r['stream_a_id'] as String, r['stream_b_id'] as String]};
      for (final s in _streams) {
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
    _reload.cancel();
    _channel?.unsubscribe();
    BlocksController.instance.removeListener(notifyListeners);
    super.dispose();
  }
}
