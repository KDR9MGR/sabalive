import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../../config/supabase_client.dart';
import '../../../data/store_repository.dart';
import 'room_effect.dart';

/// Reads the last few seconds of a room's chat and lets [effects] play THIS user's own join row.
///
/// Realtime never replays what happened before a screen was listening, and the join row (which carries the
/// entry effect) is written by the server the moment the user joins, so it can land in the gap before the
/// room's channel is subscribed. Calling this once the channel reports SUBSCRIBED closes that gap. Rows seen
/// twice are played once (the controller remembers row ids). Never throws.
Future<void> catchUpOwnEntry(
  String streamId,
  RoomEffectController effects, {
  required String? meId,
  StoreRepository? repo,
}) async {
  try {
    final rows = await supabase
        .from('live_chat_messages')
        .select()
        .eq('live_stream_id', streamId)
        .gte(
          'created_at',
          DateTime.now().toUtc().subtract(const Duration(seconds: 20)).toIso8601String(),
        )
        .order('created_at', ascending: false)
        .limit(30);
    final store = repo ?? StoreRepository();
    for (final row in rows.reversed) {
      unawaited(
        effects.handleRow(
          row,
          meId: meId,
          senderName: 'You',
          giftById: (_) => null,
          loadItems: store.itemsByIds,
          history: true,
        ),
      );
    }
  } catch (e) {
    debugPrint('entry catch-up failed: $e');
  }
}

/// Plays this user's own vehicle / entry effect right away, from what they have equipped, instead of waiting
/// for their join row to come back over Realtime. Never throws.
Future<void> playMyEntry(
  RoomEffectController effects, {
  required String? meId,
  StoreRepository? repo,
}) async {
  if (meId == null) return;
  try {
    final owned = await (repo ?? StoreRepository()).equippedFor(meId);
    effects.playOwnEntry(entryItemsFrom(owned), senderId: meId);
  } catch (e) {
    debugPrint('own entry failed: $e');
  }
}

/// The items to play for an entry, vehicle first and then the entry effect (the order the join row uses),
/// leaving out anything expired or not an entry kind.
@visibleForTesting
List<StoreItem> entryItemsFrom(List<OwnedItem> owned) {
  final live = [
    for (final o in owned)
      if (!o.isExpired && o.equipped) o.item,
  ];
  return [
    ...live.where((i) => i.category == StoreCategory.vehicle),
    ...live.where((i) => i.category == StoreCategory.entryEffect),
  ];
}
