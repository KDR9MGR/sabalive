import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// SABALIVE brand crest. [size] is the rendered height in logical pixels;
/// width follows the artwork's aspect ratio.
class SabaLogo extends StatelessWidget {
  const SabaLogo({
    super.key,
    this.size = 44,
    this.showTagline = false,
    this.glow = true,
  });

  final double size;
  final bool showTagline;
  final bool glow;

  static const String asset = 'assets/images/sabalive_logo.png';

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: glow
              ? BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.35),
                      blurRadius: size * 0.7,
                      spreadRadius: size * 0.02,
                    ),
                    BoxShadow(
                      color: AppColors.gold.withValues(alpha: 0.18),
                      blurRadius: size * 0.9,
                    ),
                  ],
                )
              : const BoxDecoration(),
          child: Image.asset(
            asset,
            height: size,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          ),
        ),
        if (showTagline) ...[
          SizedBox(height: size * 0.18),
          Text(
            'Go Live. Be a Star!',
            style: TextStyle(
              fontFamily: 'Poppins',
              fontWeight: FontWeight.w600,
              fontSize: size * 0.24,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ],
    );
  }
}
