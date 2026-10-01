import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../utils/formatters.dart';

/// Shows the user's real uploaded photo when [imageUrl] is set; otherwise
/// falls back to a deterministic gradient with initials, keeping every user
/// visually distinct even with no photo.
class AppAvatar extends StatelessWidget {
  const AppAvatar({
    super.key,
    required this.name,
    this.size = 44,
    this.ring = false,
    this.ringColor,
    this.live = false,
    this.imageUrl,
  });

  final String name;
  final double size;
  final bool ring;
  final Color? ringColor;
  final bool live;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final tint = AppColors.tints[name.hashCode.abs() % AppColors.tints.length];
    final hasPhoto = imageUrl != null && imageUrl!.isNotEmpty;
    final avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: hasPhoto
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: tint,
              ),
        image: hasPhoto
            ? DecorationImage(
                image: NetworkImage(imageUrl!),
                fit: BoxFit.cover,
              )
            : null,
        border: ring
            ? Border.all(
                color: ringColor ?? AppColors.gold,
                width: size * 0.05 + 1.2,
              )
            : null,
      ),
      alignment: Alignment.center,
      child: hasPhoto
          ? null
          : Text(
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
