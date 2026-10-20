import 'package:flutter/material.dart';

import '../../../state/pk_theme_store.dart';
import '../../../theme/app_colors.dart';
import 'pk_svga.dart';

/// The tug-of-war bar of a PK battle: my share of the points from the start side, theirs from the other, the shield where they meet,
/// a sword at each end. The same bar serves the audio arena ([PkScoreBar]) and the video stage ([PkThinBar]), so the two can never
/// look different.
///
/// With the PK animations on, each side is the bundled striped bar (clipped to its share, so the stripes keep moving) in the side's
/// colour from the panel. With them off, or if a file can't be played, it is the plain gradient bar and diamond the app always had.
///
/// Nothing is drawn from the phone's own clock or a guess: [scoreA] / [scoreB] are the server's scores. Equal scores (a battle that
/// has just begun) put the meeting point in the middle.
class PkTugBar extends StatelessWidget {
  const PkTugBar({super.key, required this.scoreA, required this.scoreB, this.barHeight = 14, this.badgeSize = 38});

  final int scoreA;
  final int scoreB;

  /// How thick the bar is, and how big the shield and the swords are (the swords are a little smaller than the shield).
  final double barHeight;
  final double badgeSize;

  double get _ratio {
    final total = scoreA + scoreB;
    return total <= 0 ? 0.5 : (scoreA / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final sword = badgeSize * 0.8;
    return ListenableBuilder(
      listenable: PkThemeStore.instance,
      builder: (context, _) {
        final theme = PkThemeStore.instance.theme;
        return SizedBox(
          height: badgeSize,
          child: Row(
            children: [
              SizedBox(width: sword, height: sword, child: PkSvga(PkAsset.sword(PkTeam.mine, rtl: rtl), loop: true, team: PkTeam.mine, fallback: const _GloveFallback())),
              const SizedBox(width: 2),
              Expanded(
                child: TweenAnimationBuilder<double>(
                  key: const ValueKey('pk-tug'),
                  // the bar slides to a new share instead of jumping when a gift lands
                  tween: Tween<double>(end: _ratio),
                  duration: const Duration(milliseconds: 380),
                  curve: Curves.easeOutCubic,
                  builder: (context, ratio, _) => _bar(theme, ratio),
                ),
              ),
              const SizedBox(width: 2),
              SizedBox(width: sword, height: sword, child: PkSvga(PkAsset.sword(PkTeam.theirs, rtl: rtl), loop: true, team: PkTeam.theirs, fallback: const _GloveFallback())),
            ],
          ),
        );
      },
    );
  }

  Widget _bar(PkTheme theme, double ratio) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final mineWidth = (w * ratio).clamp(0.0, w);
        final badge = PkSvga(
          PkAsset.badge,
          loop: true,
          fallback: Icon(Icons.diamond_rounded, color: AppColors.primaryBright, size: badgeSize * 0.5),
        );
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(barHeight / 2),
              child: SizedBox(
                height: barHeight,
                width: w,
                child: Stack(
                  children: [
                    const Positioned.fill(child: ColoredBox(color: Color(0x40000000))),
                    PositionedDirectional(start: 0, top: 0, bottom: 0, width: mineWidth, child: _side(PkTeam.mine, theme, w, AlignmentDirectional.centerStart)),
                    PositionedDirectional(end: 0, top: 0, bottom: 0, width: w - mineWidth, child: _side(PkTeam.theirs, theme, w, AlignmentDirectional.centerEnd)),
                  ],
                ),
              ),
            ),
            // the shield sits on the meeting point and may stand out above and below the bar
            PositionedDirectional(
              start: (mineWidth - badgeSize / 2).clamp(0.0, (w - badgeSize).clamp(0.0, w)),
              child: SizedBox(key: const ValueKey('pk-tug-badge'), width: badgeSize, height: badgeSize, child: badge),
            ),
          ],
        );
      },
    );
  }

  /// One side's share of the bar: the full-width striped bar, shown through a window as wide as the side's share.
  Widget _side(PkTeam team, PkTheme theme, double fullWidth, AlignmentGeometry alignment) {
    return ClipRect(
      child: OverflowBox(
        alignment: alignment,
        minWidth: fullWidth,
        maxWidth: fullWidth,
        child: PkSvga(
          PkAsset.bar(team),
          loop: true,
          team: team,
          fit: BoxFit.fill,
          fallback: DecoratedBox(
            decoration: BoxDecoration(gradient: LinearGradient(colors: theme.barColors(team))),
            child: SizedBox(width: fullWidth, height: barHeight),
          ),
        ),
      ),
    );
  }
}

/// What stands at the end of the bar when the sword animation is off: the boxing glove the bar always had.
class _GloveFallback extends StatelessWidget {
  const _GloveFallback();

  @override
  Widget build(BuildContext context) => const FittedBox(child: Text('🥊'));
}
