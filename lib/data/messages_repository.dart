import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';
import 'models.dart';

/// Data access for direct messages: the inbox list, message requests, the
/// per-conversation thread + realtime subscription, and starting a new 1:1
/// conversation. Backed by `conversations` / `conversation_participants` /
/// `dm_messages` (see `supabase/migrations/*messaging*`).
class MessagesRepository {
  String get _me => supabase.auth.currentUser!.id;

  /// Accepted conversations (`requests: false`) or pending message requests
  /// (`requests: true`), newest activity first.
  Future<List<ConversationSummary>> inbox({required bool requests}) async {
    final me = _me;
    final mine = (await supabase
            .from('conversation_participants')
            .select('conversation_id, status, last_read_at')
            .eq('profile_id', me)
            .eq('status', requests ? 'pending' : 'accepted') as List)
        .cast<Map<String, dynamic>>();
    if (mine.isEmpty) return const [];

    final convIds = [for (final r in mine) r['conversation_id'] as String];

    final others = (await supabase
            .from('conversation_participants')
            .select('conversation_id, profiles!inner(*)')
            .inFilter('conversation_id', convIds)
            .neq('profile_id', me) as List)
        .cast<Map<String, dynamic>>();
    final otherByConv = <String, AppUser>{
      for (final r in others)
        r['conversation_id'] as String:
            AppUser.fromRow(r['profiles'] as Map<String, dynamic>),
    };

    final msgs = (await supabase
            .from('dm_messages')
            .select('conversation_id, body, kind, sender_id, created_at')
            .inFilter('conversation_id', convIds)
            .order('created_at', ascending: false) as List)
        .cast<Map<String, dynamic>>();
    final lastByConv = <String, Map<String, dynamic>>{};
    for (final m in msgs) {
      lastByConv.putIfAbsent(m['conversation_id'] as String, () => m);
    }

    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    final out = <ConversationSummary>[];
    for (final p in mine) {
      final cid = p['conversation_id'] as String;
      final other = otherByConv[cid];
      if (other == null) continue; // group / malformed — not shown yet
      final last = lastByConv[cid];
      final lastAt = last == null
          ? null
          : DateTime.tryParse(last['created_at'] as String)?.toLocal();
      final lastReadAt = p['last_read_at'] == null
          ? null
          : DateTime.tryParse(p['last_read_at'] as String)?.toLocal();
      final lastFromMe = last != null && last['sender_id'] == me;
      out.add(ConversationSummary(
        conversationId: cid,
        other: other,
        lastMessage: _preview(last),
        lastAt: lastAt,
        lastFromMe: lastFromMe,
        pending: p['status'] == 'pending',
        unread: last != null &&
            !lastFromMe &&
            (lastReadAt == null ||
                (lastAt != null && lastAt.isAfter(lastReadAt))),
      ));
    }
    out.sort((a, b) =>
        (b.lastAt ?? epoch).compareTo(a.lastAt ?? epoch));
    return out;
  }

  String _preview(Map<String, dynamic>? last) {
    if (last == null) return 'Say hi 👋';
    switch (last['kind'] as String? ?? 'text') {
      case 'gift':
        return '🎁 Sent a gift';
      case 'sticker':
        return 'Sent a sticker';
      default:
        final body = (last['body'] as String?)?.trim() ?? '';
        return body.isEmpty ? 'Message' : body;
    }
  }

  Future<void> acceptRequest(String conversationId) => supabase
      .from('conversation_participants')
      .update({'status': 'accepted'})
      .eq('conversation_id', conversationId)
      .eq('profile_id', _me);

  Future<void> declineRequest(String conversationId) => supabase
      .from('conversation_participants')
      .update({'status': 'declined'})
      .eq('conversation_id', conversationId)
      .eq('profile_id', _me);

  /// Free-text lookup for the "new message" composer.
  Future<List<AppUser>> searchUsers(String query) async {
    final q = query.trim().replaceAll(RegExp(r'[,()*]'), '');
    if (q.isEmpty) return const [];
    final rows = (await supabase
            .from('profiles')
            .select()
            .or('username.ilike.%$q%,name.ilike.%$q%')
            .neq('id', _me)
            .limit(20) as List)
        .cast<Map<String, dynamic>>();
    return [for (final r in rows) AppUser.fromRow(r)];
  }

  /// Returns the id of the existing 1:1 conversation with [other], or a newly
  /// created one (me `accepted`, them `pending`). The multi-row create runs in
  /// a SECURITY DEFINER function — see `20260906120000_start_conversation.sql`.
  Future<String> findOrCreateConversation(AppUser other) async {
    final id = await supabase
        .rpc('start_conversation', params: {'p_other_id': other.id});
    return id as String;
  }

  /// Creates a group conversation (all members auto-accepted) and returns its
  /// id. See `20260906160000_alpha_features.sql`.
  Future<String> startGroup(String name, List<String> memberIds) async {
    final id = await supabase.rpc('start_group_conversation', params: {
      'p_name': name,
      'p_member_ids': memberIds,
    });
    return id as String;
  }

  Future<List<Bubble>> messages(String conversationId) async {
    final me = _me;
    final rows = (await supabase
            .from('dm_messages')
            .select('*, profiles!dm_messages_sender_id_fkey(name)')
            .eq('conversation_id', conversationId)
            .order('created_at')
            .limit(300) as List)
        .cast<Map<String, dynamic>>();
    return [for (final r in rows) Bubble.fromRow(r, me)];
  }

  RealtimeChannel subscribeMessages(
    String conversationId,
    void Function(Bubble bubble) onInsert,
  ) {
    final me = _me;
    return supabase
        .channel('dm:$conversationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'dm_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: conversationId,
          ),
          callback: (payload) => onInsert(Bubble.fromRow(payload.newRecord, me)),
        )
        .subscribe();
  }

  Future<void> send(String conversationId, String body) => supabase
      .from('dm_messages')
      .insert({
        'conversation_id': conversationId,
        'sender_id': _me,
        'body': body,
        'kind': 'text',
      });

  Future<void> markRead(String conversationId) => supabase
      .from('conversation_participants')
      .update({'last_read_at': DateTime.now().toUtc().toIso8601String()})
      .eq('conversation_id', conversationId)
      .eq('profile_id', _me);
}
