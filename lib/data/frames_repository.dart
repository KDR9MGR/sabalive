import '../config/supabase_client.dart';

/// One avatar frame from the panel's Profile Frame catalog (`frames`), with
/// whether the signed-in user owns / wears it.
class ProfileFrame {
  const ProfileFrame({
    required this.id,
    required this.name,
    required this.emoji,
    required this.unlockType,
    required this.unlockValue,
    required this.priceCoins,
    this.iconUrl,
    this.owned = false,
    this.equipped = false,
  });

  factory ProfileFrame.fromRow(
    Map<String, dynamic> row, {
    bool owned = false,
    bool equipped = false,
  }) {
    final icon = (row['icon_url'] as String?)?.trim();
    return ProfileFrame(
      id: row['id'] as String,
      name: row['name'] as String? ?? 'Frame',
      emoji: row['emoji'] as String? ?? '🖼️',
      unlockType: row['unlock_type'] as String? ?? 'free',
      unlockValue: (row['unlock_value'] as num?)?.toInt() ?? 0,
      priceCoins: (row['price_coins'] as num?)?.toInt() ?? 0,
      iconUrl: icon == null || icon.isEmpty ? null : icon,
      owned: owned,
      equipped: equipped,
    );
  }

  final String id;
  final String name;
  final String emoji;

  /// free | level | vip | coins | event
  final String unlockType;
  final int unlockValue;
  final int priceCoins;
  final String? iconUrl;
  final bool owned;
  final bool equipped;
}

/// What the Frames screen offers for one frame.
enum FrameActionKind { remove, equip, claim, buy, locked }

class FrameAction {
  const FrameAction(this.kind, this.label);
  final FrameActionKind kind;
  final String label;

  /// Whether tapping does anything.
  bool get enabled => kind != FrameActionKind.locked;
}

/// The one thing a user can do with [f] right now, given their [level]. Owned
/// frames are worn or taken off; others are claimed (free / reached level),
/// bought (coins), or locked with the reason (a higher level, VIP, or an event
/// the team gives them out for). The database re-checks every rule.
FrameAction frameActionFor(ProfileFrame f, {required int level}) {
  if (f.owned) {
    return f.equipped
        ? const FrameAction(FrameActionKind.remove, 'Remove')
        : const FrameAction(FrameActionKind.equip, 'Equip');
  }
  return switch (f.unlockType) {
    'free' => const FrameAction(FrameActionKind.claim, 'Claim'),
    'level' =>
      level >= f.unlockValue
          ? const FrameAction(FrameActionKind.claim, 'Claim')
          : FrameAction(FrameActionKind.locked, 'Level ${f.unlockValue}'),
    'coins' =>
      f.priceCoins > 0
          ? FrameAction(FrameActionKind.buy, '${f.priceCoins} coins')
          : const FrameAction(FrameActionKind.locked, 'Unavailable'),
    'vip' => const FrameAction(FrameActionKind.locked, 'VIP only'),
    _ => const FrameAction(FrameActionKind.locked, 'Event'),
  };
}

class FramesRepository {
  /// Every active frame, marked with what the signed-in user owns / wears.
  Future<List<ProfileFrame>> load() async {
    final me = supabase.auth.currentUser?.id;
    final frames = await supabase
        .from('frames')
        .select()
        .eq('status', 'active')
        .order('sort_order', ascending: true)
        .order('name', ascending: true);
    final mine = me == null
        ? const <dynamic>[]
        : await supabase
              .from('user_frames')
              .select('frame_id, equipped')
              .eq('profile_id', me);
    final owned = {
      for (final r in mine) r['frame_id'] as String: r['equipped'] == true,
    };
    return [
      for (final row in frames)
        ProfileFrame.fromRow(
          row,
          owned: owned.containsKey(row['id']),
          equipped: owned[row['id']] ?? false,
        ),
    ];
  }

  /// Get the frame by its unlock rule (free, level or coins).
  Future<void> claim(String frameId) async {
    await supabase.rpc('claim_frame', params: {'p_frame_id': frameId});
  }

  Future<void> setEquipped(String frameId, bool equipped) async {
    await supabase.rpc(
      'set_frame_equipped',
      params: {'p_frame_id': frameId, 'p_equipped': equipped},
    );
  }
}
