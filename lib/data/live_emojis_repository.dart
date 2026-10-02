import '../config/supabase_client.dart';

/// One entry of the live-chat emoji / GIF picker — managed from the admin panel
/// (`live_emojis`). A plain emoji is typed into chat as text; a GIF (or other
/// animated sticker: GIF / WebP / SVGA / MP4) is sent as its own chat message.
class LiveEmoji {
  const LiveEmoji({
    required this.id,
    required this.isGif,
    required this.label,
    this.emoji,
    this.assetUrl,
  });

  factory LiveEmoji.fromRow(Map<String, dynamic> row) => LiveEmoji(
    id: row['id'] as String,
    isGif: row['kind'] == 'gif',
    label: row['label'] as String? ?? '',
    emoji: row['emoji'] as String?,
    assetUrl: row['asset_url'] as String?,
  );

  final String id;
  final bool isGif;
  final String label;

  /// The character(s) for a plain emoji; also the stand-in while a GIF loads.
  final String? emoji;
  final String? assetUrl;
}

class LiveEmojisRepository {
  /// What the picker showed before the catalog existed. Used only when the
  /// catalog can't be read at all (offline, or the table isn't there yet) — an
  /// empty catalog the admin left empty on purpose stays empty.
  static const fallback = [
    LiveEmoji(id: 'builtin-0', isGif: false, label: 'Heart', emoji: '❤️'),
    LiveEmoji(id: 'builtin-1', isGif: false, label: 'Fire', emoji: '🔥'),
    LiveEmoji(id: 'builtin-2', isGif: false, label: 'Clap', emoji: '👏'),
    LiveEmoji(id: 'builtin-3', isGif: false, label: 'Laugh', emoji: '😂'),
    LiveEmoji(id: 'builtin-4', isGif: false, label: 'Love', emoji: '😍'),
    LiveEmoji(id: 'builtin-5', isGif: false, label: 'Wow', emoji: '😮'),
    LiveEmoji(id: 'builtin-6', isGif: false, label: 'Like', emoji: '👍'),
    LiveEmoji(id: 'builtin-7', isGif: false, label: 'Party', emoji: '🎉'),
    LiveEmoji(id: 'builtin-8', isGif: false, label: 'Hundred', emoji: '💯'),
    LiveEmoji(id: 'builtin-9', isGif: false, label: 'Sad', emoji: '😢'),
    LiveEmoji(id: 'builtin-10', isGif: false, label: 'Angry', emoji: '😡'),
    LiveEmoji(id: 'builtin-11', isGif: false, label: 'Hooray', emoji: '🙌'),
  ];

  /// The last catalog read, so the picker can open with something on screen
  /// while it refreshes.
  static List<LiveEmoji>? cached;

  Future<List<LiveEmoji>> catalog() async {
    try {
      final rows = await supabase
          .from('live_emojis')
          .select()
          .eq('status', 'active')
          .order('sort_order', ascending: true)
          .order('created_at', ascending: true);
      return cached = [for (final r in rows) LiveEmoji.fromRow(r)];
    } catch (_) {
      return cached ?? fallback;
    }
  }

  /// Sends a GIF from the catalog into a live room's chat. The server looks the
  /// picture up by id, so a client can't make chat show an arbitrary address.
  Future<void> sendGif(String streamId, String emojiId) async {
    await supabase.rpc(
      'send_live_gif',
      params: {'p_stream_id': streamId, 'p_emoji_id': emojiId},
    );
  }
}
