import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';
import 'models.dart';

/// A host who can be invited right now (from `pk_eligible_following`).
class PkCandidate {
  const PkCandidate({
    required this.streamId,
    required this.hostId,
    required this.title,
    this.viewerCount = 0,
    this.mode = 'audio',
    this.hostName = '',
    this.hostAvatarUrl,
  });

  factory PkCandidate.fromRow(Map<String, dynamic> r) => PkCandidate(
    streamId: r['stream_id'] as String,
    hostId: r['host_id'] as String,
    title: r['title'] as String? ?? '',
    viewerCount: r['viewer_count'] as int? ?? 0,
    mode: r['mode'] as String? ?? 'audio',
    hostName: r['host_name'] as String? ?? '',
    hostAvatarUrl: r['host_avatar_url'] as String?,
  );

  final String streamId;
  final String hostId;
  final String title;
  final int viewerCount;
  final String mode;
  final String hostName;
  final String? hostAvatarUrl;
}

/// A live subscription to the battle rows of one live; [close] stops it.
abstract class PkBattleWatch {
  Future<void> close();
}

/// What the PK battle layer needs from the server. [PkBattlesRepository] is the real one; tests use a fake.
abstract class PkBattlesApi {
  Future<PkBattleInfo?> currentBattleFor(String streamId);
  Future<PkBattleInfo> inviteV2(String myStreamId, String targetStreamId, int durationSeconds);
  Future<List<PkCandidate>> eligibleFollowing(String myStreamId);

  /// Null = still searching; a battle = matched (already accepted).
  Future<PkBattleInfo?> randomJoin(String myStreamId);
  Future<void> randomLeave(String myStreamId);
  Future<PkBattleInfo> respond(String battleId, bool accept);
  Future<void> cancel(String battleId);
  Future<PkBattleInfo> beginV2(String battleId);
  Future<PkBattleInfo> finalizeNow(String battleId);

  /// The host ends a live battle by giving up: the other host wins (reason 'forfeit').
  Future<PkBattleInfo> giveUp(String battleId);
  Future<void> sendGift(String battleId, String side, Gift gift);
  Future<void> setReady(String streamId, bool ready);

  /// The server's clock, so a countdown does not depend on the phone's.
  Future<DateTime> serverNow();
  Future<AppUser?> profile(String userId);

  /// Every change (new row or update) of a battle that has [streamId] as one of its two lives.
  PkBattleWatch watchStream(String streamId, void Function(PkBattleInfo) onRow);
}

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
    this.lastGiftId,
    this.lastGiftSide,
    this.lastGiftSeq = 0,
    this.durationSeconds = 300,
    this.kind,
    this.source,
    this.endReason,
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
    startedAt: r['started_at'] == null
        ? null
        : DateTime.parse(r['started_at'] as String),
    endsAt: r['ends_at'] == null
        ? null
        : DateTime.parse(r['ends_at'] as String),
    winner: r['winner'] as String?,
    lastGiftId: r['last_gift_id'] as String?,
    lastGiftSide: r['last_gift_side'] as String?,
    lastGiftSeq: r['last_gift_seq'] as int? ?? 0,
    durationSeconds: r['duration_seconds'] as int? ?? 300,
    kind: r['kind'] as String?,
    source: r['source'] as String?,
    endReason: r['end_reason'] as String?,
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

  /// Piggybacks on this same realtime-subscribed row (rather than a
  /// separate ephemeral broadcast channel) so a gift landing is visible to
  /// both hosts and every viewer on both sides — lastGiftSeq always
  /// increments, so a repeat of the same gift/side is still detectable as
  /// a new event.
  final String? lastGiftId;
  final String? lastGiftSide;
  final int lastGiftSeq;

  /// How long the battle lasts once begun (set at invite time by the server), 'audio' / 'video' (null = a legacy PK-mode
  /// battle), 'invite' / 'random' (null = legacy) and why it ended ('forfeit' when a host left; null on older rows).
  final int durationSeconds;
  final String? kind;
  final String? source;
  final String? endReason;

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
class PkBattlesRepository implements PkBattlesApi {
  String? get _me => supabase.auth.currentUser?.id;

  // ---- the PK battle layer (migrations 20261017100000 / 20261017110000) ----
  @override
  Future<void> setReady(String streamId, bool ready) async {
    await supabase.rpc('pk_set_ready', params: {'p_stream_id': streamId, 'p_ready': ready});
  }

  @override
  Future<PkBattleInfo> inviteV2(String myStreamId, String targetStreamId, int durationSeconds) async {
    final row = await supabase.rpc(
      'pk_invite_v2',
      params: {'p_my_stream_id': myStreamId, 'p_target_stream_id': targetStreamId, 'p_duration_seconds': durationSeconds},
    );
    return PkBattleInfo.fromRow(Map<String, dynamic>.from(row as Map));
  }

  @override
  Future<List<PkCandidate>> eligibleFollowing(String myStreamId) async {
    final rows = await supabase.rpc('pk_eligible_following', params: {'p_my_stream_id': myStreamId});
    return [for (final r in (rows as List? ?? const [])) PkCandidate.fromRow(Map<String, dynamic>.from(r as Map))];
  }

  @override
  Future<PkBattleInfo?> randomJoin(String myStreamId) async {
    final row = await supabase.rpc('pk_random_join', params: {'p_my_stream_id': myStreamId});
    return row == null ? null : PkBattleInfo.fromRow(Map<String, dynamic>.from(row as Map));
  }

  @override
  Future<void> randomLeave(String myStreamId) async {
    await supabase.rpc('pk_random_leave', params: {'p_my_stream_id': myStreamId});
  }

  @override
  Future<PkBattleInfo> beginV2(String battleId) async {
    final row = await supabase.rpc('pk_begin_v2', params: {'p_battle_id': battleId});
    return PkBattleInfo.fromRow(Map<String, dynamic>.from(row as Map));
  }

  @override
  Future<DateTime> serverNow() async {
    final v = await supabase.rpc('pk_now');
    return DateTime.parse(v as String).toUtc();
  }

  /// ONE channel for this live with a filtered listener per column and event (insert and update on `stream_a_id` and on
  /// `stream_b_id`): the server sends this live's rows only, not every battle on the platform (the legacy
  /// [subscribeDiscovery] is unfiltered, which is fine for a handful of PK lives and not for every live).
  @override
  PkBattleWatch watchStream(String streamId, void Function(PkBattleInfo) onRow) {
    var channel = supabase.channel('pk-layer:$streamId');
    for (final event in [PostgresChangeEvent.insert, PostgresChangeEvent.update]) {
      for (final column in ['stream_a_id', 'stream_b_id']) {
        channel = channel.onPostgresChanges(
          event: event,
          schema: 'public',
          table: 'pk_battles',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: column, value: streamId),
          callback: (p) => onRow(PkBattleInfo.fromRow(p.newRecord)),
        );
      }
    }
    channel.subscribe();
    return _RealtimeWatch(channel);
  }

  Future<PkBattleInfo> invite(String myStreamId, String targetStreamId) async {
    final row = await supabase.rpc(
      'invite_pk_opponent',
      params: {
        'p_my_stream_id': myStreamId,
        'p_target_stream_id': targetStreamId,
      },
    );
    return PkBattleInfo.fromRow(row as Map<String, dynamic>);
  }

  @override
  Future<PkBattleInfo> respond(String battleId, bool accept) async {
    final row = await supabase.rpc(
      'respond_to_pk_invite',
      params: {'p_battle_id': battleId, 'p_accept': accept},
    );
    return PkBattleInfo.fromRow(row as Map<String, dynamic>);
  }

  @override
  Future<void> cancel(String battleId) async {
    await supabase.rpc('cancel_pk_battle', params: {'p_battle_id': battleId});
  }

  Future<PkBattleInfo> begin(
    String battleId, {
    int durationSeconds = 300,
  }) async {
    final row = await supabase.rpc(
      'begin_pk_battle',
      params: {'p_battle_id': battleId, 'p_duration_seconds': durationSeconds},
    );
    return PkBattleInfo.fromRow(row as Map<String, dynamic>);
  }

  @override
  Future<void> sendGift(String battleId, String side, Gift gift) async {
    await supabase.rpc(
      'send_pk_gift',
      params: {'p_battle_id': battleId, 'p_side': side, 'p_gift_id': gift.id},
    );
  }

  @override
  Future<PkBattleInfo> giveUp(String battleId) async {
    final row = await supabase.rpc(
      'pk_give_up_v2',
      params: {'p_battle_id': battleId},
    );
    return PkBattleInfo.fromRow(row as Map<String, dynamic>);
  }

  @override
  Future<PkBattleInfo> finalizeNow(String battleId) async {
    final row = await supabase.rpc(
      'finalize_pk_battle',
      params: {'p_battle_id': battleId},
    );
    return PkBattleInfo.fromRow(row as Map<String, dynamic>);
  }

  /// The current non-terminal battle (if any) referencing [streamId] — used
  /// to recover state on screen entry/hot-reload without waiting for a
  /// Realtime event.
  @override
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
  RealtimeChannel subscribeIncomingInvites(
    void Function(PkBattleInfo) onInvite,
  ) {
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
  RealtimeChannel subscribeBattle(
    String battleId,
    void Function(PkBattleInfo) onChange,
  ) {
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
  RealtimeChannel subscribeDiscovery(
    String streamId,
    void Function(PkBattleInfo) onMatch,
  ) {
    return supabase
        .channel('pk-discovery:$streamId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'pk_battles',
          callback: (p) {
            final row = PkBattleInfo.fromRow(p.newRecord);
            if (row.streamAId == streamId || row.streamBId == streamId)
              onMatch(row);
          },
        )
        .subscribe();
  }

  @override
  Future<AppUser?> profile(String userId) async {
    final row = await supabase
        .from('profiles')
        .select()
        .eq('id', userId)
        .maybeSingle();
    return row == null ? null : AppUser.fromRow(row);
  }
}

class _RealtimeWatch implements PkBattleWatch {
  _RealtimeWatch(this._channel);
  final RealtimeChannel _channel;

  @override
  Future<void> close() async {
    await _channel.unsubscribe();
  }
}
