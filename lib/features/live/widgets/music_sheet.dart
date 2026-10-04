import 'package:flutter/material.dart' hide Text;

import '../../../services/local_music_service.dart';
import '../../../theme/app_colors.dart';
import '../../../core/i18n/text.dart';

/// Pick songs from the phone and control playback, in a live room.
Future<void> showMusicSheet(BuildContext context, LocalMusicController music) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.bgElevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _MusicSheet(music: music),
  );
}

class _MusicSheet extends StatelessWidget {
  const _MusicSheet({required this.music});

  final LocalMusicController music;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: music,
        builder: (context, _) {
          final current = music.current;
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.music_note_rounded, color: AppColors.pink),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('Play music',
                          style: TextStyle(
                              fontFamily: 'Poppins',
                              fontWeight: FontWeight.w700,
                              fontSize: 16)),
                    ),
                    TextButton.icon(
                      onPressed: music.pick,
                      icon: const Icon(Icons.library_music_rounded, size: 18),
                      label: const Text('Choose songs'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Songs from your phone, played into your audio room. Keep your '
                  'mic on while music plays — the music goes out with your voice.',
                  style: TextStyle(
                      fontSize: 11.5, color: AppColors.textMuted, height: 1.4),
                ),
                if (music.error != null) ...[
                  const SizedBox(height: 8),
                  Text(music.error!,
                      style: const TextStyle(
                          color: AppColors.danger, fontSize: 12)),
                ],
                const SizedBox(height: 14),
                if (current == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Center(
                      child: Text('No song playing',
                          style: TextStyle(color: AppColors.textMuted)),
                    ),
                  )
                else ...[
                  Text(current.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(
                    music.starting
                        ? 'Starting…'
                        : music.paused
                            ? 'Paused'
                            : music.playing
                                ? 'Playing — the room can hear it'
                                : 'Stopped',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: music.playing && !music.paused
                          ? AppColors.success
                          : AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        onPressed: music.index > 0 ? music.previous : null,
                        icon: const Icon(Icons.skip_previous_rounded),
                      ),
                      IconButton(
                        iconSize: 40,
                        onPressed: music.paused ? music.resume : music.pause,
                        icon: Icon(music.paused
                            ? Icons.play_circle_fill_rounded
                            : Icons.pause_circle_filled_rounded),
                      ),
                      IconButton(
                        onPressed: music.index + 1 < music.queue.length
                            ? music.next
                            : null,
                        icon: const Icon(Icons.skip_next_rounded),
                      ),
                      IconButton(
                        onPressed: music.stop,
                        icon: const Icon(Icons.stop_rounded,
                            color: AppColors.danger),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Icon(Icons.volume_down_rounded, size: 18),
                      Expanded(
                        child: Slider(
                          value: music.volume.toDouble(),
                          min: 0,
                          max: 100,
                          onChanged: (v) => music.setVolume(v.round()),
                        ),
                      ),
                      const Icon(Icons.volume_up_rounded, size: 18),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Only I can hear it',
                        style: TextStyle(fontSize: 13)),
                    value: music.onlyMe,
                    onChanged: music.setOnlyMe,
                  ),
                  if (music.queue.length > 1) ...[
                    const Divider(),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 160),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: music.queue.length,
                        itemBuilder: (_, i) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            i == music.index
                                ? Icons.graphic_eq_rounded
                                : Icons.music_note_outlined,
                            size: 18,
                            color: i == music.index ? AppColors.pink : null,
                          ),
                          title: Text(music.queue[i].name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ),
                  ],
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
