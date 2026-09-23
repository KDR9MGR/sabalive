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
    final thresholdRows = await supabase
        .from('level_thresholds')
        .select()
        .order('level');
    return MyLevel(
      profileRow['level'] as int,
      profileRow['xp'] as int,
      [
        for (final r in thresholdRows)
          LevelThreshold(r['level'] as int, r['xp_required'] as int),
      ],
    );
  }
}
