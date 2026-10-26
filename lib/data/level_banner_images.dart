import '../config/supabase_client.dart';

/// The join-banner pictures the panel set for each level (Master -> Levels), kept in memory so a room full of
/// arrivals asks the database once, not once per person.
///
/// A person's banner is the picture of the highest Charm level they have reached that has one (falling back to
/// their Wealth level's picture when [bannerFor] is asked). Everything is read in one small query (a few dozen
/// rows), shared by concurrent callers, and remembered for [ttl] (5 minutes: a picture changed in the panel shows up on a phone within a few minutes). A failed read is not remembered, and gives null:
/// the caller then keeps the picture the join row carried.
class LevelBannerImages {
  LevelBannerImages({
    Future<List<Map<String, dynamic>>> Function()? loader,
    DateTime Function()? now,
    this.ttl = const Duration(minutes: 5),
  })  : _loader = loader ?? _loadFromSupabase,
        _now = now ?? DateTime.now;

  /// The one the live screens share.
  static final LevelBannerImages instance = LevelBannerImages();

  final Future<List<Map<String, dynamic>>> Function() _loader;
  final DateTime Function() _now;
  final Duration ttl;

  List<LevelBannerStep>? _steps;
  DateTime? _at;
  Future<List<LevelBannerStep>?>? _inFlight;

  static Future<List<Map<String, dynamic>>> _loadFromSupabase() async {
    final rows = await supabase
        .from('track_levels')
        .select('track, level, image_url')
        .not('image_url', 'is', null)
        .order('level', ascending: true);
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// Every picture the panel set, one step per level and track (shared and remembered like the rest). Null when they cannot be read right now.
  Future<List<LevelBannerStep>?> steps() => _get();

  /// The banner picture for a person at [charmLevel]: the highest Charm level at or below it that has one.
  /// Null when the panel set none (or they cannot be read right now).
  Future<String?> charmImage(int charmLevel) async {
    final steps = await _get();
    if (steps == null) return null;
    return pick(steps, charmLevel);
  }

  /// The banner picture for a person with these levels: their Charm level's picture, else their Wealth level's.
  /// Null when the panel set neither (or they cannot be read right now).
  Future<String?> bannerFor({required int wealthLevel, required int charmLevel}) async {
    final steps = await _get();
    if (steps == null) return null;
    return pick(steps, charmLevel) ?? pick(steps, wealthLevel, track: 'wealth');
  }

  /// Picks from already-read steps: the highest level of [track] at or below [level] that has a picture.
  static String? pick(List<LevelBannerStep> steps, int level, {String track = 'charm'}) {
    String? best;
    var bestLevel = 0;
    for (final s in steps) {
      if (s.track == track && s.level <= level && s.level >= bestLevel) {
        best = s.url;
        bestLevel = s.level;
      }
    }
    return best;
  }

  Future<List<LevelBannerStep>?> _get() {
    final steps = _steps;
    final at = _at;
    if (steps != null && at != null && _now().difference(at) < ttl) return Future.value(steps);
    return _inFlight ??= _fetch();
  }

  Future<List<LevelBannerStep>?> _fetch() async {
    try {
      final rows = await Future<List<Map<String, dynamic>>>.sync(_loader);
      final next = <LevelBannerStep>[
        for (final r in rows)
          if (r['level'] is num && (r['image_url'] as String?)?.trim().isNotEmpty == true)
            LevelBannerStep('${r['track'] ?? 'charm'}', (r['level'] as num).toInt(), (r['image_url'] as String).trim()),
      ];
      _steps = next;
      _at = _now();
      return next;
    } catch (_) {
      // keep serving the old list if there is one: a stale picture beats none
      return _steps;
    } finally {
      _inFlight = null;
    }
  }

  /// The next read goes to the database even if the last one is recent (the My Level screen opening, a pull to refresh). The old list is kept as the fallback if that read fails.
  void invalidate() {
    _at = null;
  }

  /// For tests: forget everything read.
  void clear() {
    _steps = null;
    _at = null;
  }
}

class LevelBannerStep {
  const LevelBannerStep(this.track, this.level, this.url);
  final String track;
  final int level;
  final String url;
}
