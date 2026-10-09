import '../config/supabase_client.dart';

/// The two numbers the admin panel controls (Master -> Lucky Box):
/// how long a host must stay live in ONE stream, and the one-time reward.
class LuckyBoxConfig {
  const LuckyBoxConfig({
    required this.durationMinutes,
    required this.rewardDiamonds,
    this.cooldownHours = 0,
  });
  final int durationMinutes;
  final int rewardDiamonds;

  /// A host paid within this many hours is not paid again (0 = no cooldown, also what an older database means).
  final int cooldownHours;

  Duration get duration => Duration(minutes: durationMinutes);
}

/// Lucky Box: a host who stays live for the configured stretch, unbroken, in
/// one stream gets a one-time diamond reward. The server grants it (a cron job
/// checks every minute — see 20260929130000_lucky_box.sql); this just reads the
/// panel's settings and whether the reward has landed, so the app can show a
/// countdown.
class LuckyBoxRepository {
  Future<LuckyBoxConfig> config() async {
    // all columns: cooldown_hours does not exist on a database that has not been updated yet
    final row = await supabase.from('lucky_box_config').select().eq('id', true).single();
    return LuckyBoxConfig(
      durationMinutes: row['duration_minutes'] as int,
      rewardDiamonds: row['reward_diamonds'] as int,
      cooldownHours: (row['cooldown_hours'] as num?)?.toInt() ?? 0,
    );
  }

  /// The server's answer for this live: whether it was already paid and until when its host is resting
  /// (paid within the cooldown, so this live's box will not open). Null when it can't be read, or the database
  /// has no such function yet: callers then behave as they did before the cooldown existed.
  Future<LuckyBoxStatus?> status(String streamId) async {
    try {
      final res = await supabase.rpc('lucky_box_status', params: {'p_stream_id': streamId});
      return res is Map ? LuckyBoxStatus.fromJson(Map<String, dynamic>.from(res)) : null;
    } catch (_) {
      return null;
    }
  }

  /// The server's own start time for this stream — the one its reward check
  /// counts from.
  Future<DateTime?> streamStartedAt(String streamId) async {
    final row = await supabase
        .from('live_streams')
        .select('started_at')
        .eq('id', streamId)
        .maybeSingle();
    final raw = row?['started_at'] as String?;
    return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
  }

  /// Diamonds this stream's Lucky Box has paid out, or null if it hasn't yet
  /// (the reward is a wallet_ledger row tagged `lucky_box`).
  Future<int?> rewardGranted(String streamId) async {
    final row = await supabase
        .from('wallet_ledger')
        .select('amount')
        .eq('reference_table', 'live_streams')
        .eq('reference_id', streamId)
        .eq('note', 'lucky_box')
        .maybeSingle();
    return row == null ? null : (row['amount'] as num).toInt();
  }
}

/// What `lucky_box_status` says about one live.
class LuckyBoxStatus {
  const LuckyBoxStatus({this.paid = false, this.restUntil});

  /// This live's box already paid out.
  final bool paid;

  /// The host was paid recently enough that this live's box will not open; they may earn again from a NEW live
  /// started after this time. Null = not resting.
  final DateTime? restUntil;

  factory LuckyBoxStatus.fromJson(Map<String, dynamic> j) => LuckyBoxStatus(
        paid: j['paid'] == true,
        restUntil: j['rest_until'] is String ? DateTime.tryParse(j['rest_until'] as String)?.toUtc() : null,
      );
}

/// "23h 12m" / "45m" / "now": how long a resting host has to wait before a new live can earn again.
String luckyBoxRestLabel(Duration d) {
  if (d <= Duration.zero) return 'now';
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h > 0) return m == 0 ? '${h}h' : '${h}h ${m}m';
  return '${d.inMinutes < 1 ? 1 : d.inMinutes}m';
}

enum LuckyBoxPhase {
  /// Still counting down to the reward.
  counting,

  /// Time is up; waiting for the server to pay out (it runs once a minute).
  opening,

  /// Paid out.
  opened,
}

class LuckyBoxProgress {
  const LuckyBoxProgress(this.phase, this.remaining, this.reward);
  final LuckyBoxPhase phase;
  final Duration remaining;
  final int? reward;
}

/// Pure so it can be tested: where the box is, given when the stream started,
/// the configured duration, "now", and whether a reward has been paid.
///
/// A viewer cannot see the host's wallet, so [pastDeadlineMeansOpened] is set for them: the box
/// simply shows as opened (without an amount) once the time is up.
LuckyBoxProgress luckyBoxProgress({
  required DateTime startedAt,
  required Duration duration,
  required DateTime now,
  int? rewardPaid,
  bool pastDeadlineMeansOpened = false,
  bool paidWithoutAmount = false,
}) {
  if (rewardPaid != null) {
    return LuckyBoxProgress(LuckyBoxPhase.opened, Duration.zero, rewardPaid);
  }
  // the server says this live paid (a viewer can't see how much): opened, whatever this phone's clock says
  if (paidWithoutAmount) return const LuckyBoxProgress(LuckyBoxPhase.opened, Duration.zero, null);
  final remaining = startedAt.add(duration).difference(now);
  if (remaining > Duration.zero) {
    return LuckyBoxProgress(LuckyBoxPhase.counting, remaining, null);
  }
  return LuckyBoxProgress(
    pastDeadlineMeansOpened ? LuckyBoxPhase.opened : LuckyBoxPhase.opening,
    Duration.zero,
    null,
  );
}

/// "12:05", or "1:02:05" past an hour.
String luckyBoxClock(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
