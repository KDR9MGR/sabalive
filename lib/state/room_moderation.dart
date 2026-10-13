import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';
import '../core/utils/errors.dart';
import '../data/live_moderation_repository.dart';

/// Why the host (or an admin) took someone out of the live.
enum RemovalReason { kicked, banned }

/// Who may moderate one live and what has been done in it, kept live: the host's room admins, whose chat is off, and
/// the signals that tell THIS phone it was kicked, banned or had its chat turned off.
///
/// One per live screen. The host and the host's admins are "moderators"; the server decides what each may do, this
/// only decides what to offer (a tool a moderator can't use is not shown).
class RoomModeration extends ChangeNotifier {
  RoomModeration({
    required this.streamId,
    required this.hostId,
    required this.myId,
    this.onRemoved,
    LiveModerationRepository? repo,
    this.listen = true,
  }) : repo = repo ?? LiveModerationRepository();

  final String streamId;
  final String hostId;
  final String? myId;
  final LiveModerationRepository repo;

  /// Called (once) when this phone is kicked or banned out of the live.
  final void Function(RemovalReason reason)? onRemoved;

  /// False in tests: no Realtime channel is opened.
  final bool listen;

  Set<String> _admins = {};
  Set<String> _chatOff = {};
  bool _serverHasModeration = true;
  RealtimeChannel? _channel;
  bool _removed = false;
  bool _disposed = false;

  Set<String> get admins => Set.unmodifiable(_admins);

  /// False when the server answered that it has no room admins / text bans yet (the app is newer than the server's
  /// last update). The screens then leave those tools out instead of showing an error on every tap.
  bool get serverHasModeration => _serverHasModeration;

  bool get iAmHost => myId != null && myId == hostId;
  bool isAdmin(String id) => _admins.contains(id);
  bool get iAmAdmin => myId != null && _admins.contains(myId);

  /// The host or one of the host's room admins.
  bool get iAmModerator => iAmHost || iAmAdmin;

  /// This person's chat is off for the live.
  bool isChatOff(String id) => _chatOff.contains(id);

  /// My own chat is off.
  bool get chatOff => myId != null && _chatOff.contains(myId);

  /// Whether I may act on [userId] (not myself, never the host, and an admin only on people who are not admins).
  bool canModerate(String userId) {
    if (!iAmModerator || userId == myId || userId == hostId) return false;
    if (!iAmHost && _admins.contains(userId)) return false;
    return true;
  }

  Future<void> start() async {
    await _load();
    if (listen && !_disposed) _subscribe();
  }

  Future<void> _load() async {
    try {
      final admins = await repo.adminsOf(hostId);
      final off = await repo.chatOffIn(streamId);
      if (_disposed) return;
      _admins = admins;
      _chatOff = off;
      notifyListeners();
    } catch (e) {
      // not reachable: the live works without it. If the server says it has no such tables / functions, remember
      // that, so the tools that need them are not offered.
      if (isMissingOnServer(e) && !_disposed && _serverHasModeration) {
        _serverHasModeration = false;
        notifyListeners();
      }
    }
  }

  void _subscribe() {
    final me = myId;
    var ch = supabase.channel('room-mod:$streamId:${me ?? 'anon'}')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'live_room_admins',
        filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'host_id', value: hostId),
        callback: (p) => applyAdmin(p.newRecord['admin_id'] as String?, true),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.delete,
        schema: 'public',
        table: 'live_room_admins',
        // Realtime can't filter a delete: keep only this host's
        callback: (p) {
          if (p.oldRecord['host_id'] == hostId) applyAdmin(p.oldRecord['admin_id'] as String?, false);
        },
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'live_chat_mutes',
        filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'live_stream_id', value: streamId),
        callback: (p) => applyChatOff(p.newRecord['user_id'] as String?, true),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.delete,
        schema: 'public',
        table: 'live_chat_mutes',
        callback: (p) {
          if (p.oldRecord['live_stream_id'] == streamId) applyChatOff(p.oldRecord['user_id'] as String?, false);
        },
      );
    if (me != null) {
      ch = ch
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'live_stream_kicks',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: me),
          callback: (p) {
            if (p.newRecord['live_stream_id'] == streamId) removed(RemovalReason.kicked);
          },
        )
        ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'live_stream_viewer_bans',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: me),
          callback: (p) {
            if (p.newRecord['live_stream_id'] == streamId) removed(RemovalReason.banned);
          },
        );
    }
    _channel = ch.subscribe((status, [error]) {
      // a (re)connected channel replays nothing it missed
      if (status == RealtimeSubscribeStatus.subscribed) unawaited(_load());
    });
  }

  // ---- the things that happen (also what the Realtime callbacks call; public so they can be tested)

  @visibleForTesting
  void applyAdmin(String? id, bool on) {
    if (id == null || _disposed) return;
    final changed = on ? _admins.add(id) : _admins.remove(id);
    if (changed) notifyListeners();
  }

  @visibleForTesting
  void applyChatOff(String? id, bool off) {
    if (id == null || _disposed) return;
    final changed = off ? _chatOff.add(id) : _chatOff.remove(id);
    if (changed) notifyListeners();
  }

  @visibleForTesting
  void removed(RemovalReason reason) {
    if (_removed || _disposed) return;
    _removed = true;
    onRemoved?.call(reason);
  }

  // ---- the actions a moderator takes; each updates what the screen shows straight away

  Future<void> kick(String userId) => repo.kick(streamId, userId);

  Future<void> ban(String userId) => repo.ban(streamId, userId);

  Future<void> setChatOff(String userId, bool off) async {
    await repo.setChatOff(streamId, userId, off);
    applyChatOff(userId, off);
  }

  Future<void> setAdmin(String userId, bool on) async {
    await repo.setAdmin(userId, on);
    applyAdmin(userId, on);
  }

  @override
  void dispose() {
    _disposed = true;
    _channel?.unsubscribe();
    super.dispose();
  }
}
