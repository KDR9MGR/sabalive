import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../utils/formatters.dart';

/// Deterministic gradient avatar with initials. Keeps the app fully offline
/// while still giving every user a distinct, colourful identity.
class AppAvatar extends StatelessWidget {
  const AppAvatar({
    super.key,
    required this.name,
    this.size = 44,
    this.ring = false,
    this.ringColor,
    this.live = false,
  });

  final String name;
  final double size;
  final bool ring;
  final Color? ringColor;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final tint = AppColors.tints[name.hashCode.abs() % AppColors.tints.length];
    final avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: tint,
        ),
        border: ring
            ? Border.all(
                color: ringColor ?? AppColors.gold,
                width: size * 0.05 + 1.2,
              )
            : null,
      ),
      alignment: Alignment.center,
      child: Text(
        initialsOf(name),
        style: TextStyle(
          fontFamily: 'Poppins',
          fontWeight: FontWeight.w600,
          fontSize: size * 0.38,
          color: Colors.white,
        ),
      ),
    );

    if (!live) return avatar;

    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.bottomCenter,
      children: [
        avatar,
        Positioned(
          bottom: -size * 0.12,
          child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: size * 0.14, vertical: size * 0.02),
            decoration: BoxDecoration(
              gradient: AppColors.liveGradient,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.bg, width: 1.5),
            ),
            child: Text(
              'LIVE',
              style: TextStyle(
                fontFamily: 'Poppins',
                fontWeight: FontWeight.w700,
                fontSize: size * 0.18,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
