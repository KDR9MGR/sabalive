import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../../../core/utils/formatters.dart';
import '../../../data/lucky_box_repository.dart';
import '../../../theme/app_colors.dart';
import '../../../core/i18n/text.dart';

/// The Lucky Box on the host's live screen: a gift box with the time left
/// until the reward under it. Counts down using the panel's settings
/// (re-read every minute, so a panel change shows up without a restart),
/// then shows "Opening…" until the server pays out, then the diamonds won.
/// Shows nothing if the settings can't be read — it's a bonus, never an error.
class LuckyBoxBadge extends StatefulWidget {
  const LuckyBoxBadge({
    super.key,
    required this.streamId,
    this.repo,
    this.now,
    this.configRefresh = const Duration(minutes: 1),
    this.rewardCheck = const Duration(seconds: 10),
  });

  final String streamId;

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
  LuckyBoxConfig? _config;
  DateTime? _startedAt;
  int? _reward;
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
  }

  @override
  void dispose() {
    _tick?.cancel();
    _refresh?.cancel();
    _rewardTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final started = await _repo.streamStartedAt(widget.streamId);
      final config = await _repo.config();
      final reward = await _repo.rewardGranted(widget.streamId);
      if (!mounted) return;
      setState(() {
        _startedAt = started;
        _config = config;
        _reward = reward;
        _failed = started == null;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _loadConfig() async {
    try {
      final c = await _repo.config();
      if (mounted) setState(() => _config = c);
    } catch (_) {/* keep showing the last known settings */}
  }

  Future<void> _checkReward() async {
    if (_reward != null || _startedAt == null || _config == null) return;
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
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('Lucky Box'),
        content: Text(won != null
            ? 'You won ${withThousands(won)} diamonds from this live. '
                'Well done!'
            : 'Stay live for ${c.durationMinutes} minutes without a break in '
                'this stream and win ${withThousands(c.rewardDiamonds)} diamonds.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
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
    final p = luckyBoxProgress(
      startedAt: started,
      duration: config.duration,
      now: _now(),
      rewardPaid: _reward,
    );
    final opened = p.phase == LuckyBoxPhase.opened;
    final label = switch (p.phase) {
      LuckyBoxPhase.counting => luckyBoxClock(p.remaining),
      LuckyBoxPhase.opening => 'Opening…',
      LuckyBoxPhase.opened => '+${withThousands(p.reward!)}',
    };

    return GestureDetector(
      onTap: () => _explain(config),
      behavior: HitTestBehavior.opaque,
      child: Semantics(
        label: opened
            ? 'Lucky Box opened, won ${p.reward} diamonds'
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
                  if (opened) ...[
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
