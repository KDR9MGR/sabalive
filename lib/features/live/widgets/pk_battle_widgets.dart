import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../../../core/i18n/text.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/pills.dart';
import '../../../data/models.dart';
import '../../../data/pk_battles_repository.dart';
import '../../../state/pk_battle_controller.dart';
import '../../../theme/app_colors.dart';
import 'pk_battle_arena.dart';
import 'pk_score_bar.dart';
import 'seat_snapshot.dart';

/// The PK battle layer's screens (PK as a layer over a normal audio live; see HANDOFF.md "PK battle layer"). Everything here only
/// READS the [PkBattleController]; the server row is the single source of truth.

/// The invite lengths the server offers (`pk_config.invite_durations`), as shown on the chips. A random PK is always 5 minutes.
const List<int> kPkInviteSeconds = [300, 600, 1800, 2400];

String pkLengthLabel(int seconds) => '${seconds ~/ 60} min';

// ---------------------------------------------------------------------------------------------------------------- header
/// The strip shown while a battle is being SET UP: "looking for an opponent" (with a way to stop) and "waiting for the other host". Once
/// the 3-2-1 starts it draws nothing: the arena (audio) or the video stage takes over. Draws nothing without a battle either.
class PkBattleHeader extends StatelessWidget {
  const PkBattleHeader({super.key, required this.controller, required this.me});

  final PkBattleController controller;

  /// The host of THIS live (my side).
  final AppUser me;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        switch (c.phase) {
          case PkPhase.searching:
            return _pill('Looking for an opponent…', onCancel: () => c.stopSearch(), busy: true);
          case PkPhase.inviting:
            return _pill(
              'Waiting for ${c.opponent?.name ?? 'the other host'}…',
              onCancel: c.amHost ? () => c.cancel() : null,
              busy: true,
            );
          default:
            return const SizedBox.shrink();
        }
      },
    );
  }

  Widget _pill(String text, {VoidCallback? onCancel, bool busy = false}) {
    return Container(
      key: const ValueKey('pk-status'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(22)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70)),
          if (busy) const SizedBox(width: 10),
          Flexible(child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600))),
          if (onCancel != null)
            IconButton(
              key: const ValueKey('pk-cancel'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded, size: 18, color: Colors.white70),
              onPressed: onCancel,
            ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------------------------------------------- audio top
/// What an AUDIO room (host and viewer) shows above its seats during PK: the setup strip, then the red / blue arena. The room hides
/// its own seat grid while [PkBattleController.fighting] (the arena draws the seats of both rooms itself).
class PkBattleTop extends StatelessWidget {
  const PkBattleTop({
    super.key,
    required this.controller,
    required this.me,
    required this.mine,
    this.skinned = false,
    this.fetchSeats = fetchSeatSnapshot,
    this.every = const Duration(seconds: 8),
  });
  final PkBattleController controller;
  final AppUser me;
  final PkSeatsData mine;

  /// The room has a skin: the arena's two halves let it show through.
  final bool skinned;
  final Future<SeatSnapshot?> Function(String streamId) fetchSeats;
  final Duration every;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      PkBattleHeader(controller: controller, me: me),
      PkBattleArena(controller: controller, me: me, mine: mine, skinned: skinned, fetchSeats: fetchSeats, every: every),
    ],
  );
}

// ----------------------------------------------------------------------------------------------------------- confetti
/// A one-shot burst of confetti for a win (about 2 s, then it stops: a looping animation does not belong on a live screen).
class PkConfetti extends StatefulWidget {
  const PkConfetti({super.key});

  @override
  State<PkConfetti> createState() => _PkConfettiState();
}

class _PkConfettiState extends State<PkConfetti> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))..forward();
  final _random = math.Random(7);
  late final List<_Piece> _pieces = [for (var i = 0; i < 46; i++) _Piece(_random)];

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) => CustomPaint(key: const ValueKey('pk-confetti'), painter: _ConfettiPainter(_pieces, _c.value), size: Size.infinite),
    ),
  );
}

class _Piece {
  _Piece(math.Random r)
    : x = r.nextDouble(),
      delay = r.nextDouble() * 0.35,
      speed = 0.55 + r.nextDouble() * 0.5,
      sway = (r.nextDouble() - 0.5) * 0.18,
      size = 5 + r.nextDouble() * 6,
      color = const [Color(0xFFFFD166), Color(0xFFFF5C8A), Color(0xFF4DD4FF), Color(0xFF7CFFB2), Color(0xFFFFFFFF)][r.nextInt(5)];
  final double x, delay, speed, sway, size;
  final Color color;
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.pieces, this.t);
  final List<_Piece> pieces;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in pieces) {
      final local = ((t - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final y = -20 + local * p.speed * (size.height + 40);
      final x = p.x * size.width + math.sin(local * 9 + p.x * 20) * p.sway * size.width;
      final paint = Paint()..color = p.color.withValues(alpha: (1 - local * local).clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(local * 10 + p.x * 6);
      canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 0.55), paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}

// ------------------------------------------------------------------------------------------------------ video stage
/// A VIDEO PK battle's picture: the scores and the clock over a slim red / blue bar, then two videos side by side in a red and a
/// blue frame, mine on the left and the opponent's on the right; whoever leads carries WIN, the other LOSE. [left] and [right] are
/// the two video views (or whatever shows while one is not there yet): this widget only lays them out, so the same stage serves
/// the host (a local camera and a remote one) and the viewers (two remote ones).
class PkVideoStage extends StatelessWidget {
  const PkVideoStage({super.key, required this.controller, required this.me, required this.left, required this.right});

  final PkBattleController controller;
  final AppUser me;
  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PkBattleHeader(controller: controller, me: me),
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            if (!controller.fighting) return const SizedBox.shrink();
            final mine = controller.scoreMine;
            final theirs = controller.scoreTheirs;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _scores(controller, mine, theirs),
                Padding(padding: const EdgeInsets.fromLTRB(2, 2, 2, 6), child: PkThinBar(scoreA: mine, scoreB: theirs)),
                Row(
                  children: [
                    Expanded(
                      child: _pane(left, me.name, AppColors.live, mine > theirs ? 'WIN' : (mine < theirs ? 'LOSE' : null),
                          winning: mine > theirs, key: const ValueKey('pk-pane-left')),
                    ),
                    const SizedBox(width: 3),
                    Expanded(
                      child: _pane(right, controller.opponent?.name ?? '…', AppColors.diamond,
                          theirs > mine ? 'WIN' : (theirs < mine ? 'LOSE' : null),
                          winning: theirs > mine, key: const ValueKey('pk-pane-right')),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  /// Score, clock, score: the same numbers the audio arena shows, in one row.
  Widget _scores(PkBattleController c, int mine, int theirs) {
    final starting = c.phase == PkPhase.countdown;
    Widget score(int value, Color tint, {required bool end}) => Expanded(
      child: Row(
        mainAxisAlignment: end ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!end) Icon(Icons.diamond_rounded, size: 12, color: tint),
          if (!end) const SizedBox(width: 3),
          Flexible(
            child: Text(
              compactCount(value),
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w700, fontSize: 13, color: Colors.white),
            ),
          ),
          if (end) const SizedBox(width: 3),
          if (end) Icon(Icons.diamond_rounded, size: 12, color: tint),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          score(mine, AppColors.live, end: false),
          Container(
            key: const ValueKey('pk-clock'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(gradient: AppColors.goldGradient, borderRadius: BorderRadius.circular(12)),
            child: starting
                ? const Text('Starting…', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11, color: Color(0xFF3A1A5E)))
                : ValueListenableBuilder<int>(
                    valueListenable: c.secondsLeft,
                    builder: (_, seconds, _) => Text(
                      'PK ${pkClock(seconds)}',
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11, color: Color(0xFF3A1A5E)),
                    ),
                  ),
          ),
          score(theirs, AppColors.diamond, end: true),
        ],
      ),
    );
  }

  Widget _pane(Widget video, String name, Color frame, String? label, {required bool winning, Key? key}) {
    return AspectRatio(
      key: key,
      aspectRatio: 3 / 4,
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: frame, width: 2), borderRadius: BorderRadius.circular(10)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xFF0B0714)),
              video,
              Positioned(
                left: 6,
                bottom: 6,
                right: 6,
                child: Row(
                  children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(10)),
                        child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 11.5)),
                      ),
                    ),
                    const Spacer(),
                    if (label != null)
                      Text(
                        label,
                        key: ValueKey('pk-${winning ? 'win' : 'lose'}'),
                        style: TextStyle(
                          color: winning ? AppColors.gold : Colors.white70,
                          fontWeight: FontWeight.w800,
                          fontSize: 12.5,
                          shadows: const [Shadow(color: Colors.black87, blurRadius: 4)],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What a half of the stage shows while its video is not there yet (the other host is still joining the shared channel).
class PkVideoWaiting extends StatelessWidget {
  const PkVideoWaiting({super.key});

  @override
  Widget build(BuildContext context) => const Center(
    child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54)),
  );
}

// ------------------------------------------------------------------------------------------------------- invite sheet
/// "Invite PK" / "Random PK": a length and a host from the people I follow who are live now, or a random opponent (always 5 min).
Future<void> showPkInviteSheet(BuildContext context, PkBattleController controller, {int initialTab = 0}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.bgElevated,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
    builder: (_) => _PkInviteSheet(controller: controller, initialTab: initialTab),
  );
}

class _PkInviteSheet extends StatefulWidget {
  const _PkInviteSheet({required this.controller, required this.initialTab});
  final PkBattleController controller;
  final int initialTab;

  @override
  State<_PkInviteSheet> createState() => _PkInviteSheetState();
}

class _PkInviteSheetState extends State<_PkInviteSheet> {
  late int _tab = widget.initialTab;
  int _seconds = kPkInviteSeconds.first;
  List<PkCandidate>? _following;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final list = await widget.controller.api.eligibleFollowing(widget.controller.streamId);
      if (mounted) setState(() => _following = list);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _invite(PkCandidate who) async {
    final navigator = Navigator.of(context);
    await widget.controller.invite(who, _seconds);
    if (!mounted) return;
    if (widget.controller.phase == PkPhase.inviting) {
      navigator.pop(); // the header shows "Waiting for …" now
    } else if (widget.controller.message != null) {
      setState(() => _error = widget.controller.message);
    }
  }

  Future<void> _random() async {
    final navigator = Navigator.of(context);
    await widget.controller.searchRandom();
    if (mounted && widget.controller.phase != PkPhase.idle) navigator.pop();
    if (mounted && widget.controller.message != null) setState(() => _error = widget.controller.message);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Center(child: Text('PK battle', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
            const SizedBox(height: 12),
            SegmentedTabs(tabs: const ['Following', 'Random'], index: _tab, onChanged: (i) => setState(() => _tab = i)),
            const SizedBox(height: 14),
            if (_tab == 0) ...[
              const Text('How long', style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final s in kPkInviteSeconds)
                    ChoiceChip(
                      key: ValueKey('pk-length-$s'),
                      label: Text(pkLengthLabel(s)),
                      selected: _seconds == s,
                      onSelected: (_) => setState(() => _seconds = s),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              ConstrainedBox(constraints: const BoxConstraints(maxHeight: 320), child: _followingList()),
            ] else ...[
              const Text(
                'You are matched with another host who is live right now and looking for a PK. A random PK lasts 5 minutes.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('pk-random'),
                  onPressed: widget.controller.busy ? null : _random,
                  child: const Text('Find an opponent'),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, key: const ValueKey('pk-error'), style: const TextStyle(color: AppColors.danger, fontSize: 12.5)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _followingList() {
    final list = _following;
    if (list == null) {
      return _error != null
          ? const SizedBox.shrink()
          : const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    }
    if (list.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Text(
          'Nobody you follow is live and free for a PK right now. Try Random.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
      );
    }
    return ListView(
      shrinkWrap: true,
      children: [
        for (final who in list)
          ListTile(
            key: ValueKey('pk-candidate-${who.streamId}'),
            contentPadding: EdgeInsets.zero,
            leading: AppAvatar(name: who.hostName, imageUrl: who.hostAvatarUrl, size: 42),
            title: Text(who.hostName, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${who.viewerCount} watching', style: const TextStyle(fontSize: 11.5)),
            trailing: FilledButton(
              onPressed: widget.controller.busy ? null : () => _invite(who),
              child: const Text('Invite'),
            ),
          ),
      ],
    );
  }
}

// ----------------------------------------------------------------------------------------------------- events (dialogs)
/// Not drawn itself (only the 3-2-1 over the screen): reacts to the controller by opening what the moment needs. An invite to me
/// (Accept / Decline), the countdown, the result, a cancelled battle, an error. Put it in the screen's Stack.
class PkBattleEvents extends StatefulWidget {
  const PkBattleEvents({super.key, required this.controller});
  final PkBattleController controller;

  @override
  State<PkBattleEvents> createState() => _PkBattleEventsState();
}

class _PkBattleEventsState extends State<PkBattleEvents> {
  PkPhase _seen = PkPhase.idle;
  Timer? _count;
  int _number = 0;
  bool _incomingOpen = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _count?.cancel();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final c = widget.controller;
    final phase = c.phase;
    if (phase == _seen) {
      return;
    }
    final before = _seen;
    _seen = phase;
    switch (phase) {
      case PkPhase.incoming:
        _showIncoming();
      case PkPhase.countdown:
        _startCount();
        HapticFeedback.mediumImpact();
      case PkPhase.finished:
        _stopCount();
        _showResult();
      case PkPhase.cancelled:
        _stopCount();
        final text = c.message;
        c.acknowledge();
        if (text != null) _snack(text);
      case PkPhase.idle:
        _stopCount();
        if (c.message != null && before == PkPhase.searching) _snack(c.message!);
      default:
        break;
    }
  }

  void _snack(String text) {
    final m = ScaffoldMessenger.maybeOf(context);
    m?.showSnackBar(SnackBar(content: Text(text)));
  }

  void _startCount() {
    _count?.cancel();
    setState(() => _number = 3);
    _count = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _number <= 1) {
        t.cancel();
        if (mounted) setState(() => _number = 0);
        return;
      }
      setState(() => _number--);
    });
  }

  void _stopCount() {
    _count?.cancel();
    if (_number != 0 && mounted) setState(() => _number = 0);
  }

  Future<void> _showIncoming() async {
    if (_incomingOpen) return;
    _incomingOpen = true;
    final c = widget.controller;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => ListenableBuilder(
        listenable: c,
        builder: (_, _) {
          // the invite was withdrawn or timed out while this was open: close it
          if (c.phase != PkPhase.incoming) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (dialogContext.mounted && Navigator.of(dialogContext).canPop()) Navigator.of(dialogContext).pop();
            });
          }
          final who = c.opponent?.name ?? 'A host';
          final minutes = (c.battle?.durationSeconds ?? 300) ~/ 60;
          return AlertDialog(
            backgroundColor: AppColors.bgElevated,
            title: const Text('PK invite'),
            content: Text('$who invites you to a $minutes minute PK battle.'),
            actions: [
              TextButton(
                key: const ValueKey('pk-decline'),
                onPressed: c.busy ? null : () => c.respond(false),
                child: const Text('Decline'),
              ),
              FilledButton(
                key: const ValueKey('pk-accept'),
                onPressed: c.busy ? null : () => c.respond(true),
                child: const Text('Accept'),
              ),
            ],
          );
        },
      ),
    );
    _incomingOpen = false;
  }

  Future<void> _showResult() async {
    final c = widget.controller;
    final r = c.result;
    if (r == null) return;
    final title = switch (r.outcome) {
      PkOutcome.win => 'You won!',
      PkOutcome.lose => 'You lost',
      PkOutcome.draw => "It's a draw",
    };
    final why = r.forfeit
        ? (r.outcome == PkOutcome.win ? 'The other host left, so you win.' : 'You left the battle.')
        : 'Final score: ${r.mine} – ${r.theirs}';
    if (r.outcome == PkOutcome.win) HapticFeedback.heavyImpact();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Stack(
        children: [
          if (r.outcome == PkOutcome.win) const Positioned.fill(child: PkConfetti()),
          AlertDialog(
            backgroundColor: AppColors.bgElevated,
            title: Text(title, key: const ValueKey('pk-result-title')),
            content: Text(why),
            actions: [
              FilledButton(
                key: const ValueKey('pk-result-ok'),
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Back to the live'),
              ),
            ],
          ),
        ],
      ),
    );
    c.acknowledge();
  }

  @override
  Widget build(BuildContext context) {
    if (_number == 0) return const SizedBox.shrink();
    return IgnorePointer(
      child: Center(
        child: Text(
          '$_number',
          key: const ValueKey('pk-countdown'),
          style: const TextStyle(fontSize: 120, fontWeight: FontWeight.w900, color: Colors.white, shadows: [Shadow(blurRadius: 24, color: Colors.black87)]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------------------- gifting
/// Which host of the battle a gift is for.
enum PkGiftSide { mine, theirs }

/// While a battle is live, who a gift counts for: the host of THIS room is [PkGiftSide.mine], the other host is [PkGiftSide.theirs].
/// Null = an ordinary gift (to a guest on a seat, to everyone, or no battle is live).
PkGiftSide? pkGiftSideFor(PkBattleController c, {required String? recipientId, required String myHostId, bool sendToAll = false}) {
  if (c.phase != PkPhase.live || sendToAll) return null;
  if (recipientId == null || recipientId == myHostId) return PkGiftSide.mine;
  if (recipientId == c.opponent?.id) return PkGiftSide.theirs;
  return null;
}

/// The people the gift sheet offers: the room's own list, and while a battle is live the OTHER host too, so a gift to either host is
/// picked in the sheet like in any audio live (no extra question). "Send to all" never includes the other host.
List<AppUser> pkGiftSheetRecipients(List<AppUser> base, PkBattleController? c) {
  final them = c?.opponent;
  if (c == null || c.phase != PkPhase.live || them == null || base.any((u) => u.id == them.id)) return base;
  return [...base, them];
}

/// Sends the gift through the server's PK gift, once per unit, so the coins count for that host's side. Returns the side it went to
/// ('a' / 'b'), or null if it failed (the reason is shown in a snackbar).
Future<String?> sendPkGift(BuildContext context, PkBattleController c, Gift gift, int quantity, {required PkGiftSide to}) async {
  final battle = c.battle;
  final mine = c.mySide;
  if (battle == null || mine == null || c.phase != PkPhase.live) return null;
  final side = to == PkGiftSide.mine ? mine : (mine == 'a' ? 'b' : 'a');
  try {
    for (var i = 0; i < quantity; i++) {
      await c.gift(side, gift);
    }
    return side;
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    return null;
  }
}
