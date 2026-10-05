import 'dart:async';
import 'dart:math' as math;

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../config/supabase_client.dart';
import '../../core/utils/errors.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/ids.dart';
import '../../core/utils/share_links.dart';
import '../../core/utils/share_sheet.dart';
import '../../core/utils/viewer_list_sheet.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/connection_banner.dart';
import '../../core/widgets/pills.dart';
import '../../core/widgets/remote_media.dart';
import '../../data/mock_data.dart';
import '../../data/live_emojis_repository.dart';
import '../../data/models.dart';
import '../../data/store_repository.dart';
import '../../data/stream_end_watcher.dart';
import '../../data/viewer_ban_watcher.dart';
import '../../router/app_nav.dart';
import '../messages/messages_screen.dart';
import '../../services/agora_errors.dart';
import '../../services/agora_service.dart';
import '../../state/active_live_session_controller.dart';
import '../../state/auth_controller.dart';
import '../../state/blocks_controller.dart';
import '../../state/session_controller.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';
import 'live_access_exit.dart';
import 'widgets/room_effect.dart';
import 'widgets/gift_sheet.dart';
import 'widgets/live_emoji_sheet.dart';
import 'widgets/ghost_watch_bar.dart';
import 'widgets/live_chat_bubble.dart';
import 'widgets/room_chat_state.dart';
import 'widgets/live_minimized_bubble.dart';
import 'widgets/seat_room.dart';
import 'widgets/seat_snapshot.dart';
import 'widgets/seat_speaking.dart';
import 'widgets/stream_diamonds.dart';
import 'widgets/tool_grid.dart';
import '../../core/i18n/text.dart';

/// Viewer of an audio room — same proven audience-join + chat/gift/like
/// chrome as [WatchLiveScreen] (lib/features/live/watch_live_screen.dart),
/// swapping the video canvas for the same [SeatRoom] visual the host sees.
/// Seat occupancy is real and live (live_stream_seats) — tapping an empty,
/// unlocked seat claims it instantly (self-serve, no host approval) and
/// switches this client's Agora role to broadcaster so it actually
/// publishes microphone audio; tapping your own seat releases it.
class WatchAudioRoomScreen extends StatefulWidget {
  const WatchAudioRoomScreen({super.key, required this.stream});
  final LiveStream stream;

  @override
  State<WatchAudioRoomScreen> createState() => _WatchAudioRoomScreenState();
}

class _WatchAudioRoomScreenState extends State<WatchAudioRoomScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final bool _isReal = isRealId(widget.stream.id);
  void Function()? _stopEndWatch;
  bool _hostEndedHandled = false;
  bool _accessDeniedHandled = false;
  void Function()? _stopKickWatch;
  final List<LiveChatLine> _chat = [];
  final _msgController = TextEditingController();
  final _room = RoomChatState();
  final _rand = math.Random();
  final List<_Heart> _hearts = [];
  final _effects = RoomEffectController();
  String? _skinUrl;
  int _likes = 0;

  int? _remoteUid;
  RealtimeChannel? _chatChannel;
  String? _joinError;
  bool _reconnecting = false;
  String? _connectionFailure;
  Timer? _waitTimer;
  bool _waitingTooLong = false;

  RtcEngine? _engine;
  final Map<int, AppUser> _seatOccupants = {};
  Set<int> _lockedSeats = {};
  final Set<int> _mutedSeats = {};
  // who is talking right now (Agora volume reports mapped back to seats)
  final _speaking = SeatSpeaking();
  Set<int> _speakingSeats = {};
  late final StreamDiamonds _diamonds =
      StreamDiamonds(widget.stream.id, onChanged: () {
        if (mounted) setState(() {});
      });
  late int _seatCount = widget.stream.seatCount;
  RealtimeChannel? _seatsChannel;
  RealtimeChannel? _seatStreamChannel;
  bool _seatBusy = false;
  int? _mySeat;
  bool _myMuted = false;
  Timer? _heartbeat;
  int? _myAgoraUid;

  /// Tells the room which Agora uid is mine once I hold a seat, so my seat lights
  /// up on every screen while I talk.
  void _syncMySeatUid() {
    final uid = _myAgoraUid;
    if (uid == null || _mySeat == null) return;
    supabase
        .rpc('set_seat_agora_uid', params: {'p_stream_id': widget.stream.id, 'p_uid': uid})
        .catchError((e) => debugPrint('set_seat_agora_uid failed: $e'));
  }

  // widget.stream.viewers is a one-time snapshot from whenever this stream
  // object was fetched (e.g. the live feed) — it never changes on its own,
  // so the "N in room" display looked frozen for the whole session. This
  // mirrors the host's own broadcast screen, which already tracks it live.
  late int _viewerCount = widget.stream.viewers;

  late final ActiveLiveSessionController _session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session = context.read<ActiveLiveSessionController>()..backHandler = _showCloseDialog;
    _diamonds.start();
    _likes = widget.stream.likes;
    if (_isReal) {
      // See the same note in watch_live_screen.dart — without this, a
      // screen timeout suspends the Agora connection and this screen's own
      // heartbeat/seat timers, which looked exactly like a random disconnect.
      WakelockPlus.enable().catchError((_) {});
      _joinReal();
      _loadRealChat();
      _logViewerJoin();
      _subscribeSeats();
      _stopEndWatch = watchStreamEnd(widget.stream.id, _onHostEnded);
      final me = supabase.auth.currentUser?.id;
      if (me != null) {
        _stopKickWatch = watchViewerRemoval(
          widget.stream.id,
          me,
          () => _leaveDenied('The host removed you from this live.'),
        );
      }
      // Mirrors the host's own heartbeat: keeps this viewer (and, while
      // seated, this seat) from being swept by finalize_stale_presence if
      // the connection silently dies instead of a clean dispose.
      _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
        // See the same note in watch_live_screen.dart — these used to be
        // pure fire-and-forget with no error handling, so a silently-failed
        // heartbeat_seat looked identical to a real disconnect once
        // finalize_stale_presence swept the seat 90+ seconds later.
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

  Future<void> _logViewerJoin() async {
    try {
      await supabase.rpc(
        'join_live_stream',
        params: {'p_stream_id': widget.stream.id},
      );
    } catch (e) {
      // Banned from live, or removed by the host: this must stop the join (the
      // server has already refused it). Anything else is best-effort — a missed
      // count beats a broken screen.
      if (isLiveAccessError(e)) _leaveDenied(friendlyError(e));
    }
  }

  /// Out of the room, with the reason, because the server won't let this user in.
  void _leaveDenied(String message) {
    if (_accessDeniedHandled || !mounted) return;
    _accessDeniedHandled = true;
    leaveLiveBecauseDenied(context, message);
  }

  /// Live seat occupancy + locks — mirrors the host's own subscription in
  /// live_broadcast_screen.dart so both sides see the identical room state.
  Timer? _seatSyncTimer;
  int _missingMySeat = 0;

  /// Re-read the seats on a timer (see SeatSnapshot for why Realtime alone isn't enough).
  void _startSeatSync() {
    _seatSyncTimer?.cancel();
    _seatSyncTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_reconcileSeats()),
    );
  }

  Future<void> _reconcileSeats() async {
    if (!_isReal || !mounted) return;
    final snap = await fetchSeatSnapshot(widget.stream.id);
    if (snap == null || !mounted) return;
    final mine = snap.seatOf(supabase.auth.currentUser?.id);
    // my own seat is gone (the host removed me, or it was freed): act only if the next
    // look agrees, so a claim that was still landing isn't mistaken for it
    var lostMine = false;
    if (_mySeat != null && mine == null) {
      _missingMySeat++;
      lostMine = _missingMySeat >= 2;
    } else {
      _missingMySeat = 0;
    }
    final keepMine = _mySeat != null && mine == null && !lostMine;
    setState(() {
      final keep = keepMine ? _seatOccupants[_mySeat!] : null;
      for (final seat in _seatOccupants.keys) {
        if (!snap.occupants.containsKey(seat)) _speaking.unbindSeat(seat);
      }
      _seatOccupants
        ..clear()
        ..addAll(snap.occupants);
      if (keep != null) _seatOccupants[_mySeat!] = keep;
      _mutedSeats
        ..clear()
        ..addAll(snap.muted);
      for (final e in snap.agoraUids.entries) {
        _speaking.bindSeat(e.key, e.value);
      }
      if (snap.locked != null) _lockedSeats = snap.locked!;
      if (snap.seatCount != null) _seatCount = snap.seatCount!;
      if (snap.hostAgoraUid != null) _speaking.hostUid = snap.hostAgoraUid;
      if (mine != null) _mySeat = mine;
      if (lostMine) {
        _mySeat = null;
        _myMuted = false;
        _missingMySeat = 0;
      }
    });
    if (lostMine) {
      final engine = _engine;
      if (engine != null) {
        unawaited(AgoraService.instance.switchRole(
          engine,
          channelName: widget.stream.id,
          asBroadcaster: false,
        ));
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You are no longer on a seat')),
      );
    }
  }

  Future<void> _subscribeSeats() async {
    final rows = await supabase
        .from('live_stream_seats')
        .select(
          'seat_number, is_muted, agora_uid, profiles!live_stream_seats_occupant_id_fkey(*)',
        )
        .eq('live_stream_id', widget.stream.id);
    final streamRow = await supabase
        .from('live_streams')
        .select('locked_seats, seat_count, room_skin_item_id, host_agora_uid, pinned_notice, chat_cleared_at')
        .eq('id', widget.stream.id)
        .maybeSingle();
    unawaited(_applySkin(streamRow?['room_skin_item_id'] as String?));
    if (streamRow != null) _room.apply(streamRow, initial: true);
    _speaking.hostUid = streamRow?['host_agora_uid'] as int?;
    if (mounted) {
      final myId = supabase.auth.currentUser?.id;
      setState(() {
        for (final r in rows as List) {
          final profileRow = r['profiles'] as Map<String, dynamic>?;
          if (profileRow != null) {
            final seat = r['seat_number'] as int;
            _speaking.bindSeat(seat, r['agora_uid'] as int?);
            _seatOccupants[seat] = AppUser.fromRow(profileRow);
            if (r['is_muted'] as bool? ?? false) _mutedSeats.add(seat);
            // Without this, reopening the screen while already seated never
            // restores _mySeat — see the same note in watch_live_screen.dart.
            if (profileRow['id'] == myId) _mySeat = seat;
          }
        }
        final locked = streamRow?['locked_seats'] as List?;
        if (locked != null) _lockedSeats = locked.cast<int>().toSet();
        final count = streamRow?['seat_count'] as int?;
        if (count != null) _seatCount = count;
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
            _speaking.bindSeat(seat, payload.newRecord['agora_uid'] as int?);
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
            final seatUid = payload.newRecord['agora_uid'] as int?;
            if (seat != null && seatUid != null) _speaking.bindSeat(seat, seatUid);
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
          // Realtime can't filter DELETE events (a filtered listener silently never fires),
          // so this listens to every seat delete and keeps only this room's.
          callback: (payload) {
            if (payload.oldRecord['live_stream_id'] != widget.stream.id) return;
            final seat = payload.oldRecord['seat_number'] as int?;
            if (seat != null) _speaking.unbindSeat(seat);
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
        .subscribe((status, [error]) {
          // a (re)connected channel replays nothing it missed — read the seats again
          if (status == RealtimeSubscribeStatus.subscribed) {
            unawaited(_reconcileSeats());
          }
        });
    _startSeatSync();
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
            final viewers = payload.newRecord['viewer_count'] as int?;
            if (!mounted) return;
            // the host equipped / removed a room skin
            if (payload.newRecord.containsKey('room_skin_item_id')) {
              unawaited(
                _applySkin(payload.newRecord['room_skin_item_id'] as String?),
              );
            }
            final cleared = _room.apply(payload.newRecord);
            final hostUid = payload.newRecord['host_agora_uid'] as int?;
            if (hostUid != null) _speaking.hostUid = hostUid;
            setState(() {
              if (cleared) _chat.clear();
              if (locked != null) _lockedSeats = locked.cast<int>().toSet();
              if (count != null) _seatCount = count;
              if (viewers != null) _viewerCount = viewers;
            });
          },
        )
        .subscribe();
  }

  Future<void> _applySkin(String? itemId) async {
    String? url;
    try {
      url = await StoreRepository().assetUrlFor(itemId);
    } catch (_) {
      return; // keep whatever is showing
    }
    if (mounted && url != _skinUrl) setState(() => _skinUrl = url);
  }

  Future<void> _joinReal() async {
    try {
      final engine = await AgoraService.instance.ensureEngine();
      _engine = engine;
      final token = await AgoraService.instance.fetchToken(
        channelName: widget.stream.id,
        asBroadcaster: false,
      );
      engine.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (connection, elapsed) {
            _myAgoraUid = connection.localUid;
            _syncMySeatUid();
          },
          onAudioVolumeIndication: (connection, speakers, speakerNumber, totalVolume) {
            final next = _speaking.seatsFor(
              speakers,
              occupants: _seatOccupants,
              hostId: widget.stream.host.id,
              mySeat: _mySeat,
              meMuted: _myMuted,
            );
            if (mounted && !SeatSpeaking.same(next, _speakingSeats)) {
              setState(() => _speakingSeats = next);
            }
          },
          onUserJoined: (connection, remoteUid, elapsed) {
            _waitTimer?.cancel();
            if (mounted) {
              setState(() {
                _remoteUid = remoteUid;
                _waitingTooLong = false;
              });
            }
          },
          onUserOffline: (connection, remoteUid, reason) {
            if (mounted && _remoteUid == remoteUid) {
              setState(() => _remoteUid = null);
            }
          },
          onError: (err, msg) {
            if (mounted) setState(() => _joinError = agoraErrorMessage(err, msg));
          },
          onConnectionStateChanged: (connection, state, reason) {
            if (!mounted) return;
            final failed = state == ConnectionStateType.connectionStateFailed;
            setState(() {
              _reconnecting =
                  state == ConnectionStateType.connectionStateReconnecting;
              _connectionFailure = failed ? agoraFailureMessage(reason) : null;
              // a viewer who never got in sees the reason, not a spinner
              if (failed) _joinError = _connectionFailure;
            });
          },
        ),
      );
      AgoraService.instance.registerAutoTokenRenewal(
        engine,
        channelName: widget.stream.id,
        asBroadcaster: false,
      );
      await engine.enableAudioVolumeIndication(
        interval: 300,
        smooth: 3,
        reportVad: true,
      );
      await engine.joinChannel(
        token: token.token,
        channelId: token.channelName,
        uid: token.uid,
        options: const ChannelMediaOptions(
          channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
          clientRoleType: ClientRoleType.clientRoleAudience,
          autoSubscribeAudio: true,
          autoSubscribeVideo: true,
          publishCameraTrack: false,
          publishMicrophoneTrack: false,
        ),
      );
      _waitTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && _remoteUid == null)
          setState(() => _waitingTooLong = true);
      });
    } catch (e) {
      if (isLiveAccessError(e)) {
        _leaveDenied(friendlyError(e));
      } else if (mounted) {
        setState(() => _joinError = friendlyError(e));
      }
    }
  }

  Future<void> _loadRealChat() async {
    // A new arrival sees only what is said from now on — no earlier chat. The last
    // few seconds are still read, but only to catch this user's own join row (its
    // entry effect can land before this screen starts listening); no lines are shown.
    final rows = await supabase
        .from('live_chat_messages')
        .select()
        .eq('live_stream_id', widget.stream.id)
        .gte(
          'created_at',
          DateTime.now().toUtc().subtract(const Duration(seconds: 20)).toIso8601String(),
        )
        .order('created_at', ascending: false)
        .limit(30);
    if (!mounted) return;
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
            if (payload.newRecord['kind'] == 'gift') _diamonds.onGift();
            // A gift or an entry from someone: play it on screen, not just as
            // a line.
            unawaited(
              _effects.handleRow(
                payload.newRecord,
                meId: context.read<AuthController>().user?.id,
                senderName: sender.name,
                giftById: context.read<WalletController>().giftById,
                loadItems: StoreRepository().itemsByIds,
              ),
            );
            // someone the user blocked: no chat line
            if (BlocksController.instance.isBlocked(senderId)) return;
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

  /// dispose() alone only covers a clean in-app exit (back/close button).
  /// Backgrounding or the OS killing the app skips dispose() on iOS and
  /// often on Android too, so without this a seat stays occupied — visible
  /// to the host and everyone else — until the ~90-150s stale-presence
  /// cron sweep catches it. Releasing on pause also matches reality here:
  /// this app has no background-audio mode, so a backgrounded seat holder
  /// stops actually publishing anyway.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_reconcileSeats());
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
    if (_session.backHandler == _showCloseDialog) _session.backHandler = null;
    _diamonds.dispose();
    _stopEndWatch?.call();
    _stopKickWatch?.call();
    _waitTimer?.cancel();
    _heartbeat?.cancel();
    _msgController.dispose();
    _effects.dispose();
    _chatChannel?.unsubscribe();
    _seatSyncTimer?.cancel();
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
    if (_ghost) return;
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

  bool get _ghost => isGhostViewer(context);


  Future<void> _seatTap(int seat) async {
    if (_ghost || !_isReal || _seatBusy) return;
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
        if (mounted)
          messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
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
      await supabase.rpc(
        'claim_seat',
        params: {'p_stream_id': widget.stream.id, 'p_seat': seat},
      );
      final engine = _engine;
      if (engine != null) {
        await AgoraService.instance.switchRole(
          engine,
          channelName: widget.stream.id,
          asBroadcaster: true,
        );
      }
      if (mounted) setState(() => _mySeat = seat);
      _syncMySeatUid();
      // Narrows the window before the periodic heartbeat's next tick has to
      // land cleanly to stay under finalize_stale_presence's 90s threshold
      // — see the same note in watch_live_screen.dart.
      supabase
          .rpc('heartbeat_seat', params: {'p_stream_id': widget.stream.id})
          .catchError((e) => debugPrint('heartbeat_seat failed: $e'));
    } catch (e) {
      if (mounted)
        messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
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

  /// Everyone worth gifting: the host plus anyone currently seated (the host
  /// auto-occupies seat 1 in audio rooms, so this is usually redundant but
  /// harmless — deduped by id either way). Feeds the gift sheet's own
  /// avatar row.
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
          AppNav.open(context, const MessagesScreen());
        }),
        ToolSpec(
          Icons.ios_share_rounded,
          'Share',
          AppColors.diamond,
          () => showShareSheet(
            context,
            title: '${widget.stream.host.name} is live on SABALIVE — join now!',
            url: liveShareUrl(widget.stream.id),
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
    // No Material wrapper — see the same note in live_broadcast_screen.dart.
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

  /// "Minimize" is hidden while already minimized — see the same note in
  /// watch_live_screen.dart.
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
          if (!following && !_ghost)
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
          // Plain backdrop only — the actual host avatar + seat grid render
          // in-flow below, inside the SafeArea's Column, not stacked under
          // it. A seat grid stacked as a backdrop (the old approach) sits
          // underneath the chat/toolbar layer, and anything painted on top
          // of it — even an empty-looking one — can silently swallow taps
          // meant for a seat beneath it. CompactSeatStrip (video mode) never
          // had this problem because it was already laid out in-flow;
          // this brings audio in line with that instead of continuing to
          // patch the overlay approach.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1B1140), Color(0xFF0B0716)],
              ),
            ),
          ),
          // The host's room skin (a store item they equipped), over the default
          // gradient, with a scrim so seat names stay readable.
          if (_skinUrl != null) ...[
            RemoteMedia(_skinUrl!, key: ValueKey(_skinUrl), fit: BoxFit.cover),
            const ColoredBox(color: Color(0x59000000)),
          ],
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black54,
                  Colors.transparent,
                  Colors.transparent,
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
                Expanded(child: _seatArea()),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(child: _chatColumn()),
                    _sideRail(),
                  ],
                ),
                const SizedBox(height: 10),
                _inputBar(),
                SizedBox(height: MediaQuery.of(context).padding.bottom + 6),
              ],
            ),
          ),
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

  /// The actual tappable seat grid, laid out in-flow (see the comment in
  /// build()). The host occupies one of these numbered seats like anyone
  /// else now (marked with SeatCircle's host badge) rather than getting a
  /// separate avatar above the grid. Scrollable since audio rooms can have
  /// up to 25 seats — five rows would otherwise overflow on a shorter phone.
  Widget _seatArea() {
    final error =
        _joinError ??
        (_waitingTooLong
            ? "Still nothing from the host — they may have ended, "
                  "or there's a connection issue."
            : null);
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            error,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          const SizedBox(height: 24),
          GridView.count(
            crossAxisCount: 5,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 16,
            crossAxisSpacing: 4,
            childAspectRatio: 0.72,
            children: [
              for (var i = 1; i <= _seatCount; i++)
                SeatCircle(
                  seat: i,
                  occupant: _seatOccupants[i],
                  locked: _lockedSeats.contains(i),
                  muted: _mutedSeats.contains(i),
                  speaking: _speakingSeats.contains(i),
                  diamonds: _seatOccupants[i] == null ? null : _diamonds.of(_seatOccupants[i]!.id),
                  isHost: _seatOccupants[i]?.id == widget.stream.host.id,
                  onTap: () => _seatTap(i),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],
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
          ConnectionBanner(reconnecting: _reconnecting, failure: _connectionFailure),
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
                            frameUrl: widget.stream.host.frameUrl,
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
                                  '${compactCount(_viewerCount)} in room · '
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
                    if (!_ghost)
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
      // shrinkWrap: without it, a Scrollable always claims its full 220px
      // box for hit-testing (so a drag can start anywhere in it), even when
      // there are only a couple of chat lines — silently swallowing taps on
      // the seat grid underneath wherever this empty space overlaps it.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_room.notice != null) PinnedNoticeBanner(_room.notice!),
          Flexible(
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
          ),
        ],
      ),
    );
  }

  Widget _sideRail() {
    if (_ghost) return const SizedBox.shrink();
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

  // Same structure/order as the video watch screen's own _inputBar() (which
  // itself matches the host's _bottomBar()) — More, Emoji, Gift, input
  // pill, then a separate circular Send button. Was previously
  // More/Gift/Emoji with the send icon inline in the pill, which had
  // drifted from the other two live screens.
  Widget _inputBar() {
    if (_ghost) return const GhostWatchBar();
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
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: tr('Say something nice…'),
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
