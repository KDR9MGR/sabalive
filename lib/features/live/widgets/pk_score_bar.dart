import 'package:flutter/material.dart' hide Text;

import '../../../core/utils/formatters.dart';
import '../../../state/pk_theme_store.dart';
import '../../../theme/app_colors.dart';
import '../../../core/i18n/text.dart';
import 'pk_tug_bar.dart';

/// "04:12" for a number of seconds (never negative).
String pkClock(int seconds) {
  final d = Duration(seconds: seconds.clamp(0, 1 << 30));
  final m = d.inMinutes.toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// The slim two-colour bar of the video PK stage: my share of the points on one side, theirs on the other, the shield where they meet
/// (the same [PkTugBar] the audio arena shows, only thinner).
class PkThinBar extends StatelessWidget {
  const PkThinBar({super.key, required this.scoreA, required this.scoreB});
  final int scoreA;
  final int scoreB;

  @override
  Widget build(BuildContext context) => PkTugBar(scoreA: scoreA, scoreB: scoreB, barHeight: 9, badgeSize: 28);
}

/// The tug-of-war bar + score panels + VS badge + countdown clock. Shared by
/// the host's own PK screen (pk_battle_screen.dart, the source of truth for
/// these numbers) and the viewer's PK screen (watch_pk_battle_screen.dart,
/// which mirrors them via a Realtime broadcast) — one visual, one place it's
/// built, so the two can never drift apart.
class PkScoreBar extends StatelessWidget {
  const PkScoreBar({
    super.key,
    required this.scoreA,
    required this.scoreB,
    required this.secondsLeft,
  });
  final int scoreA;
  final int scoreB;
  final int secondsLeft;

  String get _clock => pkClock(secondsLeft);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PkThemeStore.instance,
      builder: (context, _) {
        final theme = PkThemeStore.instance.theme;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PkTugBar(scoreA: scoreA, scoreB: scoreB, barHeight: 14, badgeSize: 40),
            const SizedBox(height: 2),
            _scoreRow(theme),
          ],
        );
      },
    );
  }

  Widget _scoreRow(PkTheme theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(child: _scorePanel(scoreA, theme.mine)),
          const SizedBox(width: 8),
          Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  gradient: theme.accentGradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text('VS',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 11,
                        color: Color(0xFF3A1A5E))),
              ),
              const SizedBox(height: 3),
              Text(_clock,
                  style: const TextStyle(fontSize: 11, color: Colors.white70)),
            ],
          ),
          const SizedBox(width: 8),
          Expanded(child: _scorePanel(scoreB, theme.theirs)),
        ],
      ),
    );
  }

  /// One side's score panel. Three medals fit only when the panel is wide (the PK layer's header leaves a narrow room on a small
  /// phone); narrower panels show fewer medals and always keep the score.
  Widget _scorePanel(int score, Color tint) {
    return LayoutBuilder(builder: (context, box) {
      final medals = box.maxWidth >= 150 ? 3 : (box.maxWidth >= 118 ? 1 : 0);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: tint.withValues(alpha: 0.45)),
        ),
        child: Row(
          children: [
            for (final m in const ['🥇', '🥈', '🥉'].take(medals))
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                  child: Text(m, style: const TextStyle(fontSize: 11)),
                ),
              ),
            const Spacer(),
            const Icon(Icons.diamond_rounded, size: 12, color: AppColors.diamond),
            const SizedBox(width: 3),
            Flexible(
              child: Text(compactCount(score),
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      color: Colors.white)),
            ),
          ],
        ),
      );
    });
  }
}
