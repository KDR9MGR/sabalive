import 'package:flutter/material.dart';

/// The top of My Profile: the picture on the left with the name, ID and small pills beside it, then the badges / tags and the
/// Wealth / Charm levels across the FULL width under both.
///
/// Why it is laid out like this (owner's screenshot, 2026-11-05): every piece used to sit in one column to the right of the
/// picture. With six badges / tags and the level pictures that column was far taller than the picture, which left a big empty
/// block under it. Only what is short stays beside the picture (the column is centred against it); the wide pieces start at the
/// left edge, under the picture, so nothing is left empty.
class ProfileHeader extends StatelessWidget {
  const ProfileHeader({
    super.key,
    required this.photo,
    required this.name,
    required this.id,
    required this.pills,
    required this.labels,
    required this.levels,
  });

  /// The profile picture with its frame (its own size decides the height of the top row).
  final Widget photo;
  final Widget name;
  final Widget id;

  /// Small chips beside the picture (gender, diamonds): they wrap if the column is narrow.
  final List<Widget> pills;

  /// Badges and staff tags; draws nothing while there are none.
  final Widget labels;

  /// Wealth and Charm level pictures.
  final Widget levels;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            photo,
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  name,
                  const SizedBox(height: 3),
                  id,
                  if (pills.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(spacing: 6, runSpacing: 6, children: pills),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        labels,
        const SizedBox(height: 8),
        levels,
      ],
    );
  }
}
