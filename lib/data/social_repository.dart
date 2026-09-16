import '../config/supabase_client.dart';
import '../core/utils/ids.dart';
import 'models.dart';

/// Follows, profile lookups, search and notifications — the social surface
/// outside of live/DM. Backed by `follows`, `profiles`, `live_streams`,
/// `notifications`.
class SocialRepository {
  String? get _me => supabase.auth.currentUser?.id;

  // ───────────────────────────────── follows
  Future<Set<String>> myFollowingIds() async {
    final me = _me;
    if (me == null) return {};
    final rows = (await supabase
            .from('follows')
            .select('followee_id')
            .eq('follower_id', me) as List)
        .cast<Map<String, dynamic>>();
    return {for (final r in rows) r['followee_id'] as String};
  }

  Future<void> follow(String userId) async {
    final me = _me;
    if (me == null || !isRealId(userId)) return;
    await supabase.from('follows').upsert({
      'follower_id': me,
      'followee_id': userId,
    });
  }

  Future<void> unfollow(String userId) async {
    final me = _me;
    if (me == null) return;
    await supabase
        .from('follows')
        .delete()
        .eq('follower_id', me)
        .eq('followee_id', userId);
  }

  // ───────────────────────────────── profiles
  Future<AppUser?> profile(String userId) async {
    if (!isRealId(userId)) return null;
    final row = await supabase.from('profiles').select().eq('id', userId).maybeSingle();
    return row == null ? null : AppUser.fromRow(row);
  }

  Future<LiveStream?> liveStreamForHost(String hostId) async {
    if (!isRealId(hostId)) return null;
    final row = await supabase
        .from('live_streams')
        .select('*, profiles!live_streams_host_id_fkey(*)')
        .eq('host_id', hostId)
        .eq('status', 'live')
        .order('started_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (row == null || row['profiles'] == null) return null;
    return LiveStream.fromRow(
        row, AppUser.fromRow(row['profiles'] as Map<String, dynamic>));
  }

  Future<List<AppUser>> followList(String userId, {required bool followers}) async {
    final col = followers ? 'follower_id' : 'followee_id';
    final other = followers ? 'followee_id' : 'follower_id';
    final rows = (await supabase
            .from('follows')
            .select('$col, profiles!follows_${col}_fkey(*)')
            .eq(other, userId)
            .limit(200) as List)
        .cast<Map<String, dynamic>>();
    return [
      for (final r in rows)
        if (r['profiles'] != null)
          AppUser.fromRow(r['profiles'] as Map<String, dynamic>),
    ];
  }

  // ───────────────────────────────── search
  Future<List<AppUser>> searchUsers(String query) async {
    final q = query.trim().replaceAll(RegExp(r'[,()*]'), '');
    if (q.isEmpty) return const [];
    final rows = (await supabase
            .from('profiles')
            .select()
            .or('username.ilike.%$q%,name.ilike.%$q%')
            .limit(30) as List)
        .cast<Map<String, dynamic>>();
    return [for (final r in rows) AppUser.fromRow(r)];
  }

  Future<List<LiveStream>> searchLiveStreams(String query) async {
    final q = query.trim().replaceAll(RegExp(r'[,()*]'), '');
    final base = supabase
        .from('live_streams')
        .select('*, profiles!live_streams_host_id_fkey(*)')
        .eq('status', 'live');
    final rows = (await (q.isEmpty
            ? base.order('viewer_count', ascending: false).limit(30)
            : base.ilike('title', '%$q%').limit(30)) as List)
        .cast<Map<String, dynamic>>();
    return [
      for (final r in rows)
        if (r['profiles'] != null)
          LiveStream.fromRow(r, AppUser.fromRow(r['profiles'] as Map<String, dynamic>)),
    ];
  }

  // ───────────────────────────────── stream likes
  Future<Set<String>> likedStreamIds() async {
    final me = _me;
    if (me == null) return {};
    final rows = (await supabase
            .from('stream_likes')
            .select('live_stream_id')
            .eq('profile_id', me)
            .limit(500) as List)
        .cast<Map<String, dynamic>>();
    return {for (final r in rows) r['live_stream_id'] as String};
  }

  Future<void> likeStream(String streamId) async {
    final me = _me;
    if (me == null || !isRealId(streamId)) return;
    await supabase
        .from('stream_likes')
        .upsert({'live_stream_id': streamId, 'profile_id': me});
  }

  Future<void> unlikeStream(String streamId) async {
    final me = _me;
    if (me == null) return;
    await supabase
        .from('stream_likes')
        .delete()
        .eq('live_stream_id', streamId)
        .eq('profile_id', me);
  }

  // ───────────────────────────────── badges / frames
  Future<List<({String emoji, String name})>> userBadges(String userId) async {
    if (!isRealId(userId)) return const [];
    final rows = (await supabase
            .from('user_badges')
            .select('badges(emoji, name)')
            .eq('profile_id', userId) as List)
        .cast<Map<String, dynamic>>();
    return [
      for (final r in rows)
        if (r['badges'] != null)
          (
            emoji: (r['badges'] as Map)['emoji'] as String? ?? '🏅',
            name: (r['badges'] as Map)['name'] as String? ?? 'Badge',
          ),
    ];
  }

  // ───────────────────────────────── block / report
  Future<Set<String>> blockedIds() async {
    final me = _me;
    if (me == null) return {};
    final rows = (await supabase
            .from('blocks')
            .select('blocked_id')
            .eq('blocker_id', me) as List)
        .cast<Map<String, dynamic>>();
    return {for (final r in rows) r['blocked_id'] as String};
  }

  Future<void> block(String userId) async {
    final me = _me;
    if (me == null || !isRealId(userId)) return;
    await supabase.from('blocks').upsert({'blocker_id': me, 'blocked_id': userId});
  }

  Future<void> unblock(String userId) async {
    final me = _me;
    if (me == null) return;
    await supabase
        .from('blocks')
        .delete()
        .eq('blocker_id', me)
        .eq('blocked_id', userId);
  }

  Future<void> report({
    required String targetType,
    required String targetId,
    required String reason,
    String? note,
  }) async {
    final me = _me;
    if (me == null) return;
    await supabase.from('user_reports').insert({
      'reporter_id': me,
      'target_type': targetType,
      'target_id': targetId,
      'reason': reason,
      'note': note,
    });
  }

  // ───────────────────────────────── host access (agency code gate)
  Future<({bool hasAccess, bool staff, bool banned, DateTime? expiresAt})>
      hostAccess() async {
    final r = (await supabase.rpc('my_host_access')) as Map<String, dynamic>;
    return (
      hasAccess: r['has_access'] as bool? ?? false,
      staff: r['staff'] as bool? ?? false,
      banned: r['banned'] as bool? ?? false,
      expiresAt: DateTime.tryParse(r['expires_at'] as String? ?? '')?.toLocal(),
    );
  }

  /// Redeems an agency-issued host code. Returns the access expiry (null =
  /// permanent). Throws a friendly [PostgrestException] on a bad/expired code.
  Future<DateTime?> redeemHostCode(String code) async {
    final r = (await supabase
        .rpc('redeem_host_code', params: {'p_code': code})) as Map<String, dynamic>;
    return DateTime.tryParse(r['expires_at'] as String? ?? '')?.toLocal();
  }

  // ───────────────────────────────── coin reseller access + selling
  Future<({bool hasAccess, bool staff, bool banned, DateTime? expiresAt})>
      resellerAccess() async {
    final r = (await supabase.rpc('my_reseller_access')) as Map<String, dynamic>;
    return (
      hasAccess: r['has_access'] as bool? ?? false,
      staff: r['staff'] as bool? ?? false,
      banned: r['banned'] as bool? ?? false,
      expiresAt: DateTime.tryParse(r['expires_at'] as String? ?? '')?.toLocal(),
    );
  }

  Future<DateTime?> redeemResellerCode(String code) async {
    final r = (await supabase.rpc('redeem_reseller_code', params: {'p_code': code}))
        as Map<String, dynamic>;
    return DateTime.tryParse(r['expires_at'] as String? ?? '')?.toLocal();
  }

  /// Transfers [coins] from the caller (an approved reseller) to the user with
  /// [recipientUsername]. Server-authoritative (`resell_coins`).
  Future<void> sellCoins({
    required String recipientUsername,
    required int coins,
    String? note,
  }) async {
    await supabase.rpc('resell_coins', params: {
      'p_recipient': recipientUsername,
      'p_coins': coins,
      'p_note': note,
    });
  }

  Future<List<({String other, int coins, bool outgoing, DateTime? at, String note})>>
      resellerTransfers() async {
    final me = _me;
    if (me == null) return const [];
    final rows = (await supabase
            .from('coin_transfers')
            .select('sender_id, recipient_id, coins, note, created_at, '
                'sender:profiles!coin_transfers_sender_id_fkey(name,username), '
                'recipient:profiles!coin_transfers_recipient_id_fkey(name,username)')
            .or('sender_id.eq.$me,recipient_id.eq.$me')
            .order('created_at', ascending: false)
            .limit(50) as List)
        .cast<Map<String, dynamic>>();
    return [
      for (final r in rows)
        (
          outgoing: r['sender_id'] == me,
          coins: (r['coins'] as num).toInt(),
          at: DateTime.tryParse(r['created_at'] as String? ?? '')?.toLocal(),
          note: r['note'] as String? ?? '',
          other: () {
            final p = (r['sender_id'] == me ? r['recipient'] : r['sender']) as Map?;
            return (p?['name'] as String?) ?? (p?['username'] as String?) ?? 'user';
          }(),
        ),
    ];
  }

  // ───────────────────────────────── KYC
  Future<String> kycStatus() async {
    final me = _me;
    if (me == null) return 'none';
    final row = await supabase
        .from('kyc_verifications')
        .select('status')
        .eq('profile_id', me)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    return (row?['status'] as String?) ?? 'none';
  }

  Future<void> submitKyc({required String documentType, String? documentUrl}) async {
    final me = _me;
    if (me == null) return;
    await supabase.from('kyc_verifications').insert({
      'profile_id': me,
      'document_type': documentType,
      'document_url': documentUrl,
    });
  }

  // ───────────────────────────────── notifications
  Future<List<AppNotification>> notifications() async {
    final me = _me;
    if (me == null) return const [];
    final rows = (await supabase
            .from('notifications')
            .select()
            .eq('profile_id', me)
            .order('created_at', ascending: false)
            .limit(100) as List)
        .cast<Map<String, dynamic>>();
    return [for (final r in rows) AppNotification.fromRow(r)];
  }

  Future<int> unreadNotificationCount() async {
    final me = _me;
    if (me == null) return 0;
    final rows = (await supabase
            .from('notifications')
            .select('id')
            .eq('profile_id', me)
            .eq('read', false)
            .limit(100) as List)
        .length;
    return rows;
  }

  Future<void> markNotificationRead(String id) =>
      supabase.from('notifications').update({'read': true}).eq('id', id);

  Future<void> markAllNotificationsRead() async {
    final me = _me;
    if (me == null) return;
    await supabase
        .from('notifications')
        .update({'read': true})
        .eq('profile_id', me)
        .eq('read', false);
  }
}
