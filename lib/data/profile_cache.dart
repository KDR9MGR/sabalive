import '../config/supabase_client.dart';

/// Short-lived memory of profile rows, so a busy room does not ask the database for the same person
/// on every chat line, join notice and seat event (each one used to be its own `profiles` select, and
/// the line only appeared after it came back).
///
/// Concurrent requests for one id share a single query. Failures and "not found" are not remembered.
class ProfileCache {
  ProfileCache({
    Future<Map<String, dynamic>?> Function(String id)? loader,
    DateTime Function()? now,
    this.ttl = const Duration(minutes: 2),
    this.maxEntries = 400,
  })  : _loader = loader ?? _loadFromSupabase,
        _now = now ?? DateTime.now;

  /// The one the live screens share.
  static final ProfileCache instance = ProfileCache();

  final Future<Map<String, dynamic>?> Function(String id) _loader;
  final DateTime Function() _now;
  final Duration ttl;
  final int maxEntries;

  final Map<String, ({DateTime at, Map<String, dynamic> row})> _rows = {};
  final Map<String, Future<Map<String, dynamic>?>> _inFlight = {};

  static Future<Map<String, dynamic>?> _loadFromSupabase(String id) =>
      supabase.from('profiles').select().eq('id', id).maybeSingle();

  /// The profile row for [id], from memory when it is recent, else from the database.
  /// Null when the person cannot be read (or does not exist).
  Future<Map<String, dynamic>?> get(String id) {
    final hit = _rows[id];
    if (hit != null && _now().difference(hit.at) < ttl) return Future.value(hit.row);
    return _inFlight[id] ??= _fetch(id);
  }

  Future<Map<String, dynamic>?> _fetch(String id) async {
    try {
      // Future.sync: even a loader that throws at once settles after _inFlight was filled in
      final row = await Future<Map<String, dynamic>?>.sync(() => _loader(id));
      if (row != null) put(row);
      return row;
    } catch (_) {
      return null;
    } finally {
      _inFlight.remove(id);
    }
  }

  /// Remember a row some other query already returned (seat and viewer lists carry full profiles).
  void put(Map<String, dynamic> row) {
    final id = row['id'];
    if (id is! String) return;
    if (_rows.length >= maxEntries && !_rows.containsKey(id)) {
      final oldest = _rows.entries.reduce((a, b) => a.value.at.isBefore(b.value.at) ? a : b);
      _rows.remove(oldest.key);
    }
    _rows[id] = (at: _now(), row: row);
  }

  void clear() {
    _rows.clear();
    _inFlight.clear();
  }
}
