import '../config/supabase_client.dart';
import 'models.dart';

enum RankBoard { hosts, gifters }

/// [lifetime] = every gift ever sent (owner, 2026-11-06): no start date, never resets. Needs migration 20261106110000 for Gifters and Agency; Hosts uses the older `rankings_all_time`.
enum RankPeriod { daily, weekly, monthly, lifetime }

/// The database function behind a Hosts / Gifters board of a period.
String rankingsFunction(RankBoard board, RankPeriod period) => switch ((board, period)) {
  (RankBoard.hosts, RankPeriod.daily) => 'rankings_daily',
  (RankBoard.hosts, RankPeriod.weekly) => 'rankings_weekly',
  (RankBoard.hosts, RankPeriod.monthly) => 'rankings_monthly',
  (RankBoard.hosts, RankPeriod.lifetime) => 'rankings_all_time',
  (RankBoard.gifters, RankPeriod.daily) => 'rankings_top_gifters_daily',
  (RankBoard.gifters, RankPeriod.weekly) => 'rankings_top_gifters_weekly',
  (RankBoard.gifters, RankPeriod.monthly) => 'rankings_top_gifters_monthly',
  (RankBoard.gifters, RankPeriod.lifetime) => 'rankings_top_gifters_lifetime',
};

/// The database function behind the Agency board of a period.
String agencyRankingsFunction(RankPeriod period) => switch (period) {
  RankPeriod.daily => 'rankings_agencies_daily',
  RankPeriod.weekly => 'rankings_agencies_weekly',
  RankPeriod.monthly => 'rankings_agencies_monthly',
  RankPeriod.lifetime => 'rankings_agencies_lifetime',
};

/// Reads the leaderboard RPCs (SECURITY DEFINER functions defined in
/// `supabase/migrations/*rankings*`) and hydrates the `(profile_id, score)`
/// rows into [RankingEntry]s, preserving the RPC's score-descending order.
class RankingsRepository {
  Future<List<RankingEntry>> fetch(RankBoard board, RankPeriod period) async {
    final fn = rankingsFunction(board, period);

    final rows = (await supabase.rpc(fn).limit(100) as List)
        .cast<Map<String, dynamic>>();
    if (rows.isEmpty) return const [];

    final scoreById = <String, int>{
      for (final r in rows) r['profile_id'] as String: (r['score'] as num).toInt(),
    };
    final profiles = (await supabase
            .from('profiles')
            .select()
            .inFilter('id', scoreById.keys.toList()) as List)
        .cast<Map<String, dynamic>>();
    final userById = <String, AppUser>{
      for (final p in profiles) p['id'] as String: AppUser.fromRow(p),
    };

    return [
      for (final r in rows)
        if (userById[r['profile_id']] case final user?)
          RankingEntry(user, scoreById[r['profile_id']]!, 0),
    ];
  }

  Future<List<AgencyRankingEntry>> fetchAgencies(RankPeriod period) async {
    final fn = agencyRankingsFunction(period);
    final rows = (await supabase.rpc(fn).limit(100) as List)
        .cast<Map<String, dynamic>>();
    return [
      for (final r in rows)
        AgencyRankingEntry(
          r['agency_id'] as String,
          r['agency_name'] as String,
          (r['score'] as num).toInt(),
        ),
    ];
  }
}
