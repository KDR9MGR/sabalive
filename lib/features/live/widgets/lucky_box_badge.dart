import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../../../core/utils/formatters.dart';
import '../../../data/lucky_box_repository.dart';
import '../../../theme/app_colors.dart';
import '../../../core/i18n/text.dart';

/// The Lucky Box on a video live: a gift box with the time left until the
/// reward under it. Counts down using the panel's settings (re-read every
/// minute, so a panel change shows up without a restart), then shows
/// "Opening…" until the server pays out, then the diamonds won.
///
/// The host sees their own reward. A viewer ([forViewer]) sees the same box and
/// countdown, and "Opened" when the time is up; the reward is the host's, so a
/// viewer's wallet and the amount are never looked up.
///
/// Shows nothing while the settings can't be read — it's a bonus, never an
/// error — and keeps trying in the background, so it appears once the network does.
class LuckyBoxBadge extends StatefulWidget {
  const LuckyBoxBadge({
    super.key,
    required this.streamId,
    this.forViewer = false,
    this.repo,
    this.now,
    this.configRefresh = const Duration(minutes: 1),
    this.rewardCheck = const Duration(seconds: 10),
    this.retryEvery = const Duration(seconds: 15),
  });

  final String streamId;

  /// Watching someone else's live: no reward lookup, wording about the host.
  final bool forViewer;

  /// How often a failed first load is tried again.
  final Duration retryEvery;

  /// Injectable for tests.
  final LuckyBoxRepository? repo;
  final DateTime Function()? now;
  final Duration configRefresh;
  final Duration rewardCheck;

  @override
  State<LuckyBoxBadge> createState() => _LuckyBoxBadgeState();
}

class _LuckyBoxBadgeState extends State<LuckyBoxBadge> {
  late final LuckyBoxRepository _repo = widget.repo ?? LuckyBoxRepository();
  Timer? _tick;
  Timer? _refresh;
  Timer? _rewardTimer;
  Timer? _retry;
  bool _loading = false;
  LuckyBoxConfig? _config;
  DateTime? _startedAt;
  int? _reward;
  LuckyBoxStatus? _status;
  bool _failed = false;

  DateTime _now() => (widget.now ?? DateTime.now)().toUtc();

  @override
  void initState() {
    super.initState();
    _load();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _refresh = Timer.periodic(widget.configRefresh, (_) => _loadConfig());
    _rewardTimer = Timer.periodic(widget.rewardCheck, (_) => _checkReward());
    // the first load can fail (no network yet): keep trying until it works
    _retry = Timer.periodic(widget.retryEvery, (_) {
      if (_failed || _config == null || _startedAt == null) _load();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _refresh?.cancel();
    _rewardTimer?.cancel();
    _retry?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final started = await _repo.streamStartedAt(widget.streamId);
      final config = await _repo.config();
      final reward = widget.forViewer ? null : await _repo.rewardGranted(widget.streamId);
      final status = await _repo.status(widget.streamId);
      if (!mounted) return;
      setState(() {
        _startedAt = started;
        _config = config;
        _reward = reward;
        _status = status;
        _failed = started == null;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      _loading = false;
    }
  }

  Future<void> _loadConfig() async {
    try {
      final c = await _repo.config();
      final s = await _repo.status(widget.streamId);
      if (mounted) {
        setState(() {
          _config = c;
          _status = s ?? _status;
        });
      }
    } catch (_) {/* keep showing the last known settings */}
  }

  Future<void> _checkReward() async {
    if (widget.forViewer || _reward != null || _startedAt == null || _config == null) return;
    // only worth asking once the countdown is over
    final p = luckyBoxProgress(
      startedAt: _startedAt!,
      duration: _config!.duration,
      now: _now(),
    );
    if (p.phase == LuckyBoxPhase.counting) return;
    try {
      final r = await _repo.rewardGranted(widget.streamId);
      if (mounted && r != null) setState(() => _reward = r);
    } catch (_) {}
  }

  void _explain(LuckyBoxConfig c) {
    final won = _reward;
    final String message;
    if (widget.forViewer) {
      message = 'The host wins ${withThousands(c.rewardDiamonds)} diamonds '
          'for staying live ${c.durationMinutes} minutes without a break. '
          'The box opens when the time is up.';
    } else if (won != null) {
      message = 'You won ${withThousands(won)} diamonds from this live. Well done!';
    } else {
      message = 'Stay live for ${c.durationMinutes} minutes without a break in '
          'this stream and win ${withThousands(c.rewardDiamonds)} diamonds.';
    }
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('Lucky Box'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// The host's box while it is resting: grey, with how long until a NEW live can earn again.
  Widget _restingBox(LuckyBoxConfig c, DateTime restUntil) {
    final left = restUntil.difference(_now());
    final label = left <= Duration.zero ? 'New live' : 'Next in ${luckyBoxRestLabel(left)}';
    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppColors.bgElevated,
          title: const Text('Lucky Box'),
          content: Text(
            left <= Duration.zero
                ? 'The rest is over. Start a new live and stay on for ${c.durationMinutes} minutes without a '
                    'break to earn the next box.'
                : 'You already earned a Lucky Box in the last ${c.cooldownHours} hours, so this live will not '
                    'open one. Start a new live in ${luckyBoxRestLabel(left)} (and stay on for '
                    '${c.durationMinutes} minutes) to earn the next one.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
          ],
        ),
      ),
      behavior: HitTestBehavior.opaque,
      child: Semantics(
        label: 'Lucky Box resting, $label',
        excludeSemantics: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.card_giftcard_rounded, color: Colors.white54, size: 26),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                label,
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                  color: Colors.white70,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    final started = _startedAt;
    if (_failed || config == null || started == null) {
      return const SizedBox.shrink();
    }
    // A host paid within the cooldown: this live's box will not open. A viewer is shown nothing to wait for;
    // the host is shown that the box is resting and when a new live can earn again.
    final rest = _status?.restUntil;
    final paidHere = _reward != null || (_status?.paid ?? false);
    if (rest != null && !paidHere) {
      if (widget.forViewer) return const SizedBox.shrink();
      return _restingBox(config, rest);
    }
    final p = luckyBoxProgress(
      startedAt: started,
      duration: config.duration,
      now: _now(),
      rewardPaid: _reward,
      pastDeadlineMeansOpened: widget.forViewer,
      paidWithoutAmount: _status?.paid ?? false,
    );
    final opened = p.phase == LuckyBoxPhase.opened;
    final label = switch (p.phase) {
      LuckyBoxPhase.counting => luckyBoxClock(p.remaining),
      LuckyBoxPhase.opening => 'Opening…',
      LuckyBoxPhase.opened => p.reward == null ? 'Opened' : '+${withThousands(p.reward!)}',
    };

    return GestureDetector(
      onTap: () => _explain(config),
      behavior: HitTestBehavior.opaque,
      child: Semantics(
        label: opened
            ? (p.reward == null ? 'Lucky Box opened' : 'Lucky Box opened, won ${p.reward} diamonds')
            : 'Lucky Box, $label',
        excludeSemantics: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.gold, AppColors.goldDeep],
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.gold.withValues(alpha: opened ? 0.7 : 0.4),
                    blurRadius: opened ? 16 : 10,
                  ),
                ],
              ),
              child: Icon(
                opened ? Icons.celebration_rounded : Icons.card_giftcard_rounded,
                color: Colors.white,
                size: 26,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                      color: Colors.white,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (opened && p.reward != null) ...[
                    const SizedBox(width: 3),
                    const Icon(Icons.diamond_rounded,
                        size: 11, color: AppColors.diamond),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
