import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../../config/supabase_client.dart';
import '../../../data/models.dart';

/// Who is on which seat right now, as the database has it.
///
/// Realtime tells a room about seat changes as they happen, but it does not replay
/// anything a phone missed — a dropped connection, the app in the background, a
/// listener that started a moment too late — and older app builds never receive seat
/// removals at all. So the rooms re-read this on a timer (and when the app returns to
/// the foreground or Realtime reconnects) and make their screen match it, which keeps a
/// stuck "seat in use", a missing host or a missing guest from lasting more than a few
/// seconds.
class SeatSnapshot {
  SeatSnapshot({
    required this.occupants,
    required this.muted,
    required this.agoraUids,
    this.locked,
    this.seatCount,
    this.hostAgoraUid,
    this.seatRequests,
  });

  final Map<int, AppUser> occupants;
  final Set<int> muted;

  /// seat -> the occupant's Agora uid (when they've published it)
  final Map<int, int?> agoraUids;
  final Set<int>? locked;
  final int? seatCount;
  final int? hostAgoraUid;

  /// The host asks before someone sits (migration 20261019100000). Null when the server does not have the setting yet.
  final bool? seatRequests;

  /// The seat [userId] is on, if any.
  int? seatOf(String? userId) {
    if (userId == null) return null;
    for (final e in occupants.entries) {
      if (e.value.id == userId) return e.key;
    }
    return null;
  }
}

/// Whether the server has the `live_streams.seat_requests` column (migration 20261019100000). Learned on the first read: a server
/// without it answers that one with an error, and from then on the app does not ask for the column again.
bool _seatRequestsColumn = true;

const _streamColumns = 'locked_seats, seat_count, host_agora_uid';

Future<Map<String, dynamic>?> _readStreamRow(String streamId) async {
  if (_seatRequestsColumn) {
    try {
      return await supabase
          .from('live_streams')
          .select('$_streamColumns, seat_requests')
          .eq('id', streamId)
          .maybeSingle();
    } on PostgrestException catch (e) {
      // "column live_streams.seat_requests does not exist": an older server. Anything else is a real failure.
      if (e.code != '42703' && !e.message.contains('seat_requests')) rethrow;
      _seatRequestsColumn = false;
    }
  }
  return await supabase.from('live_streams').select(_streamColumns).eq('id', streamId).maybeSingle();
}

/// Null when it could not be read (offline, etc.) — callers just keep what they have.
Future<SeatSnapshot?> fetchSeatSnapshot(String streamId) async {
  try {
    final rows = await supabase
        .from('live_stream_seats')
        .select(
          'seat_number, is_muted, agora_uid, profiles!live_stream_seats_occupant_id_fkey(*)',
        )
        .eq('live_stream_id', streamId);
    final stream = await _readStreamRow(streamId);
    final occupants = <int, AppUser>{};
    final muted = <int>{};
    final uids = <int, int?>{};
    for (final r in rows as List) {
      final profile = r['profiles'] as Map<String, dynamic>?;
      if (profile == null) continue;
      final seat = r['seat_number'] as int;
      occupants[seat] = AppUser.fromRow(profile);
      if (r['is_muted'] as bool? ?? false) muted.add(seat);
      uids[seat] = r['agora_uid'] as int?;
    }
    final locked = stream?['locked_seats'] as List?;
    return SeatSnapshot(
      occupants: occupants,
      muted: muted,
      agoraUids: uids,
      locked: locked?.cast<int>().toSet(),
      seatCount: stream?['seat_count'] as int?,
      hostAgoraUid: stream?['host_agora_uid'] as int?,
      seatRequests: stream?['seat_requests'] as bool?,
    );
  } catch (e) {
    debugPrint('seat snapshot failed: $e');
    return null;
  }
}
