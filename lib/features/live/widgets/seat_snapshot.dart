import 'package:flutter/foundation.dart';

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
  });

  final Map<int, AppUser> occupants;
  final Set<int> muted;

  /// seat -> the occupant's Agora uid (when they've published it)
  final Map<int, int?> agoraUids;
  final Set<int>? locked;
  final int? seatCount;
  final int? hostAgoraUid;

  /// The seat [userId] is on, if any.
  int? seatOf(String? userId) {
    if (userId == null) return null;
    for (final e in occupants.entries) {
      if (e.value.id == userId) return e.key;
    }
    return null;
  }
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
    final stream = await supabase
        .from('live_streams')
        .select('locked_seats, seat_count, host_agora_uid')
        .eq('id', streamId)
        .maybeSingle();
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
    );
  } catch (e) {
    debugPrint('seat snapshot failed: $e');
    return null;
  }
}
