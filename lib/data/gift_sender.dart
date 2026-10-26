import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';
import '../core/utils/ids.dart';
import 'models.dart';

/// Calls a database function: name and named parameters, like `supabase.rpc`.
typedef RpcCall = Future<dynamic> Function(String function, Map<String, dynamic> params);

/// The database has no function with that name (yet): PostgREST code PGRST202 / Postgres 42883.
bool isMissingFunction(Object e) {
  if (e is PostgrestException) {
    return e.code == 'PGRST202' || e.code == '42883' || e.message.contains('Could not find the function');
  }
  return false;
}

/// Sends gifts through the database. A gift with a QUANTITY is ONE action (`send_gift_v2` / `send_gift_to_all_v2`): charged up front, ONE chat line
/// ("sent Alice 10x Rose", "sent 10x Rose to 5 people"), and the chat row records how many and who received it. The old functions (`send_gift`,
/// `send_gift_to_all`) stay for a database that does not have the new ones yet, and for old apps: against such a database a quantity of 10 falls back
/// to ten calls (ten chat lines), so nothing breaks while the new database update is on its way.
class GiftSender {
  GiftSender({RpcCall? rpc, String? Function()? currentUserId})
      : _rpc = rpc ?? ((fn, params) => supabase.rpc(fn, params: params)),
        _currentUserId = currentUserId ?? (() => supabase.auth.currentUser?.id);

  final RpcCall _rpc;
  final String? Function() _currentUserId;

  /// Gift [gift] x [quantity] to [receiver]. A demo host (mock data) is refused with a clear message.
  Future<void> send(Gift gift, AppUser receiver, {String? liveStreamId, int quantity = 1}) async {
    if (!isRealId(receiver.id)) {
      throw Exception("${receiver.name} is a demo host — gifts can't be sent yet.");
    }
    try {
      await _rpc('send_gift_v2', {
        'p_gift_id': gift.id,
        'p_receiver_id': receiver.id,
        'p_live_stream_id': liveStreamId,
        'p_quantity': quantity,
      });
      return;
    } catch (e) {
      if (!isMissingFunction(e)) rethrow;
    }
    for (var i = 0; i < quantity; i++) {
      await _rpc('send_gift', {'p_gift_id': gift.id, 'p_receiver_id': receiver.id, 'p_live_stream_id': liveStreamId});
    }
  }

  /// Gift [gift] x [quantity] to everyone in the room (the host and whoever is on a seat, the SENDER INCLUDED when they are one of them). Returns how many people got it.
  /// `send_gift_to_all_v3` includes the sender; against a database that does not have it yet this falls back to `send_gift_to_all_v2` (the sender is left out), then to
  /// the old Send to All once per unit, and without that to one gift per person.
  Future<int> sendToAll(
    Gift gift, {
    required String liveStreamId,
    int quantity = 1,
    required List<AppUser> fallbackRecipients,
  }) async {
    try {
      final n = await _rpc('send_gift_to_all_v3', {
        'p_gift_id': gift.id,
        'p_live_stream_id': liveStreamId,
        'p_quantity': quantity,
      });
      return (n as num?)?.toInt() ?? 0;
    } catch (e) {
      if (!isMissingFunction(e)) rethrow;
    }
    try {
      final n = await _rpc('send_gift_to_all_v2', {
        'p_gift_id': gift.id,
        'p_live_stream_id': liveStreamId,
        'p_quantity': quantity,
      });
      return (n as num?)?.toInt() ?? 0;
    } catch (e) {
      if (!isMissingFunction(e)) rethrow;
    }
    try {
      var n = 0;
      for (var i = 0; i < quantity; i++) {
        final r = await _rpc('send_gift_to_all', {'p_gift_id': gift.id, 'p_live_stream_id': liveStreamId});
        n = (r as num?)?.toInt() ?? n;
      }
      return n;
    } catch (e) {
      if (!isMissingFunction(e)) rethrow;
    }
    final me = _currentUserId();
    var sent = 0;
    for (final r in fallbackRecipients) {
      if (r.id == me) continue;
      for (var i = 0; i < quantity; i++) {
        await _rpc('send_gift', {'p_gift_id': gift.id, 'p_receiver_id': r.id, 'p_live_stream_id': liveStreamId});
      }
      sent++;
    }
    return sent;
  }
}
