/// Which joined Agora uid is which host, for a VIEWER of a video PK battle (left = the host of the room being watched, right = the other).
///
/// [mine] and [theirs] are the two hosts' uids as the database has them (`live_streams.host_agora_uid` of this live and of the other
/// one); each is null until known and can be STALE: a host gets a new uid every time it joins a channel (the move into the battle's
/// shared channel included) and writes it a moment later. So a uid only counts when it is among the [joined] broadcasters, and the two
/// halves never get the same uid.
///
/// When only one host can be recognised, the OTHER joined uid is the other host (never a guess between the two). When neither can,
/// two joined hosts fill the halves in a fixed order until the real uids arrive, and a single unknown one waits (a half that is
/// briefly empty is better than the wrong host on it).
({int? left, int? right}) pkVideoUids({required int? mine, required int? theirs, required Set<int> joined}) {
  final m = mine != null && joined.contains(mine) ? mine : null;
  final t = theirs != null && theirs != m && joined.contains(theirs) ? theirs : null;
  var left = m;
  var right = t;
  final rest = joined.where((u) => u != m && u != t).toList()..sort();
  if (left == null && right == null) {
    if (joined.length >= 2) {
      final sorted = joined.toList()..sort();
      left = sorted.first;
      right = sorted.last;
    }
  } else {
    // one host is recognised: the other joined uid, if there is one, is the other host
    left ??= rest.firstOrNull;
    right ??= rest.firstOrNull;
  }
  return (left: left, right: right);
}
