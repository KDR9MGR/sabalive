import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../../../core/i18n/text.dart';
import '../../../data/models.dart';
import '../../../state/pk_battle_controller.dart';
import '../../../theme/app_colors.dart';
import 'emote_overlay.dart';
import 'pk_score_bar.dart';
import 'seat_room.dart';
import 'seat_snapshot.dart';

/// How many guest seats one side of the arena shows. The host is the big picture and is not counted.
const int kPkSeatsPerSide = 7;

/// The seat counts a host can move between during a battle: the host and three guests (the smallest room) up to the host and seven
/// guests (what one side of the arena shows).
const int kPkMinSeats = 4;
const int kPkMaxSeats = 1 + kPkSeatsPerSide;

/// The seat count after the host taps Add seat ([more]) or Remove seat during a battle: one at a time. A room made bigger before the
/// battle comes down to [kPkMaxSeats] on the first Remove. Returns [current] when there is nowhere to go.
int pkNextSeatCount(int current, {required bool more}) {
  if (more) return current >= kPkMaxSeats ? current : current + 1;
  if (current <= kPkMinSeats) return current;
  if (current > kPkMaxSeats) return kPkMaxSeats;
  return current - 1;
}

/// What the HOST of a room can do from the arena. A null callback greys that button out. A viewer's arena has none of this.
class PkHostControls {
  const PkHostControls({this.onAddSeat, this.onRemoveSeat, this.onRequests, this.requestCount = 0});
  final VoidCallback? onAddSeat;
  final VoidCallback? onRemoveSeat;

  /// Opens the list of people who asked for a seat.
  final VoidCallback? onRequests;
  final int requestCount;
}

/// Asks the host to confirm ending the battle: it is giving up, so the other host wins. Then ends it; if the server cannot (it has no
/// give-up function yet) the reason is shown and the battle goes on.
Future<void> confirmEndPk(BuildContext context, PkBattleController controller) async {
  if (controller.phase != PkPhase.live || !controller.amHost) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.bgElevated,
      title: const Text('End the PK now?'),
      content: const Text('You give up and the other host wins. This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
        TextButton(
          key: const ValueKey('pk-end-confirm'),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('End PK', style: TextStyle(color: AppColors.danger)),
        ),
      ],
    ),
  );
  if (ok != true) return;
  await controller.giveUp();
  final message = controller.message;
  if (context.mounted && controller.phase == PkPhase.live && message != null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// One seat shown in the arena.
class PkArenaSeat {
  const PkArenaSeat(this.seat, this.occupant, this.locked);
  final int seat;
  final AppUser? occupant;
  final bool locked;
}

/// The seats one side of the arena shows, and how many seated guests did not fit.
class PkArenaSeats {
  const PkArenaSeats(this.shown, this.hidden);
  final List<PkArenaSeat> shown;
  final int hidden;
}

/// Which seats of a room the arena draws: at most [max] guest seats (the host's own seat is the big picture, so it is left out).
/// People sitting come first, in seat order, so nobody who is talking is hidden behind an empty seat; the rest of the places go to
/// the lowest free (or locked) seats. The result is in seat order. [hidden] counts seated guests that did not fit.
/// [keep] is a seat that is always shown when someone is on it (a viewer's own seat: they must be able to tap it to leave).
PkArenaSeats pkArenaSeats({
  required int seatCount,
  required Map<int, AppUser> occupants,
  Set<int> locked = const {},
  String? hostId,
  int? keep,
  int max = kPkSeatsPerSide,
}) {
  var top = seatCount < 0 ? 0 : seatCount;
  for (final seat in occupants.keys) {
    if (seat > top) top = seat; // an older room can hold a guest above its own seat count
  }
  final candidates = [
    for (var seat = 1; seat <= top; seat++)
      if (hostId == null || occupants[seat]?.id != hostId) seat,
  ];
  final seated = [for (final seat in candidates) if (occupants[seat] != null) seat];
  // the kept seat goes first, so it is never the one that does not fit
  final guests = [if (keep != null && seated.contains(keep)) keep, for (final seat in seated) if (seat != keep) seat];
  final chosen = <int>{...guests.take(max)};
  for (final seat in candidates) {
    if (chosen.length >= max) break;
    if (occupants[seat] == null && seat <= seatCount) chosen.add(seat);
  }
  final ordered = chosen.toList()..sort();
  return PkArenaSeats(
    [for (final seat in ordered) PkArenaSeat(seat, occupants[seat], locked.contains(seat))],
    guests.length - guests.take(max).length,
  );
}

/// What the arena needs to draw MY side: this room's real seats and what a tap on one does (the host's seat menu, a viewer's
/// request / leave). The other side is read from the other live and is never tappable.
class PkSeatsData {
  const PkSeatsData({
    required this.hostId,
    required this.seatCount,
    required this.occupants,
    required this.onSeatTap,
    this.lockedSeats = const {},
    this.mutedSeats = const {},
    this.speakingSeats = const {},
    this.emotes,
    this.mySeat,
    this.controls,
  });

  /// Add / Remove seat, the requests and End PK: the host's screen only.
  final PkHostControls? controls;

  final String hostId;

  /// The seat the person looking at this room sits on (a viewer on a seat), or null. The arena always shows it.
  final int? mySeat;
  final int seatCount;
  final Map<int, AppUser> occupants;
  final Set<int> lockedSeats;
  final Set<int> mutedSeats;
  final Set<int> speakingSeats;
  final EmoteController? emotes;
  final void Function(int seat) onSeatTap;

  int? get hostSeat {
    for (final e in occupants.entries) {
      if (e.value.id == hostId) return e.key;
    }
    return null;
  }
}

/// Rebuilds [builder] only when a battle comes on or goes off (not on every score), so a room that hides its own seat grid during a
/// battle does not redraw all its seats on each gift.
class PkFighting extends StatefulWidget {
  const PkFighting({super.key, required this.controller, required this.builder});

  /// Null = no PK in this room: [builder] always gets false.
  final PkBattleController? controller;
  final Widget Function(BuildContext context, bool fighting) builder;

  @override
  State<PkFighting> createState() => _PkFightingState();
}

class _PkFightingState extends State<PkFighting> {
  bool _on = false;

  @override
  void initState() {
    super.initState();
    _on = widget.controller?.fighting ?? false;
    widget.controller?.addListener(_changed);
  }

  @override
  void didUpdateWidget(PkFighting old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?.removeListener(_changed);
      widget.controller?.addListener(_changed);
      _on = widget.controller?.fighting ?? false;
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final on = widget.controller?.fighting ?? false;
    if (on != _on && mounted) setState(() => _on = on);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _on);
}

/// Reads the OTHER live's seats while a battle runs, every few seconds (no extra live connection), and hands them to [builder]
/// (null until the first read, and again when the battle is over).
class PkOpponentSeats extends StatefulWidget {
  const PkOpponentSeats({
    super.key,
    required this.controller,
    required this.builder,
    this.fetchSeats = fetchSeatSnapshot,
    this.every = const Duration(seconds: 8),
  });

  final PkBattleController controller;
  final Future<SeatSnapshot?> Function(String streamId) fetchSeats;
  final Duration every;
  final Widget Function(BuildContext context, SeatSnapshot? seats) builder;

  @override
  State<PkOpponentSeats> createState() => _PkOpponentSeatsState();
}

class _PkOpponentSeatsState extends State<PkOpponentSeats> {
  Timer? _timer;
  String? _watching;
  SeatSnapshot? _snap;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    _timer?.cancel();
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    final c = widget.controller;
    final on = c.fighting ? c.opponentStreamId : null;
    if (on == _watching) return;
    _watching = on;
    _timer?.cancel();
    if (on == null) {
      setState(() => _snap = null);
      return;
    }
    unawaited(_read(on));
    _timer = Timer.periodic(widget.every, (_) => _read(on));
  }

  Future<void> _read(String streamId) async {
    final snap = await widget.fetchSeats(streamId);
    if (!mounted || _watching != streamId || snap == null) return;
    setState(() => _snap = snap);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _snap);
}

/// The old PK screen's look, inside the live room: a red half (this live's host) and a blue half (the opponent), each with the
/// host's big picture, name and up to [kPkSeatsPerSide] seats, and under them the tug-of-war bar, VS badge, clock and scores.
/// The red half is this room's own seats (tappable the way the room's seats are); the blue half is read-only.
/// Draws nothing outside the 3-2-1 and the battle.
class PkBattleArena extends StatelessWidget {
  const PkBattleArena({
    super.key,
    required this.controller,
    required this.me,
    required this.mine,
    this.skinned = false,
    this.fetchSeats = fetchSeatSnapshot,
    this.every = const Duration(seconds: 8),
  });

  final PkBattleController controller;

  /// The host of THIS live (the red half).
  final AppUser me;
  final PkSeatsData mine;

  /// The room has a skin: the two halves become see-through so it shows behind them.
  final bool skinned;
  final Future<SeatSnapshot?> Function(String streamId) fetchSeats;
  final Duration every;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.fighting) return const SizedBox.shrink();
        final starting = controller.phase == PkPhase.countdown;
        return Container(
          key: const ValueKey('pk-arena'),
          margin: const EdgeInsets.only(bottom: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(
                  children: [
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: _mySide()),
                          Expanded(child: _theirSide()),
                        ],
                      ),
                    ),
                    if (starting)
                      Positioned(
                        top: 6,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(12)),
                            child: const Text('Starting…', style: TextStyle(color: AppColors.gold, fontSize: 11, fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<int>(
                valueListenable: controller.secondsLeft,
                builder: (_, seconds, _) => PkScoreBar(
                  scoreA: controller.scoreMine,
                  scoreB: controller.scoreTheirs,
                  secondsLeft: starting ? (controller.battle?.durationSeconds ?? 0) : seconds,
                ),
              ),
              if (mine.controls != null) _controls(context, mine.controls!),
            ],
          ),
        );
      },
    );
  }

  Widget _controls(BuildContext context, PkHostControls c) {
    Widget chip(IconData icon, String label, VoidCallback? onTap, {Key? key, int badge = 0, Color? tint}) {
      final color = tint ?? Colors.white;
      return Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: GestureDetector(
          key: key,
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(16)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 14, color: color),
                    const SizedBox(width: 4),
                    Text(label, style: TextStyle(fontSize: 11, color: color)),
                  ],
                ),
              ),
              if (badge > 0)
                Positioned(
                  right: -4,
                  top: -5,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
                    child: Text('$badge', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Padding(
      key: const ValueKey('pk-host-controls'),
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          chip(Icons.remove_rounded, 'Remove seat', c.onRemoveSeat, key: const ValueKey('pk-remove-seat')),
          chip(Icons.add_rounded, 'Add seat', c.onAddSeat, key: const ValueKey('pk-add-seat')),
          chip(Icons.person_add_alt_1_rounded, 'Requests', c.onRequests, key: const ValueKey('pk-requests'), badge: c.requestCount),
          if (controller.phase == PkPhase.live && controller.amHost)
            chip(Icons.stop_circle_outlined, 'End PK', () => confirmEndPk(context, controller),
                key: const ValueKey('pk-end'), tint: AppColors.danger),
        ],
      ),
    );
  }

  Widget _mySide() {
    final seats = pkArenaSeats(
      seatCount: mine.seatCount,
      occupants: mine.occupants,
      locked: mine.lockedSeats,
      hostId: mine.hostId,
      keep: mine.mySeat,
    );
    final hostSeat = mine.hostSeat;
    return _ArenaSide(
      key: const ValueKey('pk-arena-mine'),
      skinned: skinned,
      left: true,
      host: me,
      hostSeat: hostSeat,
      hostSpeaking: hostSeat != null && mine.speakingSeats.contains(hostSeat),
      hostMuted: hostSeat != null && mine.mutedSeats.contains(hostSeat),
      onHostTap: hostSeat == null ? null : () => mine.onSeatTap(hostSeat),
      seats: seats,
      mutedSeats: mine.mutedSeats,
      speakingSeats: mine.speakingSeats,
      emotes: mine.emotes,
      onSeatTap: mine.onSeatTap,
    );
  }

  Widget _theirSide() {
    return PkOpponentSeats(
      key: const ValueKey('pk-arena-theirs'),
      controller: controller,
      fetchSeats: fetchSeats,
      every: every,
      builder: (context, snap) {
        final them = controller.opponent;
        final seats = snap == null
            ? const PkArenaSeats([], 0)
            : pkArenaSeats(
                seatCount: snap.seatCount ?? 0,
                occupants: snap.occupants,
                locked: snap.locked ?? const {},
                hostId: them?.id,
              );
        final hostSeat = them == null ? null : snap?.seatOf(them.id);
        return _ArenaSide(
          skinned: skinned,
          left: false,
          host: them,
          hostSeat: hostSeat,
          hostMuted: hostSeat != null && (snap?.muted.contains(hostSeat) ?? false),
          seats: seats,
          mutedSeats: snap?.muted ?? const {},
        );
      },
    );
  }
}

/// One half of the arena. [onSeatTap] / [onHostTap] are null on the opponent's half: nothing there takes a tap.
class _ArenaSide extends StatelessWidget {
  const _ArenaSide({
    super.key,
    required this.skinned,
    required this.left,
    required this.host,
    required this.seats,
    this.hostSeat,
    this.hostSpeaking = false,
    this.hostMuted = false,
    this.onHostTap,
    this.mutedSeats = const {},
    this.speakingSeats = const {},
    this.emotes,
    this.onSeatTap,
  });

  final bool left;
  final bool skinned;
  final AppUser? host;
  final int? hostSeat;
  final bool hostSpeaking;
  final bool hostMuted;
  final VoidCallback? onHostTap;
  final PkArenaSeats seats;
  final Set<int> mutedSeats;
  final Set<int> speakingSeats;
  final EmoteController? emotes;
  final void Function(int seat)? onSeatTap;

  @override
  Widget build(BuildContext context) {
    final glow = left ? AppColors.live : AppColors.diamond;
    final wallpaper = host?.pkWallpaper;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            for (final c in wallpaper != null
                ? AppColors.tints[wallpaper % AppColors.tints.length]
                : left
                ? const [Color(0xFFB1122B), Color(0xFF3A0A16)]
                : const [Color(0xFF11489B), Color(0xFF0A1B3A)])
              // with a room skin the halves keep their red / blue but let the skin through
              skinned ? c.withValues(alpha: 0.58) : c,
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 10, 6, 6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            _hostPicture(glow),
            const SizedBox(height: 4),
            Text(
              host?.name ?? '…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w700, fontSize: 13, color: Colors.white),
            ),
            const SizedBox(height: 8),
            // three to a row: seven seats are three short rows, and three fit the narrowest half
            for (var i = 0; i < seats.shown.length; i += 3)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var j = i; j < i + 3 && j < seats.shown.length; j++) ...[
                      if (j > i) const SizedBox(width: 4),
                      _seat(seats.shown[j]),
                    ],
                  ],
                ),
              ),
            if (seats.hidden > 0)
              Container(
                key: const ValueKey('pk-arena-more'),
                margin: const EdgeInsets.only(top: 2),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
                child: Text('+${seats.hidden}', style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w600)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _hostPicture(Color glow) {
    return SizedBox(
      width: 76,
      height: 76,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [BoxShadow(color: glow.withValues(alpha: 0.55), blurRadius: 18)]),
          ),
          if (host == null)
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.08)),
              child: const Icon(Icons.person_outline_rounded, color: Colors.white38, size: 30),
            )
          else
            SeatCircle(
              seat: hostSeat ?? 0,
              occupant: host,
              isHost: true,
              speaking: hostSpeaking,
              muted: hostMuted,
              size: 46,
              slot: 72,
              showLabel: false,
              emotes: emotes,
              onTap: onHostTap,
            ),
        ],
      ),
    );
  }

  Widget _seat(PkArenaSeat s) => SeatCircle(
    key: ValueKey('pk-arena-seat-${left ? 'a' : 'b'}-${s.seat}'),
    seat: s.seat,
    occupant: s.occupant,
    locked: s.locked,
    muted: mutedSeats.contains(s.seat),
    speaking: speakingSeats.contains(s.seat),
    size: 28,
    slot: 38,
    emotes: emotes,
    onTap: onSeatTap == null ? null : () => onSeatTap!(s.seat),
  );
}
