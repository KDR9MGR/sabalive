import '../config/supabase_client.dart';

class HostStreamRow {
  HostStreamRow({
    required this.title,
    required this.category,
    required this.status,
    required this.viewerPeak,
    required this.giftCoins,
    required this.startedAt,
    required this.endedAt,
  });

  factory HostStreamRow.fromRow(Map<String, dynamic> r) => HostStreamRow(
        title: r['title'] as String? ?? 'Live',
        category: r['category'] as String? ?? '',
        status: r['status'] as String? ?? 'ended',
        viewerPeak: (r['viewer_count'] as num?)?.toInt() ?? 0,
        giftCoins: (r['gift_coin_total'] as num?)?.toInt() ?? 0,
        startedAt: DateTime.tryParse(r['started_at'] as String? ?? '')?.toLocal(),
        endedAt: DateTime.tryParse(r['ended_at'] as String? ?? '')?.toLocal(),
      );

  final String title;
  final String category;
  final String status;
  final int viewerPeak;
  final int giftCoins;
  final DateTime? startedAt;
  final DateTime? endedAt;
}

class WithdrawalRow {
  WithdrawalRow({
    required this.diamonds,
    required this.status,
    required this.requestedAt,
    required this.amountInr,
  });

  factory WithdrawalRow.fromRow(Map<String, dynamic> r) => WithdrawalRow(
        diamonds: (r['diamonds'] as num?)?.toInt() ?? 0,
        status: r['status'] as String? ?? 'pending',
        requestedAt:
            DateTime.tryParse(r['requested_at'] as String? ?? '')?.toLocal(),
        amountInr: (r['amount_inr'] as num?)?.toDouble(),
      );

  final int diamonds;
  final String status;
  final DateTime? requestedAt;
  final double? amountInr;
}

class HostSummary {
  HostSummary({
    required this.totalStreams,
    required this.liveStreams,
    required this.lifetimeGiftCoins,
    required this.giftCoins30d,
  });

  final int totalStreams;
  final int liveStreams;
  final int lifetimeGiftCoins;
  final int giftCoins30d;
}

/// Creator/host analytics + payout requests. Streams come from `live_streams`
/// (host_id = me), payouts from `withdrawals` + the `request_withdrawal` RPC.
class HostRepository {
  String? get _me => supabase.auth.currentUser?.id;

  static const int minWithdrawalDiamonds = 100;

  Future<HostSummary> summary() async {
    final me = _me;
    if (me == null) {
      return HostSummary(
          totalStreams: 0, liveStreams: 0, lifetimeGiftCoins: 0, giftCoins30d: 0);
    }
    final rows = (await supabase
            .from('live_streams')
            .select('status, gift_coin_total, started_at')
            .eq('host_id', me)
            .limit(500) as List)
        .cast<Map<String, dynamic>>();
    final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 30));
    var lifetime = 0, last30 = 0, live = 0;
    for (final r in rows) {
      final coins = (r['gift_coin_total'] as num?)?.toInt() ?? 0;
      lifetime += coins;
      if (r['status'] == 'live') live++;
      final started = DateTime.tryParse(r['started_at'] as String? ?? '');
      if (started != null && started.isAfter(cutoff)) last30 += coins;
    }
    return HostSummary(
      totalStreams: rows.length,
      liveStreams: live,
      lifetimeGiftCoins: lifetime,
      giftCoins30d: last30,
    );
  }

  Future<List<HostStreamRow>> myStreams() async {
    final me = _me;
    if (me == null) return const [];
    final rows = (await supabase
            .from('live_streams')
            .select()
            .eq('host_id', me)
            .order('started_at', ascending: false)
            .limit(50) as List)
        .cast<Map<String, dynamic>>();
    return [for (final r in rows) HostStreamRow.fromRow(r)];
  }

  Future<List<WithdrawalRow>> myWithdrawals() async {
    final me = _me;
    if (me == null) return const [];
    final rows = (await supabase
            .from('withdrawals')
            .select()
            .eq('profile_id', me)
            .order('requested_at', ascending: false)
            .limit(50) as List)
        .cast<Map<String, dynamic>>();
    return [for (final r in rows) WithdrawalRow.fromRow(r)];
  }

  Future<void> requestWithdrawal(int diamonds) =>
      supabase.rpc('request_withdrawal', params: {'p_diamonds': diamonds});
}
