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
    LiveEmoji(id: 'builtin-12', isGif: false, label: 'Grin', emoji: '😀'),
    LiveEmoji(id: 'builtin-13', isGif: false, label: 'Beam', emoji: '😁'),
    LiveEmoji(id: 'builtin-14', isGif: false, label: 'Roll', emoji: '🤣'),
    LiveEmoji(id: 'builtin-15', isGif: false, label: 'Blush', emoji: '😊'),
    LiveEmoji(id: 'builtin-16', isGif: false, label: 'Adore', emoji: '🥰'),
    LiveEmoji(id: 'builtin-17', isGif: false, label: 'Kiss', emoji: '😘'),
    LiveEmoji(id: 'builtin-18', isGif: false, label: 'Yum', emoji: '😋'),
    LiveEmoji(id: 'builtin-19', isGif: false, label: 'Starstruck', emoji: '🤩'),
    LiveEmoji(id: 'builtin-20', isGif: false, label: 'Celebrate', emoji: '🥳'),
    LiveEmoji(id: 'builtin-21', isGif: false, label: 'Hug', emoji: '🤗'),
    LiveEmoji(id: 'builtin-22', isGif: false, label: 'Think', emoji: '🤔'),
    LiveEmoji(id: 'builtin-23', isGif: false, label: 'Sleepy', emoji: '😴'),
    LiveEmoji(id: 'builtin-24', isGif: false, label: 'Cry', emoji: '😭'),
    LiveEmoji(id: 'builtin-25', isGif: false, label: 'Sad', emoji: '😢'),
    LiveEmoji(id: 'builtin-26', isGif: false, label: 'Angry', emoji: '😡'),
    LiveEmoji(id: 'builtin-27', isGif: false, label: 'Mind blown', emoji: '🤯'),
    LiveEmoji(id: 'builtin-28', isGif: false, label: 'Shock', emoji: '😱'),
    LiveEmoji(id: 'builtin-29', isGif: false, label: 'Please', emoji: '🥺'),
    LiveEmoji(id: 'builtin-30', isGif: false, label: 'Angel', emoji: '😇'),
    LiveEmoji(id: 'builtin-31', isGif: false, label: 'Devil', emoji: '😈'),
    LiveEmoji(id: 'builtin-32', isGif: false, label: 'Shy', emoji: '🙈'),
    LiveEmoji(id: 'builtin-33', isGif: false, label: 'Shh', emoji: '🤫'),
    LiveEmoji(id: 'builtin-34', isGif: false, label: 'Cold', emoji: '🥶'),
    LiveEmoji(id: 'builtin-35', isGif: false, label: 'Rich', emoji: '🤑'),
    LiveEmoji(id: 'builtin-36', isGif: false, label: 'Silly', emoji: '😜'),
    LiveEmoji(id: 'builtin-37', isGif: false, label: 'Like', emoji: '👍'),
    LiveEmoji(id: 'builtin-38', isGif: false, label: 'Dislike', emoji: '👎'),
    LiveEmoji(id: 'builtin-40', isGif: false, label: 'Wave', emoji: '👋'),
    LiveEmoji(id: 'builtin-41', isGif: false, label: 'Peace', emoji: '✌️'),
    LiveEmoji(id: 'builtin-42', isGif: false, label: 'Deal', emoji: '🤝'),
    LiveEmoji(id: 'builtin-43', isGif: false, label: 'Strong', emoji: '💪'),
    LiveEmoji(id: 'builtin-44', isGif: false, label: 'Luck', emoji: '🤞'),
    LiveEmoji(id: 'builtin-45', isGif: false, label: 'OK', emoji: '👌'),
    LiveEmoji(id: 'builtin-46', isGif: false, label: 'Call me', emoji: '🤙'),
    LiveEmoji(id: 'builtin-47', isGif: false, label: 'Hearts', emoji: '💕'),
    LiveEmoji(id: 'builtin-48', isGif: false, label: 'Sparkle heart', emoji: '💖'),
    LiveEmoji(id: 'builtin-49', isGif: false, label: 'Broken heart', emoji: '💔'),
    LiveEmoji(id: 'builtin-50', isGif: false, label: 'Rose', emoji: '🌹'),
    LiveEmoji(id: 'builtin-51', isGif: false, label: 'Star', emoji: '⭐'),
    LiveEmoji(id: 'builtin-52', isGif: false, label: 'Sparkles', emoji: '✨'),
    LiveEmoji(id: 'builtin-53', isGif: false, label: 'Diamond', emoji: '💎'),
    LiveEmoji(id: 'builtin-54', isGif: false, label: 'Crown', emoji: '👑'),
    LiveEmoji(id: 'builtin-55', isGif: false, label: 'Cake', emoji: '🎂'),
    LiveEmoji(id: 'builtin-56', isGif: false, label: 'Gift', emoji: '🎁'),
    LiveEmoji(id: 'builtin-57', isGif: false, label: 'Cheers', emoji: '🍻'),
    LiveEmoji(id: 'builtin-58', isGif: false, label: 'Rocket', emoji: '🚀'),
    LiveEmoji(id: 'builtin-59', isGif: false, label: 'Rainbow', emoji: '🌈'),
    LiveEmoji(id: 'builtin-60', isGif: false, label: 'Dance', emoji: '💃'),
    LiveEmoji(id: 'builtin-61', isGif: false, label: 'Groove', emoji: '🕺'),
    LiveEmoji(id: 'builtin-62', isGif: false, label: 'Mic drop', emoji: '🎤'),
    LiveEmoji(id: 'builtin-63', isGif: false, label: 'Trophy', emoji: '🏆'),
    LiveEmoji(id: 'builtin-64', isGif: false, label: 'Music', emoji: '🎶'),
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
