import 'package:flutter/foundation.dart';

import '../config/supabase_client.dart';

class LevelThreshold {
  LevelThreshold(this.level, this.xpRequired);
  final int level;
  final int xpRequired;

  @override
  bool operator ==(Object other) => other is LevelThreshold && other.level == level && other.xpRequired == xpRequired;

  @override
  int get hashCode => Object.hash(level, xpRequired);
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

  // equal when the person's level, XP and every level's XP are the same: a refresh that changed nothing redraws nothing
  @override
  bool operator ==(Object other) => other is MyLevel && other.level == level && other.xp == xp && listEquals(other.thresholds, thresholds);

  @override
  int get hashCode => Object.hash(level, xp, Object.hashAll(thresholds));

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
/// charm_xp/charm_level, fed by award_wealth_charm_xp. Each track has its OWN
/// XP per level in `track_levels`, which the panel's Master -> Levels page edits
/// (and re-levels everyone from), so that is what Wealth and Charm read here;
/// the old shared level_thresholds catalog is only the fallback when track_levels
/// can't be read or has no rows. The combined xp/level above is untouched by that
/// split; it's still the "LV X" badge shown elsewhere in the app.
class LevelsRepository {
  LevelsRepository({@visibleForTesting Future<List<Map<String, dynamic>>> Function(String track)? trackRows})
      : _trackRows = trackRows ?? _loadTrackRows;

  final Future<List<Map<String, dynamic>>> Function(String track) _trackRows;

  static Future<List<Map<String, dynamic>>> _loadTrackRows(String track) async {
    final rows = await supabase
        .from('track_levels')
        .select('level, xp_required')
        .eq('track', track)
        .order('level', ascending: true);
    return List<Map<String, dynamic>>.from(rows as List);
  }

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
    final (wealth, charm) = await (_track('wealth'), _track('charm')).wait;
    return WealthCharmLevels.from(profileRow, wealth: wealth, charm: charm);
  }

  /// The levels of one track as the panel set them; the shared catalog if that can't be read or is empty.
  Future<List<LevelThreshold>> _track(String track) async {
    try {
      final levels = levelsFromRows(await _trackRows(track));
      if (levels.isNotEmpty) return levels;
    } catch (_) {
      // fall through to the shared catalog
    }
    return _thresholds();
  }

  @visibleForTesting
  Future<List<LevelThreshold>> trackLevelsForTest(String track) => _track(track);

  Future<List<LevelThreshold>> _thresholds() async {
    final rows = await supabase
        .from('level_thresholds')
        .select()
        .order('level', ascending: true);
    return levelsFromRows(rows as List);
  }
}

/// `level` / `xp_required` rows as thresholds, in level order. A row that isn't readable is skipped.
List<LevelThreshold> levelsFromRows(Iterable<dynamic> rows) {
  final out = <LevelThreshold>[];
  for (final r in rows) {
    if (r is! Map) continue;
    final level = r['level'];
    final xp = r['xp_required'];
    if (level is int && xp is int) out.add(LevelThreshold(level, xp));
  }
  out.sort((a, b) => a.level.compareTo(b.level));
  return out;
}

class WealthCharmLevels {
  WealthCharmLevels({required this.wealth, required this.charm});

  /// The two tracks of a profile row (`wealth_xp`, `wealth_level`, `charm_xp`, `charm_level`), each with its own list of levels.
  factory WealthCharmLevels.from(
    Map<String, dynamic> profile, {
    required List<LevelThreshold> wealth,
    required List<LevelThreshold> charm,
  }) =>
      WealthCharmLevels(
        wealth: MyLevel(profile['wealth_level'] as int, profile['wealth_xp'] as int, wealth),
        charm: MyLevel(profile['charm_level'] as int, profile['charm_xp'] as int, charm),
      );

  final MyLevel wealth;
  final MyLevel charm;

  @override
  bool operator ==(Object other) => other is WealthCharmLevels && other.wealth == wealth && other.charm == charm;

  @override
  int get hashCode => Object.hash(wealth, charm);
}
