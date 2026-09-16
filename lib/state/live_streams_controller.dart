import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';
import '../data/models.dart';

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
          callback: (_) => _load(),
        )
        .subscribe();
  }

  List<LiveStream> _streams = const [];
  bool _loading = true;
  RealtimeChannel? _channel;

  List<LiveStream> get streams => List.unmodifiable(_streams);
  bool get loading => _loading;

  Future<void> refresh() => _load();

  Future<void> _load() async {
    final rows = await supabase
        .from('live_streams')
        .select('*, profiles!live_streams_host_id_fkey(*)')
        .eq('status', 'live')
        .order('started_at', ascending: false);
    _streams = [
      for (final row in rows)
        LiveStream.fromRow(row, AppUser.fromRow(row['profiles'] as Map<String, dynamic>)),
    ];
    _loading = false;
    notifyListeners();
  }

  Future<LiveStream> createStream({required String title, required String category}) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw Exception('You must be signed in to go live');

    final row = await supabase
        .from('live_streams')
        .insert({'host_id': uid, 'title': title, 'category': category})
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
      'ended_at': DateTime.now().toIso8601String(),
    }).eq('id', id);
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }
}
