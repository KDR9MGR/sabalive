import 'dart:async';
import 'dart:math' as math;

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../config/supabase_client.dart';
import '../../core/utils/errors.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/ids.dart';
import '../../core/utils/share_sheet.dart';
import '../../core/utils/viewer_list_sheet.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/app_thumb.dart';
import '../../core/widgets/connection_banner.dart';
import '../../core/widgets/pills.dart';
import '../../data/mock_data.dart';
import '../../data/live_emojis_repository.dart';
import '../../data/models.dart';
import '../../data/store_repository.dart';
import '../../data/stream_end_watcher.dart';
import '../../router/app_nav.dart';
import '../messages/messages_screen.dart';
import '../../services/agora_service.dart';
import '../../state/active_live_session_controller.dart';
import '../../state/auth_controller.dart';
import '../../state/session_controller.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';
import 'widgets/room_effect.dart';
import 'widgets/gift_sheet.dart';
import 'widgets/live_emoji_sheet.dart';
import 'widgets/live_chat_bubble.dart';
import 'widgets/live_minimized_bubble.dart';
import 'widgets/seat_room.dart';
import 'widgets/tool_grid.dart';

class WatchLiveScreen extends StatefulWidget {
  const WatchLiveScreen({super.key, required this.stream});
  final LiveStream stream;

  @override
  State<WatchLiveScreen> createState() => _WatchLiveScreenState();
}

class _WatchLiveScreenState extends State<WatchLiveScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final bool _isReal = isRealId(widget.stream.id);
  void Function()? _stopEndWatch;
  bool _hostEndedHandled = false;
  final List<LiveChatLine> _chat = [];
  final _msgController = TextEditingController();
  final _rand = math.Random();
  final List<_Heart> _hearts = [];
  final _effects = RoomEffectController();
  int _likes = 0;

  RtcEngine? _engine;
  int? _remoteUid;
  // Multiple broadcasters can now be in this channel (host + seat-holders),
  // so onUserJoined alone can't tell them apart — track everyone who's
  // currently joined and pick the host's uid out of that set once known.
  final Set<int> _joinedUids = {};
  int? _hostAgoraUid;
  RealtimeChannel? _chatChannel;
  String? _joinError;
  bool _reconnecting = false;
  Timer? _waitTimer;
  bool _waitingTooLong = false;

  // Real, synced seat state — viewers can sit in a video stream too now,
  // mic-only (no camera track). Unlike the audio room, an empty seat here
  // needs the host's approval (request_pk_seat/approve_pk_seat_request,
  // same flow PK battles use) rather than self-serve claim_seat.
  final Map<int, AppUser> _seatOccupants = {};
  Set<int> _lockedSeats = {};
  final Set<int> _mutedSeats = {};
  late int _seatCount = widget.stream.seatCount;
  RealtimeChannel? _seatsChannel;
  RealtimeChannel? _seatStreamChannel;
  bool _seatBusy = false;
  int? _mySeat;
  bool _myMuted = false;
  Timer? _heartbeat;

  // widget.stream.viewers is a one-time snapshot from whenever this stream
  // object was fetched (e.g. the live feed) — it never changes on its own,
  // so the "N watching" display looked frozen for the whole session. This
  // mirrors the host's own broadcast screen, which already tracks it live.
  late int _viewerCount = widget.stream.viewers;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _likes = widget.stream.likes;
    _hostAgoraUid = widget.stream.hostAgoraUid;
    if (_isReal) {
      // Keeps the screen from sleeping mid-stream — a screen timeout was
      // dropping the Agora connection and the viewer's own heartbeat/seat
      // timers (Android suspends both once the display turns off), which
      // looked like random disconnects with no error at all.
      WakelockPlus.enable().catchError((_) {});
      _joinReal();
      _loadRealChat();
      _logViewerJoin();
      _subscribeSeats();
      _stopEndWatch = watchStreamEnd(widget.stream.id, _onHostEnded);
      _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
        // These used to be pure fire-and-forget with no error handling at
        // all — a silently-failed heartbeat_seat looks identical to a real
        // disconnect from the finalize_stale_presence cron's point of view,
        // and on some OEM Android skins (ColorOS/RealmeUI in particular)
        // background network calls can get throttled independently of the
        // screen wakelock. At minimum this now surfaces the failure.
        supabase
            .rpc('heartbeat_viewer', params: {'p_stream_id': widget.stream.id})
            .catchError((e) => debugPrint('heartbeat_viewer failed: $e'));
        if (_mySeat != null) {
          supabase
              .rpc('heartbeat_seat', params: {'p_stream_id': widget.stream.id})
              .catchError((e) => debugPrint('heartbeat_seat failed: $e'));
        }
      });
    } else {
      _chat.addAll(Mock.liveChat());
    }
  }

  /// Live seat occupancy, locks, count, and mute state — identical shape to
  /// watch_audio_room_screen.dart's subscription, just for a video stream.
  Future<void> _subscribeSeats() async {
    final rows = await supabase
        .from('live_stream_seats')
        .select(
          'seat_number, is_muted, profiles!live_stream_seats_occupant_id_fkey(*)',
        )
        .eq('live_stream_id', widget.stream.id);
    final streamRow = await supabase
        .from('live_streams')
        .select('locked_seats, seat_count, host_agora_uid')
        .eq('id', widget.stream.id)
        .maybeSingle();
    if (mounted) {
      final myId = supabase.auth.currentUser?.id;
      setState(() {
        for (final r in rows as List) {
          final profileRow = r['profiles'] as Map<String, dynamic>?;
          if (profileRow != null) {
            final seat = r['seat_number'] as int;
            _seatOccupants[seat] = AppUser.fromRow(profileRow);
            if (r['is_muted'] as bool? ?? false) _mutedSeats.add(seat);
            // Without this, reopening the screen while already seated (a
            // reconnect, a hot navigation back, etc.) never restores
            // _mySeat — it was only ever set by the INSERT callback below,
            // so this client wouldn't recognize its own seat being deleted
            // later and would miss the "removed from your seat" handling.
            if (profileRow['id'] == myId) _mySeat = seat;
          }
        }
        final locked = streamRow?['locked_seats'] as List?;
        if (locked != null) _lockedSeats = locked.cast<int>().toSet();
        final count = streamRow?['seat_count'] as int?;
        if (count != null) _seatCount = count;
        _hostAgoraUid = streamRow?['host_agora_uid'] as int? ?? _hostAgoraUid;
        _recomputeRemoteUid();
      });
    }
    _seatsChannel = supabase
        .channel('live-seats-${widget.stream.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'live_stream_seats',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'live_stream_id',
            value: widget.stream.id,
          ),
          callback: (payload) async {
            final seat = payload.newRecord['seat_number'] as int;
            final occupantId = payload.newRecord['occupant_id'] as String;
            final profileRow = await supabase
                .from('profiles')
                .select()
                .eq('id', occupantId)
                .maybeSingle();
            if (mounted && profileRow != null) {
              setState(() {
                _seatOccupants[seat] = AppUser.fromRow(profileRow);
                _mutedSeats.remove(seat);
              });
            }
            // My own pending request just got approved by the host — this is
            // the only place that seat assignment becomes known to me, since
            // approve_pk_seat_request runs on the HOST's device. Start
            // actually publishing mic audio now that I'm really seated.
            if (mounted &&
                occupantId == supabase.auth.currentUser?.id &&
                _mySeat != seat) {
              setState(() => _mySeat = seat);
              final engine = _engine;
              if (engine != null) {
                await AgoraService.instance.switchRole(
                  engine,
                  channelName: widget.stream.id,
                  asBroadcaster: true,
                );
              }
              // approve_pk_seat_request already stamps last_heartbeat_at at
              // insert time, but the periodic timer above won't necessarily
              // tick again for up to 30s — sending one right away narrows
              // the window before the next tick has to land cleanly to stay
              // under finalize_stale_presence's 90s threshold.
              supabase
                  .rpc(
                    'heartbeat_seat',
                    params: {'p_stream_id': widget.stream.id},
                  )
                  .catchError((e) => debugPrint('heartbeat_seat failed: $e'));
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'live_stream_seats',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'live_stream_id',
            value: widget.stream.id,
          ),
          callback: (payload) {
            final seat = payload.newRecord['seat_number'] as int?;
            final muted = payload.newRecord['is_muted'] as bool?;
            // heartbeat_seat touches this same row every ~30s (it's a plain
            // UPDATE on last_heartbeat_at) and Postgres always broadcasts
            // the full row, so this callback fires constantly for every
            // seated person even when is_muted hasn't actually changed —
            // skip the rebuild entirely when nothing observable did.
            if (mounted &&
                seat != null &&
                muted != null &&
                muted != _mutedSeats.contains(seat)) {
              setState(() {
                if (muted) {
                  _mutedSeats.add(seat);
                } else {
                  _mutedSeats.remove(seat);
                }
              });
              // Covers both the self-mute echo and the host forcing a mute —
              // either way, the DB row is the source of truth, so bring the
              // real mic state in line with it rather than only updating the
              // icon (a host-forced mute previously showed the muted icon
              // while the mic stayed live).
              if (seat == _mySeat && muted != _myMuted) {
                setState(() => _myMuted = muted);
                _engine?.muteLocalAudioStream(muted);
              }
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'live_stream_seats',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'live_stream_id',
            value: widget.stream.id,
          ),
          callback: (payload) {
            final seat = payload.oldRecord['seat_number'] as int?;
            if (mounted && seat != null) {
              final wasMe = _mySeat == seat;
              setState(() {
                _seatOccupants.remove(seat);
                _mutedSeats.remove(seat);
                if (wasMe) {
                  _mySeat = null;
                  _myMuted = false;
                }
              });
              if (wasMe) {
                final engine = _engine;
                if (engine != null) {
                  AgoraService.instance.switchRole(
                    engine,
                    channelName: widget.stream.id,
                    asBroadcaster: false,
                  );
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('The host removed you from your seat'),
                  ),
                );
              }
            }
          },
        )
        .subscribe();
    _seatStreamChannel = supabase
        .channel('live-seatlocks-${widget.stream.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'live_streams',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: widget.stream.id,
          ),
          callback: (payload) {
            final locked = payload.newRecord['locked_seats'] as List?;
            final count = payload.newRecord['seat_count'] as int?;
            final hostUid = payload.newRecord['host_agora_uid'] as int?;
            final viewers = payload.newRecord['viewer_count'] as int?;
            if (!mounted) return;
            setState(() {
              if (locked != null) _lockedSeats = locked.cast<int>().toSet();
              if (count != null) _seatCount = count;
              if (hostUid != null) _hostAgoraUid = hostUid;
              if (viewers != null) _viewerCount = viewers;
              _recomputeRemoteUid();
            });
          },
        )
        .subscribe();
  }

  /// Picks which joined broadcaster's video the viewer should actually see.
  /// Prefers the known host uid; if it isn't known yet, falls back to
  /// whoever joined first so a fresh viewer isn't stuck on a blank screen
  /// waiting on a Realtime round-trip that may not have landed yet.
  void _recomputeRemoteUid() {
    final hostUid = _hostAgoraUid;
    if (hostUid != null) {
      _remoteUid = _joinedUids.contains(hostUid) ? hostUid : null;
    } else {
      _remoteUid = _joinedUids.isNotEmpty ? _joinedUids.first : null;
    }
  }

  Future<void> _seatTap(int seat) async {
    if (!_isReal || _seatBusy) return;
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;
    final occupant = _seatOccupants[seat];
    final messenger = ScaffoldMessenger.of(context);

    if (occupant?.id == myId) {
      setState(() => _seatBusy = true);
      try {
        await supabase.rpc(
          'release_seat',
          params: {'p_stream_id': widget.stream.id},
        );
        final engine = _engine;
        if (engine != null) {
          await AgoraService.instance.switchRole(
            engine,
            channelName: widget.stream.id,
            asBroadcaster: false,
          );
        }
        if (mounted) {
          setState(() {
            _seatOccupants.remove(seat);
            _mySeat = null;
            _myMuted = false;
          });
        }
      } catch (e) {
        if (mounted) {
          messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
        }
      } finally {
        if (mounted) setState(() => _seatBusy = false);
      }
      return;
    }
    if (occupant != null) {
      messenger.showSnackBar(SnackBar(content: Text('Seat $seat is taken')));
      return;
    }
    if (_lockedSeats.contains(seat)) {
      messenger.showSnackBar(SnackBar(content: Text('Seat $seat is locked')));
      return;
    }

    setState(() => _seatBusy = true);
    try {
      // Video seats are host-approval-gated (same request_pk_seat/
      // approve_pk_seat_request flow PK battles use) — actually publishing
      // mic audio happens once the approval lands via the seat INSERT
      // Realtime callback above, not here.
      await supabase.rpc(
        'request_pk_seat',
        params: {'p_stream_id': widget.stream.id},
      );
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Request sent — waiting for the host')),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _seatBusy = false);
    }
  }

  Future<void> _toggleMyMute() async {
    final next = !_myMuted;
    setState(() => _myMuted = next);
    try {
      await _engine?.muteLocalAudioStream(next);
      await supabase.rpc(
        'set_seat_mute',
        params: {'p_stream_id': widget.stream.id, 'p_muted': next},
      );
    } catch (e) {
      if (mounted) {
        setState(() => _myMuted = !next);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  /// Logs presence in `live_stream_viewers`, which a trigger uses to keep
  /// `live_streams.viewer_count` accurate — Agora's own onUserJoined isn't
  /// reliable for this: its Live Broadcasting profile doesn't report
  /// audience-role joins to other participants (by design, for scale), so
  /// the host was never actually finding out a viewer had shown up.
  Future<void> _logViewerJoin() async {
    try {
      await supabase.rpc(
        'join_live_stream',
        params: {'p_stream_id': widget.stream.id},
      );
    } catch (_) {
      /* best-effort — a missed count beats a broken screen */
    }
  }

  Future<void> _joinReal() async {
    try {
      final engine = await AgoraService.instance.ensureEngine();
      final token = await AgoraService.instance.fetchToken(
        channelName: widget.stream.id,
        asBroadcaster: false,
      );
      engine.registerEventHandler(
        RtcEngineEventHandler(
          onUserJoined: (connection, remoteUid, elapsed) {
            _waitTimer?.cancel();
            _joinedUids.add(remoteUid);
            if (mounted) {
              setState(() {
                _waitingTooLong = false;
                _recomputeRemoteUid();
              });
            }
          },
          onUserOffline: (connection, remoteUid, reason) {
            _joinedUids.remove(remoteUid);
            if (mounted) setState(_recomputeRemoteUid);
          },
          onError: (err, msg) {
            if (mounted) setState(() => _joinError = msg);
          },
          onConnectionStateChanged: (connection, state, reason) {
            if (mounted) {
              setState(
                () => _reconnecting =
                    state == ConnectionStateType.connectionStateReconnecting,
              );
            }
          },
        ),
      );
      AgoraService.instance.registerAutoTokenRenewal(
        engine,
        channelName: widget.stream.id,
        asBroadcaster: false,
      );
      await engine.joinChannel(
        token: token.token,
        channelId: token.channelName,
        uid: token.uid,
        options: const ChannelMediaOptions(
          channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
          clientRoleType: ClientRoleType.clientRoleAudience,
          // Left unset (null) these default to "on" per Agora's docs, but
          // that default has been unreliable across native platform-channel
          // serialization in some SDK builds — audience joins the channel
          // fine but never actually receives the host's tracks. Explicit
          // beats implicit here.
          autoSubscribeAudio: true,
          autoSubscribeVideo: true,
          publishCameraTrack: false,
          publishMicrophoneTrack: false,
        ),
      );
      if (mounted) setState(() => _engine = engine);
      // Joined the channel fine, but if no remote user shows up in a
      // reasonable window, that's a real signal worth surfacing distinctly
      // from "still connecting" — most likely the host has ended, or (if
      // this keeps happening) a join/subscribe bug worth another look.
      _waitTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && _remoteUid == null)
          setState(() => _waitingTooLong = true);
      });
    } catch (e) {
      if (mounted) setState(() => _joinError = friendlyError(e));
    }
  }

  Future<void> _loadRealChat() async {
    final rows = await supabase
        .from('live_chat_messages')
        .select()
        .eq('live_stream_id', widget.stream.id)
        .order('created_at', ascending: false)
        .limit(30);
    final senderIds = {for (final r in rows) r['sender_id'] as String};
    final profiles = senderIds.isEmpty
        ? <String, AppUser>{}
        : {
            for (final row
                in await supabase
                    .from('profiles')
                    .select()
                    .inFilter('id', senderIds.toList()))
              row['id'] as String: AppUser.fromRow(row),
          };
    if (!mounted) return;
    setState(() {
      _chat.addAll([
        for (final row in rows.reversed) _chatLineFromRow(row, profiles),
      ]);
    });
    // If our own join row landed before this screen began listening, our own
    // entry effect would otherwise be missed.
    final meId = context.read<AuthController>().user?.id;
    for (final row in rows.reversed) {
      unawaited(
        _effects.handleRow(
          row,
          meId: meId,
          senderName: 'You',
          giftById: (_) => null,
          loadItems: StoreRepository().itemsByIds,
          history: true,
        ),
      );
    }

    _chatChannel = supabase
        .channel('live-chat-${widget.stream.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'live_chat_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'live_stream_id',
            value: widget.stream.id,
          ),
          callback: (payload) async {
            final senderId = payload.newRecord['sender_id'] as String;
            final profileRow = await supabase
                .from('profiles')
                .select()
                .eq('id', senderId)
                .maybeSingle();
            final sender = profileRow != null
                ? AppUser.fromRow(profileRow)
                : AppUser(id: senderId, name: 'Someone', username: '@user');
            if (!mounted) return;
            // A gift or an entry from someone: play it on screen, not just as
            // a line.
            final wallet = context.read<WalletController>();
            unawaited(
              _effects.handleRow(
                payload.newRecord,
                meId: context.read<AuthController>().user?.id,
                senderName: sender.name,
                giftById: wallet.giftById,
                loadItems: StoreRepository().itemsByIds,
              ),
            );
            setState(
              () => _chat.add(
                _chatLineFromRow(payload.newRecord, {sender.id: sender}),
              ),
            );
          },
        )
        .subscribe();
  }

  LiveChatLine _chatLineFromRow(
    Map<String, dynamic> row,
    Map<String, AppUser> profiles,
  ) {
    final sender =
        profiles[row['sender_id']] ??
        AppUser(
          id: row['sender_id'] as String,
          name: 'Someone',
          username: '@user',
        );
    return LiveChatLine(
      sender,
      row['body'] as String,
      gift: row['kind'] == 'gift',
      system: row['kind'] == 'system',
      pinned: row['pinned'] as bool? ?? false,
      stickerUrl: row['kind'] == 'sticker' ? row['sticker_url'] as String? : null,
    );
  }

  /// See the same note in watch_audio_room_screen.dart — dispose() alone
  /// only covers a clean in-app exit; backgrounding/kill skips it, leaving
  /// a seat stuck occupied until the stale-presence cron sweep.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isReal &&
        _mySeat != null &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached)) {
      unawaited(
        supabase.rpc('release_seat', params: {'p_stream_id': widget.stream.id}),
      );
      _mySeat = null;
    }
  }

  /// This screen is mounted by the app-root overlay in app.dart, not
  /// pushed as a Navigator route — see live_broadcast_screen.dart's own
  /// didPopRoute() for why WidgetsBindingObserver (already mixed in here
  /// for the app-lifecycle handling above), not PopScope/BackButtonListener,
  /// is what intercepts the system back button/gesture.
  @override
  Future<bool> didPopRoute() async {
    if (!mounted) return false;
    if (context.read<ActiveLiveSessionController>().isMinimized) {
      return false;
    }
    await _showCloseDialog();
    return true;
  }

  /// The host ended the live (or it was ended as stale): take this viewer out
  /// of the room instead of leaving them on a dead stream.
  void _onHostEnded() {
    if (_hostEndedHandled || !mounted) return;
    _hostEndedHandled = true;
    final messenger = ScaffoldMessenger.of(context);
    final liveSession = context.read<ActiveLiveSessionController>();
    messenger.showSnackBar(
      SnackBar(content: Text('${widget.stream.host.name} ended the live')),
    );
    liveSession.end();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopEndWatch?.call();
    _waitTimer?.cancel();
    _heartbeat?.cancel();
    _msgController.dispose();
    _effects.dispose();
    _chatChannel?.unsubscribe();
    _seatsChannel?.unsubscribe();
    _seatStreamChannel?.unsubscribe();
    if (_isReal) {
      WakelockPlus.disable().catchError((_) {});
      AgoraService.instance.release();
      unawaited(
        supabase.rpc(
          'leave_live_stream',
          params: {'p_stream_id': widget.stream.id},
        ),
      );
      unawaited(
        supabase.rpc('release_seat', params: {'p_stream_id': widget.stream.id}),
      );
    }
    super.dispose();
  }

  void _like() {
    setState(() {
      _likes++;
      _hearts.add(
        _Heart(
          key: UniqueKey(),
          left: 8 + _rand.nextDouble() * 24,
          hue: _rand.nextDouble(),
          onDone: (k) => setState(() => _hearts.removeWhere((h) => h.key == k)),
        ),
      );
    });
    context.read<SessionController>().toggleLike(widget.stream.id);
  }

  Future<void> _send() async {
    final text = _msgController.text.trim();
    if (text.isEmpty) return;
    _msgController.clear();
    if (_isReal) {
      final uid = context.read<AuthController>().user?.id;
      if (uid == null) return;
      try {
        await supabase.from('live_chat_messages').insert({
          'live_stream_id': widget.stream.id,
          'sender_id': uid,
          'body': text,
        });
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
      return;
    }
    final me = context.read<AuthController>().user ?? Mock.me;
    setState(() => _chat.add(LiveChatLine(me, text)));
  }

  /// Everyone worth gifting: the host plus anyone currently seated, deduped
  /// by id (the host may also occupy a seat). Feeds the gift sheet's own
  /// avatar row, so picking who it goes to happens in that same sheet
  /// rather than a separate step.
  List<AppUser> _giftRecipients() {
    final byId = <String, AppUser>{widget.stream.host.id: widget.stream.host};
    for (final u in _seatOccupants.values) {
      byId[u.id] = u;
    }
    return byId.values.toList();
  }

  Future<void> _openGifts() async {
    final giftChoice = await showGiftSheet(
      context,
      hostName: widget.stream.host.name,
      recipients: _giftRecipients(),
    );
    if (giftChoice == null || !mounted) return;
    final gift = giftChoice.gift;
    final me = context.read<AuthController>().user ?? Mock.me;
    final recipients = giftChoice.sendToAll
        ? _giftRecipients()
        : [if (giftChoice.recipient != null) giftChoice.recipient!];
    if (recipients.isEmpty) return;
    try {
      for (final recipient in recipients) {
        final qty = giftChoice.sendToAll ? 1 : giftChoice.quantity;
        for (var i = 0; i < qty; i++) {
          await context.read<WalletController>().sendGift(
            gift,
            recipient,
            liveStreamId: _isReal ? widget.stream.id : null,
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendlyError(e))));
      return;
    }
    if (!mounted) return;
    final label = giftChoice.sendToAll
        ? 'sent everyone ${gift.name}'
        : giftChoice.quantity > 1
        ? 'sent ${giftChoice.quantity}x ${gift.name}'
        : 'sent ${gift.name}';
    // The sender plays their own gift straight away; everyone else gets it from
    // the chat row send_gift writes (see RoomEffectController.onChatRow).
    _effects.enqueue(
      RoomEffect.gift(
        gift: gift,
        senderName: 'You',
        senderId: me.id,
        count: giftChoice.sendToAll ? recipients.length : giftChoice.quantity,
      ),
    );
    // Demo streams have no Realtime chat feed, so echo the line locally.
    if (!_isReal) {
      setState(() => _chat.add(LiveChatLine(me, label, gift: true)));
    }
  }

  // Same 4-column icon-tile grid as the host's own Tools sheet
  // (tool_grid.dart) — was a plain ListTile list before, which looked
  // nothing like the host's screen despite covering the same actions.
  Future<void> _moreActions() async {
    await showToolGridSheet(
      context,
      title: 'More',
      tools: [
        ToolSpec(
          Icons.card_giftcard_rounded,
          'Gift',
          AppColors.gold,
          _openGifts,
        ),
        ToolSpec(
          Icons.sports_esports_rounded,
          'Games',
          AppColors.primaryBright,
          () => AppNav.games(context),
        ),
        ToolSpec(
          Icons.savings_rounded,
          'Coin Bag',
          AppColors.gold,
          () => AppNav.wallet(context),
        ),
        ToolSpec(
          Icons.notifications_none_rounded,
          'Notifications',
          const Color(0xFF818CF8),
          () => AppNav.notifications(context),
        ),
        ToolSpec(Icons.inbox_rounded, 'Inbox', const Color(0xFF34D399), () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const MessagesScreen()),
          );
        }),
        ToolSpec(
          Icons.ios_share_rounded,
          'Share',
          AppColors.diamond,
          () => showShareSheet(
            context,
            title: '${widget.stream.host.name} is live on SABALIVE — join now!',
            url: 'sabalive://live/${widget.stream.id}',
          ),
        ),
      ],
    );
  }

  // This widget is mounted by the app-root overlay in app.dart, not pushed
  // as a Navigator route. Back button handling is didPopRoute() above, not
  // PopScope/BackButtonListener — see live_broadcast_screen.dart's own
  // didPopRoute() doc comment for why.
  @override
  Widget build(BuildContext context) {
    final minimized = context.watch<ActiveLiveSessionController>().isMinimized;
    return minimized ? _buildMinimized() : _buildFull(context);
  }

  Widget _buildMinimized() {
    // See the same note in live_broadcast_screen.dart's own _buildMinimized
    // — no Material wrapper here, it silently swallows every tap on the
    // rest of the app underneath once given full-screen constraints.
    return Stack(
      children: [
        LiveMinimizedBubble(
          host: widget.stream.host,
          onTap: () => context.read<ActiveLiveSessionController>().restore(),
          onClose: _showCloseDialog,
        ),
      ],
    );
  }

  /// Leave / Minimize / Follow — shown from both the close (X) button and
  /// the system back gesture. "Follow & Leave" is a one-tap "before you go"
  /// shortcut; it only actually calls toggleFollow if not already
  /// following, then leaves either way. "Minimize" is hidden while already
  /// minimized (tapping the bubble's own X) — offering to minimize what's
  /// already minimized was confusing, so that state just shows Leave (and
  /// Follow & Leave).
  Future<void> _showCloseDialog() async {
    final session = context.read<SessionController>();
    final liveSession = context.read<ActiveLiveSessionController>();
    final following = session.isFollowing(widget.stream.host.id);
    final minimized = liveSession.isMinimized;
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: Text(minimized ? 'Leave live?' : 'Leaving already?'),
        actions: [
          if (!minimized)
            TextButton(
              onPressed: () => Navigator.pop(context, 'minimize'),
              child: const Text('Minimize'),
            ),
          if (!following)
            TextButton(
              onPressed: () => Navigator.pop(context, 'follow'),
              child: const Text('Follow & Leave'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'leave'),
            child: const Text(
              'Leave',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'minimize':
        liveSession.minimize();
      case 'follow':
        session.toggleFollow(widget.stream.host.id);
        liveSession.end();
      case 'leave':
        liveSession.end();
    }
  }

  Widget _buildFull(BuildContext context) {
    final session = context.watch<SessionController>();
    final following = session.isFollowing(widget.stream.host.id);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_isReal)
            _realVideo()
          else
            AppThumb(
              seed: '${widget.stream.id}watch',
              borderRadius: 0,
              overlayOpacity: 0.1,
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black54,
                  Colors.transparent,
                  Colors.black54,
                  Colors.black87,
                ],
                stops: [0, 0.25, 0.7, 1],
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _topBar(context, following, session),
                const Spacer(),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(child: _chatColumn()),
                    _sideRail(),
                  ],
                ),
                if (_isReal) ...[
                  const SizedBox(height: 8),
                  CompactSeatStrip(
                    seatCount: _seatCount,
                    occupants: _seatOccupants,
                    lockedSeats: _lockedSeats,
                    mutedSeats: _mutedSeats,
                    onSeatTap: _seatTap,
                  ),
                ],
                const SizedBox(height: 10),
                _inputBar(),
                SizedBox(height: MediaQuery.of(context).padding.bottom + 6),
              ],
            ),
          ),
          // floating hearts
          Positioned(
            right: 6,
            bottom: 140,
            width: 60,
            height: 320,
            child: Stack(children: _hearts),
          ),
          // gift animation, for everyone in the room
          Positioned.fill(child: RoomEffectLayer(controller: _effects)),
        ],
      ),
    );
  }

  Widget _realVideo() {
    final engine = _engine;
    if (engine == null || _remoteUid == null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: _joinError != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _joinError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                )
              : _waitingTooLong
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    "Still nothing from the host — they may have ended, "
                    "or there's a connection issue.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                )
              : const CircularProgressIndicator(color: AppColors.primaryBright),
        ),
      );
    }
    return AgoraVideoView(
      controller: VideoViewController.remote(
        rtcEngine: engine,
        canvas: VideoCanvas(uid: _remoteUid),
        connection: RtcConnection(channelId: widget.stream.id),
      ),
    );
  }

  Widget _topBar(
    BuildContext context,
    bool following,
    SessionController session,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConnectionBanner(reconnecting: _reconnecting),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: isRealId(widget.stream.host.id)
                          ? () =>
                                AppNav.userProfile(context, widget.stream.host)
                          : null,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppAvatar(
                            name: widget.stream.host.name,
                            imageUrl: widget.stream.host.avatarUrl,
                            size: 32,
                          ),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.stream.host.name,
                                style: const TextStyle(
                                  fontFamily: 'Poppins',
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                  color: Colors.white,
                                ),
                              ),
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => showViewerListSheet(
                                  context,
                                  widget.stream.id,
                                ),
                                child: Text(
                                  '${compactCount(_viewerCount)} watching · '
                                  '${_seatOccupants.length} on seat',
                                  style: const TextStyle(
                                    fontSize: 9.5,
                                    color: Colors.white70,
                                    decoration: TextDecoration.underline,
                                    decorationColor: Colors.white38,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => session.toggleFollow(widget.stream.host.id),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          gradient: following
                              ? null
                              : AppColors.primaryGradient,
                          color: following ? Colors.white24 : null,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          following ? 'Following' : 'Follow',
                          style: const TextStyle(
                            fontFamily: 'Poppins',
                            fontWeight: FontWeight.w600,
                            fontSize: 10.5,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              const LiveBadge(),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _showCloseDialog,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chatColumn() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.only(left: 14, right: 6),
      // shrinkWrap — see the same note in watch_audio_room_screen.dart: an
      // un-shrinkwrapped Scrollable claims its whole box for hit-testing
      // regardless of content, which can swallow taps meant for whatever
      // sits underneath it.
      child: ListView.builder(
        reverse: true,
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: _chat.length,
        itemBuilder: (context, i) {
          final line = _chat[_chat.length - 1 - i];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: GestureDetector(
              onTap: isRealId(line.user.id)
                  ? () => AppNav.userProfile(context, line.user)
                  : null,
              child: LiveChatLineBubble(key: ObjectKey(line), line: line),
            ),
          );
        },
      ),
    );
  }

  Widget _sideRail() {
    Widget item(
      IconData icon,
      String label,
      VoidCallback onTap, {
      Color? color,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: GestureDetector(
          onTap: onTap,
          child: Column(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.32),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color ?? Colors.white, size: 22),
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: const TextStyle(fontSize: 10, color: Colors.white),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          item(
            Icons.favorite_rounded,
            compactCount(_likes),
            _like,
            color: AppColors.live,
          ),
          if (_mySeat != null)
            item(
              _myMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
              _myMuted ? 'Unmute' : 'Mute',
              _toggleMyMute,
              color: _myMuted ? AppColors.danger : Colors.white,
            ),
        ],
      ),
    );
  }

  // Same structure/order as live_broadcast_screen.dart's own _bottomBar():
  // More, Emoji, Gift, input pill, then a separate circular Send button —
  // was previously More/Gift/Emoji with the send icon inline in the pill,
  // which drifted from the host screen after that one got its own updates.
  Widget _inputBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _barIcon(Icons.more_horiz_rounded, _moreActions),
          const SizedBox(width: 6),
          _barIcon(Icons.emoji_emotions_outlined, _openQuickEmoji),
          const SizedBox(width: 6),
          _barIcon(Icons.card_giftcard_rounded, _openGifts),
          const SizedBox(width: 6),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 42),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.42),
                borderRadius: BorderRadius.circular(21),
                border: Border.all(color: Colors.white24),
              ),
              child: TextField(
                controller: _msgController,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                cursorColor: AppColors.primaryBright,
                minLines: 1,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Say something nice…',
                  hintStyle: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _send,
            child: Container(
              width: 42,
              height: 42,
              decoration: const BoxDecoration(
                gradient: AppColors.liveGradient,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.send_rounded,
                color: Colors.white,
                size: 19,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _barIcon(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.42),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 18),
      ),
    );
  }

  /// Emoji / GIF picker — its contents are managed from the admin panel. A
  /// plain emoji goes out as a normal chat message; a GIF as its own message.
  Future<void> _openQuickEmoji() async {
    final picked = await showLiveEmojiSheet(context);
    if (picked == null || !mounted) return;
    if (picked.isGif) {
      if (!_isReal) return; // demo streams have no chat to send into
      try {
        await LiveEmojisRepository().sendGif(widget.stream.id, picked.id);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
      return;
    }
    _msgController.text = picked.emoji ?? '';
    await _send();
  }
}

class _Heart extends StatefulWidget {
  const _Heart({
    required super.key,
    required this.left,
    required this.hue,
    required this.onDone,
  });

  final double left;
  final double hue;
  final void Function(Key) onDone;

  @override
  State<_Heart> createState() => _HeartState();
}

class _HeartState extends State<_Heart> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..forward();

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone(widget.key!);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final v = _c.value;
        final sway = math.sin(v * math.pi * 3) * 14;
        return Positioned(
          left: widget.left + sway,
          bottom: v * 300,
          child: Opacity(
            opacity: (1 - v).clamp(0.0, 1.0),
            child: Transform.scale(
              scale: 0.6 + v * 0.8,
              child: Icon(
                Icons.favorite_rounded,
                color: HSVColor.fromAHSV(1, widget.hue * 360, 0.7, 1).toColor(),
                size: 26,
              ),
            ),
          ),
        );
      },
    );
  }
}
