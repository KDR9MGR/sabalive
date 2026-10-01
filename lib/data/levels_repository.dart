import '../config/supabase_client.dart';

class LevelThreshold {
  LevelThreshold(this.level, this.xpRequired);
  final int level;
  final int xpRequired;
}

class MyLevel {
  MyLevel(this.level, this.xp, this.thresholds);
  final int level;
  final int xp;
  final List<LevelThreshold> thresholds;

  LevelThreshold? _find(int forLevel) {
    for (final t in thresholds) {
      if (t.level == forLevel) return t;
    }
    return null;
  }

  LevelThreshold? get current => _find(level);
  LevelThreshold? get next => _find(level + 1);

  /// 0.0-1.0 progress toward the next level, 1.0 (maxed) if there is none.
  double get progress {
    final cur = current;
    final nxt = next;
    if (cur == null || nxt == null) return 1;
    final span = nxt.xpRequired - cur.xpRequired;
    if (span <= 0) return 1;
    return ((xp - cur.xpRequired) / span).clamp(0, 1).toDouble();
  }
}

/// Real level/XP — profiles.xp/level, earned automatically by the
/// award_gift_xp trigger on gift_transactions (both sender and receiver).
/// level_thresholds is a plain catalog table, publicly readable.
///
/// Wealth (coins spent / gifts sent) and Charm (value received) are a
/// separate pair of tracks — profiles.wealth_xp/wealth_level and
/// charm_xp/charm_level, fed by award_wealth_charm_xp — sharing the same
/// level_thresholds catalog (now extended through level 100). The combined
/// xp/level above is untouched by that split; it's still the "LV X" badge
/// shown elsewhere in the app.
class LevelsRepository {
  Future<MyLevel?> mine() async {
    final me = supabase.auth.currentUser?.id;
    if (me == null) return null;
    final profileRow = await supabase
        .from('profiles')
        .select('xp, level')
        .eq('id', me)
        .maybeSingle();
    if (profileRow == null) return null;
    final thresholds = await _thresholds();
    return MyLevel(profileRow['level'] as int, profileRow['xp'] as int, thresholds);
  }

  Future<WealthCharmLevels?> wealthAndCharm() async {
    final me = supabase.auth.currentUser?.id;
    if (me == null) return null;
    final profileRow = await supabase
        .from('profiles')
        .select('wealth_xp, wealth_level, charm_xp, charm_level')
        .eq('id', me)
        .maybeSingle();
    if (profileRow == null) return null;
    final thresholds = await _thresholds();
    return WealthCharmLevels(
      wealth: MyLevel(
        profileRow['wealth_level'] as int,
        profileRow['wealth_xp'] as int,
        thresholds,
      ),
      charm: MyLevel(
        profileRow['charm_level'] as int,
        profileRow['charm_xp'] as int,
        thresholds,
      ),
    );
  }

  Future<List<LevelThreshold>> _thresholds() async {
    final rows = await supabase
        .from('level_thresholds')
        .select()
        .order('level', ascending: true);
    return [
      for (final r in rows) LevelThreshold(r['level'] as int, r['xp_required'] as int),
    ];
  }
}

class WealthCharmLevels {
  WealthCharmLevels({required this.wealth, required this.charm});
  final MyLevel wealth;
  final MyLevel charm;
}
