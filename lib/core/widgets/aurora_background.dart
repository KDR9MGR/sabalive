import 'dart:math' as math;
import 'dart:ui';

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
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 18))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: AppColors.heroGlow),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = _c.value * 2 * math.pi;
              return Stack(
                children: [
                  _blob(Alignment(0.7 * math.sin(t), -0.8 + 0.15 * math.cos(t)),
                      AppColors.primary, 260),
                  _blob(Alignment(-0.8 + 0.2 * math.cos(t), 0.2 * math.sin(t)),
                      AppColors.magenta, 220),
                  _blob(Alignment(0.6 * math.cos(t * 0.8), 0.9),
                      AppColors.primaryDeep, 300),
                ],
              );
            },
          ),
          if (widget.child != null) widget.child!,
        ],
      ),
    );
  }

  Widget _blob(Alignment align, Color color, double size) {
    return Align(
      alignment: align,
      child: IgnorePointer(
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.28 * widget.intensity),
            ),
          ),
        ),
      ),
    );
  }
}
