import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;

import '../../../core/widgets/remote_media.dart';
import '../../../data/live_emojis_repository.dart';
import '../../../theme/app_colors.dart';
import '../../../core/i18n/text.dart';

/// The emote picker for live chat (audio rooms, video lives, the host's
/// own screen). Its contents come from the admin panel, so adding, editing or
/// removing an entry there changes what everyone sees here. A picked emote plays over the
/// sender's picture circle in the room (see emote_overlay.dart).
Future<LiveEmoji?> showLiveEmojiSheet(BuildContext context) {
  return showModalBottomSheet<LiveEmoji>(
    context: context,
    backgroundColor: AppColors.bgElevated,
    isScrollControlled: true,
    builder: (_) => const _LiveEmojiSheet(),
  );
}

class _LiveEmojiSheet extends StatelessWidget {
  const _LiveEmojiSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.5,
        ),
        child: FutureBuilder<List<LiveEmoji>>(
          future: LiveEmojisRepository().catalog(),
          initialData: LiveEmojisRepository.cached,
          builder: (context, snap) {
            final items = snap.data;
            if (items == null) {
              return const SizedBox(
                height: 160,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (items.isEmpty) {
              return const SizedBox(
                height: 120,
                child: Center(
                  child: Text(
                    'No emotes available right now',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ),
              );
            }
            // one grid, in the panel's order: plain emoji and the animated ones (GIF / WebP / SVGA) sit together and all of them move
            return _EmojiGrid(items);
          },
        ),
      ),
    );
  }
}

/// How a plain emoji moves in the picker: a gentle bob, a sway and a little breathing, on a loop. [t] is the shared loop position (0..1) and [index] puts each tile
/// a little out of step with its neighbours, so the grid ripples instead of pulsing in unison. Periodic: the value at 0 and at 1 is the same, so the loop has no jump.
({double dy, double angle, double scale}) emojiMotion(double t, int index) {
  final p = (t + (index * 0.137) % 1.0) * 2 * math.pi;
  return (dy: -3.0 * (0.5 + 0.5 * math.sin(p)), angle: 0.12 * math.sin(p + math.pi / 2), scale: 1 + 0.07 * math.sin(p * 2));
}

class _EmojiGrid extends StatefulWidget {
  const _EmojiGrid(this.items);
  final List<LiveEmoji> items;

  @override
  State<_EmojiGrid> createState() => _EmojiGridState();
}

class _EmojiGridState extends State<_EmojiGrid> with SingleTickerProviderStateMixin {
  // ONE loop for the whole grid (not one per tile): every plain emoji reads its own phase from it
  late final AnimationController _loop = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // "remove animations" in the phone's accessibility settings keeps the picker still
    if (MediaQuery.disableAnimationsOf(context)) {
      _loop.stop();
    } else if (!_loop.isAnimating) {
      _loop.repeat();
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  Widget _glyph(LiveEmoji e, int i, {double size = 28}) {
    final label = Text(e.emoji ?? e.label, style: TextStyle(fontSize: size, height: 1));
    return AnimatedBuilder(
      animation: _loop,
      child: label,
      builder: (context, child) {
        final m = emojiMotion(_loop.value, i);
        return Transform.translate(
          offset: Offset(0, m.dy),
          child: Transform.rotate(angle: m.angle, child: Transform.scale(scale: m.scale, child: child)),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      shrinkWrap: true,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 5, mainAxisSpacing: 8, crossAxisSpacing: 8),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final e = items[i];
        final animated = e.isGif && e.assetUrl != null && e.assetUrl!.isNotEmpty;
        return GestureDetector(
          key: ValueKey(animated ? 'gif-${e.id}' : 'emoji-${e.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.pop(context, e),
          child: Center(
            child: animated
                ? Padding(
                    padding: const EdgeInsets.all(4),
                    child: RemoteMedia(
                      e.assetUrl!,
                      fit: BoxFit.contain,
                      loop: true,
                      // GIF / WebP / SVGA play right here; a video file would need a player per tile, so it keeps its first picture (the emoji) until it is sent
                      animate: mediaKindFor(e.assetUrl!) != MediaKind.video,
                      fallback: Center(child: _glyph(e, i, size: 24)),
                    ),
                  )
                : _glyph(e, i),
          ),
        );
      },
    );
  }
}
