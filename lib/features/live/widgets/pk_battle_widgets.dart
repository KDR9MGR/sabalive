import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../../../core/i18n/text.dart';
import '../../../core/utils/errors.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/pills.dart';
import '../../../data/models.dart';
import '../../../data/pk_battles_repository.dart';
import '../../../state/pk_battle_controller.dart';
import '../../../theme/app_colors.dart';
import 'pk_score_bar.dart';

/// The PK battle layer's screens (PK as a layer over a normal audio live; see HANDOFF.md "PK battle layer"). Everything here only
/// READS the [PkBattleController]; the server row is the single source of truth.

/// The invite lengths the server offers (`pk_config.invite_durations`), as shown on the chips. A random PK is always 5 minutes.
const List<int> kPkInviteSeconds = [300, 600, 1800, 2400];

String pkLengthLabel(int seconds) => '${seconds ~/ 60} min';

// ---------------------------------------------------------------------------------------------------------------- header
/// The strip above the seats: who the battle is against, the score and the clock. Draws nothing while there is no battle.
class PkBattleHeader extends StatelessWidget {
  const PkBattleHeader({super.key, required this.controller, required this.me});

  final PkBattleController controller;

  /// The host of THIS live (my side, drawn on the left).
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
          case PkPhase.countdown:
            return _battle(c, starting: true);
          case PkPhase.live:
            return _battle(c);
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

  Widget _battle(PkBattleController c, {bool starting = false}) {
    final them = c.opponent;
    return Container(
      key: const ValueKey('pk-battle'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(18)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              AppAvatar(name: me.name, imageUrl: me.avatarUrl, size: 38),
              const SizedBox(width: 8),
              Expanded(child: _name(me.name)),
              if (starting)
                const Text('Starting…', style: TextStyle(color: AppColors.gold, fontSize: 12, fontWeight: FontWeight.w700))
              else
                const Text('PK', style: TextStyle(color: AppColors.gold, fontSize: 13, fontWeight: FontWeight.w800)),
              Expanded(child: _name(them?.name ?? '…', end: true)),
              const SizedBox(width: 8),
              AppAvatar(name: them?.name ?? '?', imageUrl: them?.avatarUrl, size: 38),
            ],
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<int>(
            valueListenable: c.secondsLeft,
            builder: (_, seconds, _) => PkScoreBar(
              scoreA: c.scoreMine,
              scoreB: c.scoreTheirs,
              secondsLeft: starting ? (c.battle?.durationSeconds ?? 0) : seconds,
            ),
          ),
        ],
      ),
    );
  }

  Widget _name(String name, {bool end = false}) => Text(
    name,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    textAlign: end ? TextAlign.end : TextAlign.start,
    style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600),
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
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
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
/// While a battle is live a gift must count for a side: asks "Send to" (this room or the opponent) and sends it through the
/// server's PK gift, once per unit. Returns the side it went to ('a' / 'b'), or null if cancelled or it failed.
Future<String?> sendPkGift(
  BuildContext context,
  PkBattleController c,
  Gift gift,
  int quantity, {
  required String mineLabel,
}) async {
  final battle = c.battle;
  final mine = c.mySide;
  if (battle == null || mine == null || c.phase != PkPhase.live) return null;
  var picked = 0; // 0 = this room, 1 = the opponent
  final theirs = c.opponent?.name ?? 'Opponent';
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (_, setDialog) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('Send to'),
        content: SegmentedTabs(tabs: [mineLabel, theirs], index: picked, onChanged: (i) => setDialog(() => picked = i)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          TextButton(key: const ValueKey('pk-gift-send'), onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Send')),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return null;
  final side = picked == 0 ? mine : (mine == 'a' ? 'b' : 'a');
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
