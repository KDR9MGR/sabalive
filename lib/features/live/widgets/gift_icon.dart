import 'package:flutter/material.dart' hide Text;

import '../../../core/media/gift_movie_cache.dart';
import '../../../core/widgets/remote_media.dart';
import '../../../data/models.dart';
import '../../../theme/app_colors.dart';
import '../../../core/i18n/text.dart';

/// A gift's picture: the artwork uploaded in the admin panel when there is one
/// (its first frame, for SVGA, MP4 and GIF alike — these sit in a grid),
/// otherwise the emoji.
///
/// While the artwork loads (an SVGA, a picture, a GIF / WebP, an SVG) a quiet empty shape is drawn, NOT the emoji: the emoji is a stand-in the person never asked for (every gift looked like the same
/// little box until its file arrived). The emoji is what shows when the gift has no artwork at all, or when the artwork can't be loaded (offline, a deleted
/// file), so a gift never turns into a hole.
class GiftIcon extends StatefulWidget {
  const GiftIcon(this.gift, {super.key, required this.size});

  final Gift gift;
  final double size;

  @override
  State<GiftIcon> createState() => _GiftIconState();
}

class _GiftIconState extends State<GiftIcon> {
  bool _failed = false;

  @override
  void didUpdateWidget(GiftIcon old) {
    super.didUpdateWidget(old);
    if (old.gift.iconUrl != widget.gift.iconUrl) _failed = false;
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final emoji = Text(widget.gift.emoji, style: TextStyle(fontSize: size));
    final url = widget.gift.iconUrl;
    if (url == null || _failed) return emoji;
    // Artwork fills the tile (an emoji of this font size is far smaller than a
    // picture of the same number), so the animation reads at a glance.
    return SizedBox.square(
      dimension: size * 1.7,
      child: RemoteMedia(
        url,
        fit: BoxFit.contain,
        animate: false,
        // a decoded animation is kept in memory: the sheet draws every tile at once the second time
        svgaLoader: GiftMovieCache.instance.load,
        onError: () {
          if (mounted && !_failed) setState(() => _failed = true);
        },
        // an MP4 tile can be left without a video decoder (only a few stills are held at once) and then stays on its fallback for good: that one keeps the
        // emoji, which is a real answer; every other kind is only loading and gets the quiet shape
        fallback: mediaKindFor(url) == MediaKind.video
            ? Center(child: emoji)
            : Center(
                child: Container(
                  key: const ValueKey('gift-icon-loading'),
                  width: size * 1.1,
                  height: size * 1.1,
                  decoration: BoxDecoration(
                    color: AppColors.stroke.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(size * 0.3),
                  ),
                ),
              ),
      ),
    );
  }
}
