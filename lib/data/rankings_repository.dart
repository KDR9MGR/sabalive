import '../config/supabase_client.dart';
import 'models.dart';

enum RankBoard { hosts, gifters }

enum RankPeriod { daily, weekly, monthly }

/// Reads the leaderboard RPCs (SECURITY DEFINER functions defined in
/// `supabase/migrations/*rankings*`) and hydrates the `(profile_id, score)`
/// rows into [RankingEntry]s, preserving the RPC's score-descending order.
class RankingsRepository {
  Future<List<RankingEntry>> fetch(RankBoard board, RankPeriod period) async {
    final fn = switch ((board, period)) {
      (RankBoard.hosts, RankPeriod.daily) => 'rankings_daily',
      (RankBoard.hosts, RankPeriod.weekly) => 'rankings_weekly',
      (RankBoard.hosts, RankPeriod.monthly) => 'rankings_monthly',
      (RankBoard.gifters, RankPeriod.daily) => 'rankings_top_gifters_daily',
      (RankBoard.gifters, RankPeriod.weekly) => 'rankings_top_gifters_weekly',
      (RankBoard.gifters, RankPeriod.monthly) => 'rankings_top_gifters_monthly',
    };

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
}
