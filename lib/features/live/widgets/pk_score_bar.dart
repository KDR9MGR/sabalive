import 'package:flutter/material.dart';

import '../../../core/utils/formatters.dart';
import '../../../theme/app_colors.dart';

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

  String get _clock {
    final d = Duration(seconds: secondsLeft.clamp(0, 1 << 30));
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final total = (scoreA + scoreB).clamp(1, 1 << 30);
    final ratioA = scoreA / total;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _tugBar(ratioA),
        const SizedBox(height: 8),
        _scoreRow(),
      ],
    );
  }

  Widget _tugBar(double ratioA) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      return SizedBox(
        height: 26,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Row(children: [
              Expanded(
                flex: (ratioA * 1000).round().clamp(1, 999),
                child: Container(
                  height: 10,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                        colors: [Color(0xFFFF2D55), Color(0xFFFF7A9C)]),
                  ),
                ),
              ),
              Expanded(
                flex: ((1 - ratioA) * 1000).round().clamp(1, 999),
                child: Container(
                  height: 10,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                        colors: [Color(0xFF9CC6FF), Color(0xFF2D6BFF)]),
                  ),
                ),
              ),
            ]),
            const Positioned(
                left: 4,
                child: Text('🥊', style: TextStyle(fontSize: 18))),
            const Positioned(
                right: 4,
                child: Text('🥊', style: TextStyle(fontSize: 18))),
            Positioned(
              left: (w * ratioA - 9).clamp(0.0, w - 18),
              child: const Icon(Icons.diamond_rounded,
                  color: AppColors.primaryBright, size: 18),
            ),
          ],
        ),
      );
    });
  }

  Widget _scoreRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(child: _scorePanel(scoreA, AppColors.live)),
          const SizedBox(width: 8),
          Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  gradient: AppColors.goldGradient,
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
          Expanded(child: _scorePanel(scoreB, AppColors.diamond)),
        ],
      ),
    );
  }

  Widget _scorePanel(int score, Color tint) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          for (final m in const ['🥇', '🥈', '🥉'])
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
          Text(compactCount(score),
              style: const TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: Colors.white)),
        ],
      ),
    );
  }
}
