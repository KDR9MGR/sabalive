import 'package:flutter/material.dart';

import '../../../core/widgets/remote_media.dart';
import '../../../data/models.dart';

/// A gift's picture: the artwork uploaded in the admin panel when there is one
/// (its first frame — these sit in a grid), otherwise the emoji. The emoji also
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
    return SizedBox.square(
      dimension: size * 1.15,
      child: RemoteMedia(
        url,
        fit: BoxFit.contain,
        animate: false,
        fallback: Center(child: emoji),
      ),
    );
  }
}
