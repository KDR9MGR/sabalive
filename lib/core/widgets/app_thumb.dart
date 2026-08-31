import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Deterministic gradient thumbnail used for stream previews / covers.
class AppThumb extends StatelessWidget {
  const AppThumb({
    super.key,
    required this.seed,
    this.borderRadius = 18,
    this.icon,
    this.child,
    this.overlayOpacity = 0.28,
  });

  final String seed;
  final double borderRadius;
  final IconData? icon;
  final Widget? child;
  final double overlayOpacity;

  @override
  Widget build(BuildContext context) {
    final h = seed.hashCode.abs();
    final tint = AppColors.tints[h % AppColors.tints.length];
    final align = Alignment(
      ((h >> 3) % 10) / 10 - 0.5,
      ((h >> 7) % 10) / 10 - 0.5,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: align,
                radius: 1.2,
                colors: [tint[0], tint[1], AppColors.bgElevated],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: overlayOpacity + 0.25),
                ],
              ),
            ),
          ),
          if (icon != null)
            Center(
              child: Icon(icon,
                  color: Colors.white.withValues(alpha: 0.85), size: 34),
            ),
          ?child,
        ],
      ),
    );
  }
}
