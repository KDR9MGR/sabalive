import '../config/supabase_client.dart';
import 'models.dart';

class ReferralEntry {
  ReferralEntry(this.user, this.rewardCoins, this.createdAt);
  final AppUser user;
  final int rewardCoins;
  final DateTime createdAt;
}

/// Referral / invite-a-friend — `my_referral_code`/`redeem_referral_code`
/// RPCs (both SECURITY DEFINER; the reward grant needs server-side
/// validation no client insert could enforce — one redemption per person,
/// no self-referral). Reading your own referral list is a plain client
/// select, scoped by RLS to referrer_id = auth.uid().
class ReferralsRepository {
  Future<String> myCode() async {
    final v = await supabase.rpc('my_referral_code');
    return v as String;
  }

  Future<void> redeem(String code) async {
    await supabase.rpc('redeem_referral_code', params: {'p_code': code});
  }

  Future<List<ReferralEntry>> myReferrals() async {
    final rows = await supabase
        .from('referrals')
        .select('reward_coins, created_at, profiles!referrals_referred_id_fkey(*)')
        .order('created_at', ascending: false);
    return [
      for (final r in rows)
        if (r['profiles'] case final Map<String, dynamic> p)
          ReferralEntry(
            AppUser.fromRow(p),
            r['reward_coins'] as int,
            DateTime.parse(r['created_at'] as String).toLocal(),
          ),
    ];
  }
}
