import '../config/supabase_client.dart';
import 'models.dart';

class ProfileVisit {
  ProfileVisit(this.user, this.visitedAt);
  final AppUser user;
  final DateTime visitedAt;
}

/// "Who viewed my profile" — `profile_visits` (upserted per visitor/visited
/// pair, so this is "most recently seen you", not a growing log).
/// `log_profile_visit` is a SECURITY DEFINER RPC (no client-write path;
/// self-visits and impersonation are both invalid to log). Reading your own
/// visitor list is a plain client select — RLS already scopes it to rows
/// where visited_id = auth.uid().
class ProfileVisitsRepository {
  Future<void> logVisit(String profileId) async {
    try {
      await supabase.rpc('log_profile_visit', params: {'p_profile_id': profileId});
    } catch (_) {
      /* best-effort — a missed visit log beats a broken profile screen */
    }
  }

  Future<List<ProfileVisit>> myVisitors() async {
    final me = supabase.auth.currentUser?.id;
    if (me == null) return const [];
    final rows = await supabase
        .from('profile_visits')
        .select('visited_at, profiles!profile_visits_visitor_id_fkey(*)')
        .eq('visited_id', me)
        .order('visited_at', ascending: false);
    return [
      for (final r in rows)
        if (r['profiles'] case final Map<String, dynamic> p)
          ProfileVisit(
            AppUser.fromRow(p),
            DateTime.parse(r['visited_at'] as String).toLocal(),
          ),
    ];
  }
}
