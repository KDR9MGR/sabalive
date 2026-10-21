import '../../../data/models.dart';
import '../../../state/live_warning_store.dart';

/// The first lines of a new arrival's OWN chat in a live (video or audio, and so in PK): their "joined" notice, then the house-rules warning
/// under it. Only the person who just arrived sees them; nobody else's chat gets the warning, so a busy room is not told the rules again
/// at every join. Empty for a ghost (they watch without leaving a trace) and when the panel has the warning switched off.
///
/// The shared "joined the live stream" line that the server writes for everyone is not shown to its own author (the screen drops it),
/// because this notice already is their own.
List<LiveChatLine> arrivalLines({required AppUser? me, required LiveWarning warning}) {
  if (me == null || me.isGhost || !warning.enabled) return const [];
  return [
    LiveChatLine(me, 'joined the live stream', system: true),
    LiveChatLine(me, warning.shown, system: true, notice: true),
  ];
}
