import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';

/// One change of a live's shared heart total, as the server announces it: the new sum of everybody's hearts, who added the last batch and how many.
class HeartsEvent {
  const HeartsEvent({required this.total, this.by, this.count = 0});

  factory HeartsEvent.fromRow(Map<String, dynamic> r) => HeartsEvent(
        total: (r['total'] as num?)?.toInt() ?? 0,
        by: r['last_by'] as String?,
        count: (r['last_count'] as num?)?.toInt() ?? 0,
      );

  final int total;
  final String? by;
  final int count;
}

/// What the room's hearts need from the server (the real one below; a fake in tests).
abstract class LiveHeartsApi {
  /// The sum of everybody's hearts in this live so far (0 when there are none or it cannot be read).
  Future<int> total(String streamId);

  /// Adds [count] hearts tapped by this person and returns the new total, or null when it failed (the phone keeps the taps and sends them with the next batch).
  Future<int?> add(String streamId, int count);

  /// Changes of THIS live's total, filtered to it: the one Realtime watch a room opens for hearts (never subscribe to every live).
  Stream<HeartsEvent> watch(String streamId);
}

class SupabaseLiveHeartsApi implements LiveHeartsApi {
  const SupabaseLiveHeartsApi();

  @override
  Future<int> total(String streamId) async {
    try {
      final row = await supabase.from('live_hearts').select('total').eq('live_stream_id', streamId).maybeSingle();
      return (row?['total'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0; // a database without the table: no shared hearts, nothing breaks
    }
  }

  @override
  Future<int?> add(String streamId, int count) async {
    try {
      final r = await supabase.rpc('add_live_hearts', params: {'p_stream_id': streamId, 'p_count': count});
      return (r as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<HeartsEvent> watch(String streamId) {
    RealtimeChannel? channel;
    late final StreamController<HeartsEvent> out;
    out = StreamController<HeartsEvent>(
      onListen: () {
        try {
          channel = supabase
              .channel('live-hearts-$streamId')
              .onPostgresChanges(
                event: PostgresChangeEvent.all,
                schema: 'public',
                table: 'live_hearts',
                filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'live_stream_id', value: streamId),
                callback: (p) {
                  try {
                    if (!out.isClosed) out.add(HeartsEvent.fromRow(p.newRecord));
                  } catch (_) {}
                },
              )
              .subscribe();
        } catch (_) {}
      },
      onCancel: () {
        final c = channel;
        channel = null;
        if (c != null) {
          try {
            unawaited(supabase.removeChannel(c));
          } catch (_) {}
        }
      },
    );
    return out.stream;
  }
}
