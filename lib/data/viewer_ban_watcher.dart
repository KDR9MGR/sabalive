import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';

/// Calls [onRemoved] — at most once — when the host of [streamId] removes
/// [userId] from the live ("Block viewer"). Viewer screens use it to take the
/// person out of the room the moment it happens. Returns a function that stops
/// watching.
void Function() watchViewerRemoval(
  String streamId,
  String userId,
  void Function() onRemoved,
) {
  var fired = false;
  void fire() {
    if (fired) return;
    fired = true;
    onRemoved();
  }

  final channel = supabase
      .channel('viewer-ban:$streamId:$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'live_stream_viewer_bans',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'user_id',
          value: userId,
        ),
        callback: (payload) {
          if (payload.newRecord['live_stream_id'] == streamId) fire();
        },
      )
      .subscribe();

  return () => channel.unsubscribe();
}
