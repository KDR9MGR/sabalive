import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';
import 'models.dart';

/// Real server-side state for a two-host PK battle. `pk_battles` is the
/// single source of truth (walks through every state from invite to
/// finish); the client never computes score, winner, or timing itself.
class PkBattleInfo {
  PkBattleInfo({
    required this.id,
    required this.streamAId,
    required this.streamBId,
    required this.hostAId,
    required this.hostBId,
    required this.status,
    required this.scoreA,
    required this.scoreB,
    this.startedAt,
    this.endsAt,
    this.winner,
  });

  factory PkBattleInfo.fromRow(Map<String, dynamic> r) => PkBattleInfo(
        id: r['id'] as String,
        streamAId: r['stream_a_id'] as String,
        streamBId: r['stream_b_id'] as String,
        hostAId: r['host_a_id'] as String,
        hostBId: r['host_b_id'] as String,
        status: r['status'] as String,
        scoreA: r['score_a'] as int? ?? 0,
        scoreB: r['score_b'] as int? ?? 0,
        startedAt: r['started_at'] == null ? null : DateTime.parse(r['started_at'] as String),
        endsAt: r['ends_at'] == null ? null : DateTime.parse(r['ends_at'] as String),
        winner: r['winner'] as String?,
      );

  final String id;
  final String streamAId;
  final String streamBId;
  final String hostAId;
  final String hostBId;
  final String status;
  final int scoreA;
  final int scoreB;
  final DateTime? startedAt;
  final DateTime? endsAt;
  final String? winner;

  String get agoraChannel => 'pk-$id';
  bool get isLive => status == 'live';
  bool get isTerminal => status == 'finished' || status == 'cancelled';

  /// Which side [myStreamId] is on — null if it's neither.
  String? sideFor(String myStreamId) {
    if (myStreamId == streamAId) return 'a';
    if (myStreamId == streamBId) return 'b';
    return null;
  }
}

/// Real PK battle backend — invite/accept, a shared session, and gift-driven
/// scoring, all enforced server-side via SECURITY DEFINER RPCs (never a raw
/// client write to `pk_battles`). Mirrors `calls_repository.dart`'s shape.
class PkBattlesRepository {
  String? get _me => supabase.auth.currentUser?.id;

  Future<PkBattleInfo> invite(String myStreamId, String targetStreamId) async {
    final row = await supabase.rpc('invite_pk_opponent', params: {
      'p_my_stream_id': myStreamId,
      'p_target_stream_id': targetStreamId,
    });
    return PkBattleInfo.fromRow(row as Map<String, dynamic>);
  }

  Future<PkBattleInfo> respond(String battleId, bool accept) async {
    final row = await supabase.rpc('respond_to_pk_invite', params: {
      'p_battle_id': battleId,
      'p_accept': accept,
    });
    return PkBattleInfo.fromRow(row as Map<String, dynamic>);
  }

  Future<void> cancel(String battleId) async {
    await supabase.rpc('cancel_pk_battle', params: {'p_battle_id': battleId});
  }

  Future<PkBattleInfo> begin(String battleId, {int durationSeconds = 300}) async {
    final row = await supabase.rpc('begin_pk_battle', params: {
      'p_battle_id': battleId,
      'p_duration_seconds': durationSeconds,
    });
    return PkBattleInfo.fromRow(row as Map<String, dynamic>);
  }

  Future<void> sendGift(String battleId, String side, Gift gift) async {
    await supabase.rpc('send_pk_gift', params: {
      'p_battle_id': battleId,
      'p_side': side,
      'p_gift_id': gift.id,
    });
  }

  Future<PkBattleInfo> finalizeNow(String battleId) async {
    final row = await supabase.rpc('finalize_pk_battle', params: {'p_battle_id': battleId});
    return PkBattleInfo.fromRow(row as Map<String, dynamic>);
  }

  /// The current non-terminal battle (if any) referencing [streamId] — used
  /// to recover state on screen entry/hot-reload without waiting for a
  /// Realtime event.
  Future<PkBattleInfo?> currentBattleFor(String streamId) async {
    final row = await supabase
        .from('pk_battles')
        .select()
        .or('stream_a_id.eq.$streamId,stream_b_id.eq.$streamId')
        .not('status', 'in', '(finished,cancelled)')
        .order('invited_at', ascending: false)
        .limit(1)
        .maybeSingle();
    return row == null ? null : PkBattleInfo.fromRow(row);
  }

  /// Fires whenever someone invites me (my stream is `host_b_id`).
  RealtimeChannel subscribeIncomingInvites(void Function(PkBattleInfo) onInvite) {
    final me = _me;
    return supabase
        .channel('pk-invites:$me')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'pk_battles',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'host_b_id',
            value: me,
          ),
          callback: (p) => onInvite(PkBattleInfo.fromRow(p.newRecord)),
        )
        .subscribe();
  }

  /// Watches one battle row for status/score transitions.
  RealtimeChannel subscribeBattle(String battleId, void Function(PkBattleInfo) onChange) {
    return supabase
        .channel('pk-battle:$battleId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'pk_battles',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: battleId,
          ),
          callback: (p) => onChange(PkBattleInfo.fromRow(p.newRecord)),
        )
        .subscribe();
  }

  /// Before my stream has a battle yet, this is how I learn one exists —
  /// unfiltered (mirrors LiveStreamsController's existing table-wide
  /// subscription), checked client-side against [streamId].
  RealtimeChannel subscribeDiscovery(String streamId, void Function(PkBattleInfo) onMatch) {
    return supabase
        .channel('pk-discovery:$streamId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'pk_battles',
          callback: (p) {
            final row = PkBattleInfo.fromRow(p.newRecord);
            if (row.streamAId == streamId || row.streamBId == streamId) onMatch(row);
          },
        )
        .subscribe();
  }

  Future<AppUser?> profile(String userId) async {
    final row = await supabase.from('profiles').select().eq('id', userId).maybeSingle();
    return row == null ? null : AppUser.fromRow(row);
  }
}
