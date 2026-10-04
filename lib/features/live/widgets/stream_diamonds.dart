import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../config/supabase_client.dart';

/// Diamonds each person has earned in THIS stream today (the server's
/// stream_diamonds_today: gifts received in this stream since 00:00 UTC).
///
/// Because the server derives it from the gifts themselves, leaving and coming back
/// to the same stream resumes the same number; another stream has its own; and at
/// 00:00 UTC every count restarts from 0 for everyone at once, which [_tick] also
/// notices so an open room rolls over on its own.
class StreamDiamonds {
  StreamDiamonds(this.streamId, {required this.onChanged});

  final String streamId;
  final VoidCallback onChanged;

  Map<String, int> _byUser = const {};
  Timer? _poll;
  Timer? _debounce;
  late DateTime _day = _utcDay();
  bool _disposed = false;

  static DateTime _utcDay() {
    final n = DateTime.now().toUtc();
    return DateTime.utc(n.year, n.month, n.day);
  }

  /// Diamonds [userId] has earned here today (0 when none).
  int of(String userId) => _byUser[userId] ?? 0;

  /// Everyone's count, by user id.
  Map<String, int> get all => _byUser;

  void start() {
    unawaited(_load());
    // gifts land over Realtime (see [onGift]); the poll is the safety net and the
    // midnight rollover
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
  }

  /// A gift was just sent in this room — refresh shortly (one query for a burst).
  void onGift() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () => unawaited(_load()));
  }

  void _tick() {
    final today = _utcDay();
    if (today != _day) {
      _day = today;
      _byUser = const {};
      if (!_disposed) onChanged();
    }
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final rows = await supabase.rpc(
        'stream_diamonds_today',
        params: {'p_stream_id': streamId},
      );
      if (_disposed) return;
      final next = <String, int>{
        for (final r in rows as List)
          (r['user_id'] as String): (r['diamonds'] as num).toInt(),
      };
      if (!mapEquals(next, _byUser)) {
        _byUser = next;
        onChanged();
      }
    } catch (e) {
      debugPrint('stream_diamonds_today failed: $e');
    }
  }

  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _debounce?.cancel();
  }
}
