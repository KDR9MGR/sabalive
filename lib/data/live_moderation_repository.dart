import '../config/supabase_client.dart';

/// The live-room moderation calls. Everything is decided on the server (`is_room_moderator`): the host and the host's
/// room admins may use these on anyone except the host, and an admin may not act on another admin.
class LiveModerationRepository {
  /// Removes [userId] from the live right now. They can come back in.
  Future<void> kick(String streamId, String userId) =>
      _rpc('kick_viewer', {'p_stream_id': streamId, 'p_user_id': userId});

  /// Removes [userId] and keeps them out of this live (`block_viewer`).
  Future<void> ban(String streamId, String userId) =>
      _rpc('block_viewer', {'p_stream_id': streamId, 'p_user_id': userId});

  /// Turns [userId]'s chat off (or back on) for this live. They stay in the room.
  Future<void> setChatOff(String streamId, String userId, bool off) =>
      _rpc('mute_chat', {'p_stream_id': streamId, 'p_user_id': userId, 'p_on': off});

  /// The host makes [userId] a room admin (or removes them): up to 5, for every live of that host.
  Future<void> setAdmin(String userId, bool on) => _rpc('set_room_admin', {'p_admin': userId, 'p_on': on});

  Future<void> muteSeat(String streamId, int seat, bool muted) =>
      _rpc('host_set_seat_mute', {'p_stream_id': streamId, 'p_seat': seat, 'p_muted': muted});

  Future<void> removeFromSeat(String streamId, int seat) =>
      _rpc('kick_seat_occupant', {'p_stream_id': streamId, 'p_seat': seat});

  /// Who the host's room admins are.
  Future<Set<String>> adminsOf(String hostId) async {
    final rows = await supabase.from('live_room_admins').select('admin_id').eq('host_id', hostId);
    return {for (final r in rows) r['admin_id'] as String};
  }

  /// Whose chat is off in this live. A moderator sees everyone; anyone else only sees themself.
  Future<Set<String>> chatOffIn(String streamId) async {
    final rows = await supabase.from('live_chat_mutes').select('user_id').eq('live_stream_id', streamId);
    return {for (final r in rows) r['user_id'] as String};
  }

  Future<void> _rpc(String name, Map<String, dynamic> params) async {
    await supabase.rpc(name, params: params);
  }
}
