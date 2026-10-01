import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';

/// True once a `live_streams` row has finished.
bool streamHasEnded(Map<String, dynamic>? row) => row?['status'] == 'ended';

/// Calls [onEnded] — at most once — when stream [streamId] ends: the host
/// pressed End, or the stale-stream cleanup ended it. Viewer screens use it to
/// take people out of a room whose host has gone, instead of leaving them
/// staring at a dead stream. Returns a function that stops watching.
///
/// `live_streams` is on the realtime publication, so this is a push, not a
/// poll. The one-off read covers a stream that ended between the live list
/// loading and this screen subscribing.
void Function() watchStreamEnd(String streamId, void Function() onEnded) {
  var fired = false;
  void fire() {
    if (fired) return;
    fired = true;
    onEnded();
  }

  final channel = supabase
      .channel('live-end:$streamId')
      .onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'live_streams',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'id',
          value: streamId,
        ),
        callback: (payload) {
          if (streamHasEnded(payload.newRecord)) fire();
        },
      )
      .subscribe();

  supabase
      .from('live_streams')
      .select('status')
      .eq('id', streamId)
      .maybeSingle()
      .then((row) {
        if (streamHasEnded(row)) fire();
      })
      .catchError((_) {});

  return () => channel.unsubscribe();
}
