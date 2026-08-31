import 'package:flutter/material.dart';

import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/app_thumb.dart';
import '../../../core/widgets/pills.dart';
import '../../../data/models.dart';
import '../../../theme/app_colors.dart';

/// Grid / list card for a live stream. [aspect] controls the thumbnail shape.
class LiveCard extends StatelessWidget {
  const LiveCard({
    super.key,
    required this.stream,
    required this.onTap,
    this.aspect = 0.82,
    this.rank,
  });

  final LiveStream stream;
  final VoidCallback onTap;
  final double aspect;
  final int? rank;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: AspectRatio(
          aspectRatio: aspect,
          child: AppThumb(
            seed: stream.id + stream.host.name,
            borderRadius: 18,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const LiveBadge(dense: true),
                      const Spacer(),
                      CountChip(
                          icon: Icons.visibility_rounded,
                          label: compactCount(stream.viewers)),
                    ],
                  ),
                  if (rank != null) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        gradient: AppColors.goldGradient,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('#$rank',
                          style: const TextStyle(
                            fontFamily: 'Poppins',
                            fontWeight: FontWeight.w700,
                            fontSize: 10,
                            color: Color(0xFF3A1A5E),
                          )),
                    ),
                  ],
                  const Spacer(),
                  Row(
                    children: [
                      AppAvatar(name: stream.host.name, size: 26),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          stream.host.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Poppins',
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    stream.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: Colors.white.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact horizontal row entry (Trending Now, list feeds).
class LiveListTile extends StatelessWidget {
  const LiveListTile({super.key, required this.stream, required this.onTap, this.rank});

  final LiveStream stream;
  final VoidCallback onTap;
  final int? rank;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 54,
              height: 54,
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: AppThumb(seed: stream.id, borderRadius: 14),
                  ),
                  Positioned(
                    left: 4,
                    top: 4,
                    child: AppAvatar(name: stream.host.name, size: 22),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (rank != null) ...[
                        Text('#$rank ',
                            style: const TextStyle(
                                color: AppColors.gold,
                                fontWeight: FontWeight.w700,
                                fontSize: 13)),
                      ],
                      Flexible(
                        child: Text(
                          stream.host.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Poppins',
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      if (stream.host.verified) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.verified_rounded,
                            size: 13, color: AppColors.primaryBright),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    stream.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const LiveBadge(dense: true),
                const SizedBox(height: 5),
                Row(
                  children: [
                    const Icon(Icons.visibility_rounded,
                        size: 12, color: AppColors.textMuted),
                    const SizedBox(width: 3),
                    Text(compactCount(stream.viewers),
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 11)),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
