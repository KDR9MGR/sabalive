import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Ambient animated background: slowly drifting coloured glows over the dark
/// base. Used on auth screens and the go-live setup for the "premium vibe".
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, this.child, this.intensity = 1});
  final Widget? child;
  final double intensity;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(gradient: AppColors.heroGlow),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // its own layer: the drifting glow repaints every frame, the screen on top must not
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                final t = _c.value * 2 * math.pi;
                return Stack(
                  children: [
                    _blob(
                      Alignment(0.7 * math.sin(t), -0.8 + 0.15 * math.cos(t)),
                      AppColors.primary,
                      260,
                    ),
                    _blob(
                      Alignment(-0.8 + 0.2 * math.cos(t), 0.2 * math.sin(t)),
                      AppColors.magenta,
                      220,
                    ),
                    _blob(
                      Alignment(0.6 * math.cos(t * 0.8), 0.9),
                      AppColors.primaryDeep,
                      300,
                    ),
                  ],
                );
              },
            ),
          ),
          if (widget.child != null) widget.child!,
        ],
      ),
    );
  }

  // A radial gradient fading to transparent looks the same as the blurred disc it
  // replaces, at a fraction of the cost: a sigma-70 blur re-rasterised three times per
  // frame, for as long as the screen was open, was one of the heaviest things we drew.
  Widget _blob(Alignment align, Color color, double size) {
    final glow = color.withValues(alpha: 0.28 * widget.intensity);
    return Align(
      alignment: align,
      child: IgnorePointer(
        child: Container(
          width: size * 1.7,
          height: size * 1.7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                glow,
                glow.withValues(alpha: glow.a * 0.45),
                glow.withValues(alpha: 0),
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
          ),
        ),
      ),
    );
  }
}
