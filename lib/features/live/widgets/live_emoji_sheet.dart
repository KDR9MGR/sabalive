import 'package:flutter/material.dart' hide Text;

import '../../../core/widgets/remote_media.dart';
import '../../../data/live_emojis_repository.dart';
import '../../../theme/app_colors.dart';
import '../../../core/i18n/text.dart';

/// The emoji / GIF picker for live chat (audio rooms, video lives, the host's
/// own screen). Its contents come from the admin panel, so adding, editing or
/// removing an entry there changes what everyone sees here.
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
                    'No emojis available right now',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ),
              );
            }
            final emojis = [for (final e in items) if (!e.isGif) e];
            final gifs = [for (final e in items) if (e.isGif) e];
            return DefaultTabController(
              length: gifs.isEmpty ? 1 : 2,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (gifs.isNotEmpty)
                    TabBar(
                      tabs: [Tab(text: tr('Emoji')), Tab(text: tr('GIFs'))],
                    ),
                  Flexible(
                    child: gifs.isEmpty
                        ? _EmojiGrid(emojis)
                        : TabBarView(
                            children: [_EmojiGrid(emojis), _GifGrid(gifs)],
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _EmojiGrid extends StatelessWidget {
  const _EmojiGrid(this.items);
  final List<LiveEmoji> items;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      padding: const EdgeInsets.all(16),
      crossAxisCount: 6,
      shrinkWrap: true,
      children: [
        for (final e in items)
          GestureDetector(
            key: ValueKey('emoji-${e.id}'),
            onTap: () => Navigator.pop(context, e),
            child: Center(
              child: Text(e.emoji ?? '', style: const TextStyle(fontSize: 26)),
            ),
          ),
      ],
    );
  }
}

class _GifGrid extends StatelessWidget {
  const _GifGrid(this.items);
  final List<LiveEmoji> items;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      padding: const EdgeInsets.all(16),
      crossAxisCount: 4,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      shrinkWrap: true,
      children: [
        for (final e in items)
          GestureDetector(
            key: ValueKey('gif-${e.id}'),
            onTap: () => Navigator.pop(context, e),
            child: RemoteMedia(
              e.assetUrl!,
              fit: BoxFit.contain,
              // a still frame for SVGA; GIF / WebP animate on their own
              animate: false,
              fallback: Center(
                child: Text(
                  e.emoji ?? e.label,
                  style: const TextStyle(fontSize: 22),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
