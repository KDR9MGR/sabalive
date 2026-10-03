import 'package:flutter/material.dart';

import '../../../core/widgets/remote_media.dart';
import '../../../data/models.dart';

/// A gift's picture: the artwork uploaded in the admin panel when there is one
/// (its first frame, for SVGA, MP4 and GIF alike — these sit in a grid),
/// otherwise the emoji. The emoji also
/// shows while the artwork loads and if it can't be loaded.
class GiftIcon extends StatelessWidget {
  const GiftIcon(this.gift, {super.key, required this.size});

  final Gift gift;
  final double size;

  @override
  Widget build(BuildContext context) {
    final emoji = Text(gift.emoji, style: TextStyle(fontSize: size));
    final url = gift.iconUrl;
    if (url == null) return emoji;
    // Artwork fills the tile (an emoji of this font size is far smaller than a
    // picture of the same number), so the animation reads at a glance.
    return SizedBox.square(
      dimension: size * 1.7,
      child: RemoteMedia(
        url,
        fit: BoxFit.contain,
        animate: false,
        fallback: Center(child: emoji),
      ),
    );
  }
}
