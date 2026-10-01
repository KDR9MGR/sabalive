import '../config/supabase_client.dart';

class BadgeInfo {
  BadgeInfo({
    required this.id,
    required this.name,
    required this.emoji,
    required this.criteria,
    required this.owned,
  });

  factory BadgeInfo.fromRow(Map<String, dynamic> row, {required bool owned}) =>
      BadgeInfo(
        id: row['id'] as String,
        name: row['name'] as String,
        emoji: row['emoji'] as String? ?? '🏅',
        criteria: row['criteria'] as String? ?? '',
        owned: owned,
      );

  final String id;
  final String name;
  final String emoji;
  final String criteria;
  final bool owned;
}

/// The full badge catalog (`badges`, publicly readable) cross-referenced
/// with what one profile has actually earned (`user_badges`, also public —
/// "earned badges are publicly viewable"). Badges are admin-awarded only
/// (no client/RPC write path exists, by design — these are judged
/// achievements like "Event Winner" or "Verified", not mechanically
/// checkable the way XP is), so this repository is read-only.
class BadgesRepository {
  Future<List<BadgeInfo>> allWithOwnership(String profileId) async {
    final badgeRows =
        await supabase.from('badges').select().eq('status', 'active').order('sort_order', ascending: true);
    final ownedRows = await supabase
        .from('user_badges')
        .select('badge_id')
        .eq('profile_id', profileId);
    final ownedIds = {for (final r in ownedRows) r['badge_id'] as String};
    return [
      for (final r in badgeRows)
        BadgeInfo.fromRow(r, owned: ownedIds.contains(r['id'] as String)),
    ];
  }
}
