import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';
import '../core/utils/ids.dart';
import 'models.dart';

enum CallKind { audio, video }

class CallInfo {
  CallInfo({
    required this.id,
    required this.callerId,
    required this.calleeId,
    required this.kind,
    required this.status,
    required this.channel,
    this.otherName = '',
  });

  factory CallInfo.fromRow(Map<String, dynamic> r) => CallInfo(
        id: r['id'] as String,
        callerId: r['caller_id'] as String,
        calleeId: r['callee_id'] as String,
        kind: (r['kind'] as String? ?? 'audio') == 'video'
            ? CallKind.video
            : CallKind.audio,
        status: r['status'] as String? ?? 'ringing',
        channel: r['channel'] as String? ?? '',
        otherName: r['other_name'] as String? ?? '',
      );

  final String id;
  final String callerId;
  final String calleeId;
  final CallKind kind;
  final String status;
  final String channel;
  final String otherName;

  bool isCaller(String? myId) => myId == callerId;
}

/// 1:1 call signalling over the `calls` table + Realtime. The actual media is
/// Agora (channel == calls.channel).
class CallsRepository {
  String? get _me => supabase.auth.currentUser?.id;

  Future<CallInfo> startCall(AppUser callee, {required CallKind kind}) async {
    final me = _me;
    if (me == null || !isRealId(callee.id)) {
      throw Exception('Cannot call this user');
    }
    final channel = 'call-${newUuid()}';
    final row = await supabase
        .from('calls')
        .insert({
          'caller_id': me,
          'callee_id': callee.id,
          'kind': kind == CallKind.video ? 'video' : 'audio',
          'channel': channel,
          'status': 'ringing',
        })
        .select()
        .single();
    return CallInfo.fromRow({...row, 'other_name': callee.name});
  }

  Future<void> setStatus(String callId, String status) async {
    final patch = <String, dynamic>{'status': status};
    if (status == 'accepted') patch['answered_at'] = DateTime.now().toUtc().toIso8601String();
    if (status == 'ended' || status == 'declined' || status == 'cancelled' || status == 'missed') {
      patch['ended_at'] = DateTime.now().toUtc().toIso8601String();
    }
    await supabase.from('calls').update(patch).eq('id', callId);
  }

  /// Fires whenever someone starts a call to me.
  RealtimeChannel subscribeIncoming(void Function(CallInfo) onCall) {
    final me = _me;
    return supabase
        .channel('calls:incoming:$me')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'calls',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'callee_id',
            value: me,
          ),
          callback: (p) => onCall(CallInfo.fromRow(p.newRecord)),
        )
        .subscribe();
  }

  /// Watches one call row for status transitions (accept / decline / end).
  RealtimeChannel subscribeCall(String callId, void Function(String status) onStatus) {
    return supabase
        .channel('calls:one:$callId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'calls',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: callId,
          ),
          callback: (p) => onStatus(p.newRecord['status'] as String? ?? 'ended'),
        )
        .subscribe();
  }

  Future<AppUser?> profile(String userId) async {
    final row =
        await supabase.from('profiles').select().eq('id', userId).maybeSingle();
    return row == null ? null : AppUser.fromRow(row);
  }
}
