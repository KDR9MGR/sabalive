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
import '../../../state/pk_theme_store.dart';
import '../../../theme/app_colors.dart';
import 'pk_battle_arena.dart';
import 'pk_score_bar.dart';
import 'pk_svga.dart';
import 'pk_visit_opponent.dart';
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
            return _setup(_pill('Looking for an opponent…', onCancel: () => c.stopSearch(), busy: true));
          case PkPhase.inviting:
            return _setup(
              _pill(
                'Waiting for ${c.opponent?.name ?? 'the other host'}…',
                onCancel: c.amHost ? () => c.cancel() : null,
                busy: true,
              ),
            );
          default:
            return const SizedBox.shrink();
        }
      },
    );
  }

  /// The strip, with the red-meets-blue "matching" animation above it (when the PK animations are on).
  Widget _setup(Widget pill) {
    if (!PkThemeStore.instance.theme.animations) return pill;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          key: const ValueKey('pk-matching'),
          height: 108,
          child: AspectRatio(aspectRatio: 750 / 500, child: PkSvga(PkAsset.matching, loop: true)),
        ),
        pill,
      ],
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
    this.onTapTheirs,
    this.fetchSeats = fetchSeatSnapshot,
    this.every = const Duration(seconds: 8),
  });
  final PkBattleController controller;
  final AppUser me;
  final PkSeatsData mine;

  /// A viewer's way to go to the other host's room (the blue half is tappable); null for a host.
  final VoidCallback? onTapTheirs;

  /// The room has a skin: the arena's two halves let it show through.
  final bool skinned;
  final Future<SeatSnapshot?> Function(String streamId) fetchSeats;
  final Duration every;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      PkBattleHeader(controller: controller, me: me),
      PkBattleArena(controller: controller, me: me, mine: mine, skinned: skinned, onTapTheirs: onTapTheirs, fetchSeats: fetchSeats, every: every),
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
  late final List<_Piece> _pieces = [for (var i = 0; i < 46; i++) _Piece(_random, _palette())];

  /// The two sides' colours and the accent, with a light and a white one.
  List<Color> _palette() {
    final t = PkThemeStore.instance.theme;
    return [t.accent, t.mine, t.theirs, Color.lerp(t.mine, Colors.white, 0.5)!, Colors.white];
  }

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
  _Piece(math.Random r, List<Color> palette)
    : x = r.nextDouble(),
      delay = r.nextDouble() * 0.35,
      speed = 0.55 + r.nextDouble() * 0.5,
      sway = (r.nextDouble() - 0.5) * 0.18,
      size = 5 + r.nextDouble() * 6,
      color = palette[r.nextInt(palette.length)];
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
/// Where the video PK stage ends: the two video frames and the score block under them reach down to this fraction of the screen's
/// height, just above the chat. The owner marked the line on a screenshot of a real phone (the +14 build, 2026-10-19), at 64 %.
const double kPkVideoStageBottom = 0.64;

/// Where a live screen puts [PkVideoStage]: below the top bar, down to [kPkVideoStageBottom] of the screen's height.
EdgeInsets pkVideoStagePadding(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 96, bottom: size.height * (1 - kPkVideoStageBottom));
}

/// What fills the screen behind the video PK stage: the gradient the panel sets (a deep violet into a dark navy by default) instead of the
/// plain black the stage used to sit on, so the space above and below the two frames is part of the picture.
class PkVideoBackdrop extends StatelessWidget {
  const PkVideoBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: PkThemeStore.instance,
    builder: (context, _) => DecoratedBox(
      key: const ValueKey('pk-backdrop'),
      decoration: BoxDecoration(gradient: PkThemeStore.instance.theme.backdrop),
      child: child,
    ),
  );
}

/// A VIDEO PK battle's picture: the scores and the clock over a slim red / blue bar, then two videos side by side in a red and a
/// blue frame, mine on the left and the opponent's on the right; whoever leads carries WIN, the other LOSE. The score block (the slim
/// bar, the scores and the clock) sits UNDER the videos, between them and the chat. [left] and [right] are the two video views (or
/// whatever shows while one is not there yet): this widget only lays them out, so the same stage serves the host (a local camera and
/// a remote one) and the viewers (two remote ones). It fills the height it is given (see [pkVideoStagePadding]): the frames take
/// everything above the score block, so a portrait video is seen whole.
class PkVideoStage extends StatelessWidget {
  const PkVideoStage({super.key, required this.controller, required this.me, required this.left, required this.right, this.onTapTheirs});

  final PkBattleController controller;
  final AppUser me;
  final Widget left;
  final Widget right;

  /// A viewer's way to go to the other host's room: tapping the right frame calls this (it also shows a small switch mark). Null on
  /// a host's screen: nothing to tap.
  final VoidCallback? onTapTheirs;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PkBattleHeader(controller: controller, me: me),
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([controller, PkThemeStore.instance]),
            builder: (context, _) {
              if (!controller.fighting) return const SizedBox.shrink();
              final theme = PkThemeStore.instance.theme;
              final mine = controller.scoreMine;
              final theirs = controller.scoreTheirs;
              return Column(
                children: [
                  Expanded(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                    Row(
                      children: [
                        Expanded(
                          child: _pane(left, me.name, theme.mine, mine > theirs ? 'WIN' : (mine < theirs ? 'LOSE' : null),
                              winning: mine > theirs, accent: theme.accent, key: const ValueKey('pk-pane-left')),
                        ),
                        const SizedBox(width: 3),
                        Expanded(
                          child: _pane(right, controller.opponent?.name ?? '…', theme.theirs,
                              theirs > mine ? 'WIN' : (theirs < mine ? 'LOSE' : null),
                              winning: theirs > mine, accent: theme.accent, key: const ValueKey('pk-pane-right'), onTap: onTapTheirs),
                        ),
                      ],
                    ),
                        // the VS between the two frames; a tap goes through it to the frame under it
                        IgnorePointer(child: _versus(theme)),
                      ],
                    ),
                  ),
                  // the score block under the videos
                  Column(
                    key: const ValueKey('pk-score-block'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(padding: const EdgeInsets.fromLTRB(2, 8, 2, 4), child: PkThinBar(scoreA: mine, scoreB: theirs)),
                      _scores(controller, mine, theirs, theme),
                      const SizedBox(height: 4),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// The "VS" between the two frames: the pack's VS animation (its opening flash once, then the steady shimmer), about 60 px across the
  /// letters; with the PK animations off, or if the file can't be played, a small gold VS pill.
  Widget _versus(PkTheme theme) {
    final pill = Container(
      key: const ValueKey('pk-vs'),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        gradient: theme.accentGradient,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 6)],
      ),
      child: const Text('VS', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFF3A1A5E))),
    );
    if (!theme.animations) return pill;
    // the art is 450 x 800 with the letters in the middle, about 37% of its width
    return SizedBox(
      key: const ValueKey('pk-vs'),
      width: 160,
      height: 284,
      child: PkSvga(PkAsset.versus, loop: true, loopFrom: 0.55, fallback: pill),
    );
  }

  /// Score, clock, score: the same numbers the audio arena shows, in one row.
  Widget _scores(PkBattleController c, int mine, int theirs, PkTheme theme) {
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
          score(mine, theme.mine, end: false),
          Container(
            key: const ValueKey('pk-clock'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(gradient: theme.accentGradient, borderRadius: BorderRadius.circular(12)),
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
          score(theirs, theme.theirs, end: true),
        ],
      ),
    );
  }

  Widget _pane(Widget video, String name, Color frame, String? label, {required bool winning, required Color accent, Key? key, VoidCallback? onTap}) {
    return KeyedSubtree(
      key: key,
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: frame, width: 2), borderRadius: BorderRadius.circular(10)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xFF0B0714)),
              video,
              if (onTap != null) ...[
                // above the video (a platform view takes touches of its own): a transparent layer that catches the tap
                Positioned.fill(child: GestureDetector(key: const ValueKey('pk-visit-tap'), behavior: HitTestBehavior.opaque, onTap: onTap)),
                const Positioned(top: 6, right: 6, child: PkSwitchMark()),
              ],
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
                          color: winning ? accent : Colors.white70,
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
            if (PkThemeStore.instance.theme.animations)
              Center(
                child: SizedBox(key: const ValueKey('pk-sheet-logo'), height: 64, child: AspectRatio(aspectRatio: 2, child: PkSvga(PkAsset.logo, loop: true))),
              ),
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
  const PkBattleEvents({super.key, required this.controller, this.watchedHostName});
  final PkBattleController controller;

  /// On a VIEWER's screen: the host of the room being watched. The result is then told as a spectator's ("`name` won!"), not as a
  /// host's ("You won!"). Null on a host's own screen.
  final String? watchedHostName;

  @override
  State<PkBattleEvents> createState() => _PkBattleEventsState();
}

class _PkBattleEventsState extends State<PkBattleEvents> {
  PkPhase _seen = PkPhase.idle;
  Timer? _count;
  int _number = 0;
  bool _incomingOpen = false;

  /// The big full-screen intro is playing (the panel's optional switch), and the "VS" burst that opens the battle is playing.
  bool _hero = false;
  bool _burst = false;

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
      case PkPhase.live:
        // the bell: the countdown art goes at once and the "VS" burst takes its place, only for the moment the countdown ends (not
        // for someone who joins a battle already under way)
        _stopCount();
        if (before == PkPhase.countdown) _startBurst();
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

  void _startBurst() {
    final theme = PkThemeStore.instance.theme;
    // the big intro has its own finish: no second burst on top of it
    if (!theme.animations || theme.heroIntro) return;
    setState(() => _burst = true);
  }

  void _startCount() {
    _count?.cancel();
    final theme = PkThemeStore.instance.theme;
    setState(() {
      _number = 3;
      _hero = theme.animations && theme.heroIntro;
    });
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
            title: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (PkThemeStore.instance.theme.animations)
                  SizedBox(key: const ValueKey('pk-invite-art'), height: 110, child: AspectRatio(aspectRatio: 1, child: PkSvga(PkAsset.invite, loop: true))),
                const Text('PK invite'),
              ],
            ),
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
    // a viewer is a spectator: the winner is named, nobody is told "you" won or lost
    final spectator = !c.amHost;
    final host = widget.watchedHostName ?? 'This host';
    final theirs = c.opponent?.name ?? 'The other host';
    final title = spectator
        ? switch (r.outcome) {
            PkOutcome.win => '$host won!',
            PkOutcome.lose => '$theirs won!',
            PkOutcome.draw => "It's a draw",
          }
        : switch (r.outcome) {
            PkOutcome.win => 'You won!',
            PkOutcome.lose => 'You lost',
            PkOutcome.draw => "It's a draw",
          };
    final why = r.forfeit
        ? (spectator
              ? 'The other host gave up.'
              : (r.outcome == PkOutcome.win ? 'The other host left, so you win.' : 'You left the battle.'))
        : 'Final score: ${r.mine} – ${r.theirs}';
    if (r.outcome == PkOutcome.win) HapticFeedback.heavyImpact();
    // the badge: WIN / LOSE / DRAW (the crying face for a loss when the panel chose that), kept playing while the card waits for its
    // button (each fades out at the end of its 5 s); without the animations, the plain text and, for a win, the confetti
    final theme = PkThemeStore.instance.theme;
    final emoji = r.outcome == PkOutcome.lose && theme.loseStyle == PkLoseStyle.emoji;
    final art = !theme.animations
        ? null
        : switch (r.outcome) {
            PkOutcome.win => PkAsset.win,
            PkOutcome.lose => emoji ? PkAsset.loseEmoji : PkAsset.lose,
            PkOutcome.draw => PkAsset.draw,
          };
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Stack(
        children: [
          if (r.outcome == PkOutcome.win && art == null) const Positioned.fill(child: PkConfetti()),
          AlertDialog(
            backgroundColor: AppColors.bgElevated,
            title: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (art != null)
                  SizedBox(key: const ValueKey('pk-result-art'), height: 170, child: AspectRatio(aspectRatio: emoji ? 1 : 360 / 450, child: PkSvga(art, loop: true))),
                Text(title, key: const ValueKey('pk-result-title')),
              ],
            ),
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

  /// The old plain countdown number: what shows when the PK animations are off or the file can't be played.
  Widget _plainNumber() => Center(
    child: Text(
      '$_number',
      key: const ValueKey('pk-countdown'),
      style: const TextStyle(fontSize: 120, fontWeight: FontWeight.w900, color: Colors.white, shadows: [Shadow(blurRadius: 24, color: Colors.black87)]),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PkThemeStore.instance,
      builder: (context, _) {
        final theme = PkThemeStore.instance.theme;
        final counting = _number != 0;
        if (!counting && !_burst && !_hero) return const SizedBox.shrink();
        // keys: a layer that ends must not hand its State to the one after it
        return IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (counting && theme.animations) const ColoredBox(key: ValueKey('pk-dim'), color: Color(0x59000000)),
              if (_hero)
                PkSvga(
                  PkAsset.hero,
                  key: const ValueKey('pk-hero'),
                  fit: BoxFit.cover,
                  onFinished: () {
                    if (mounted && _hero) setState(() => _hero = false);
                  },
                ),
              if (_burst)
                PkSvga(
                  PkAsset.versus,
                  key: const ValueKey('pk-burst'),
                  fit: BoxFit.cover,
                  onFinished: () {
                    if (mounted && _burst) setState(() => _burst = false);
                  },
                ),
              if (counting)
                Center(
                  key: const ValueKey('pk-count'),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // the gloves clash while the numbers run (2 s), then the coin counts 3-2-1 (3 s)
                      if (theme.animations) SizedBox(height: 170, child: AspectRatio(aspectRatio: 450 / 600, child: PkSvga(PkAsset.gloves))),
                      SizedBox(width: 200, height: 200, child: PkSvga(PkAsset.countdown, fallback: _plainNumber())),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
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
