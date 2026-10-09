import 'dart:async';

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
import '../../core/utils/viewer_picker_sheet.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/connection_banner.dart';
import '../../core/widgets/keyboard_lift.dart';
import '../../data/live_emojis_repository.dart';
import '../../data/models.dart';
import '../../data/profile_cache.dart';
import '../../data/social_repository.dart';
import '../../router/app_nav.dart';
import '../../services/agora_errors.dart';
import '../../services/agora_service.dart';
import '../../services/local_music_service.dart';
import '../../data/store_repository.dart';
import '../../state/active_live_session_controller.dart';
import '../../state/blocks_controller.dart';
import '../../state/live_streams_controller.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';
import '../messages/messages_screen.dart';
import 'widgets/room_effect.dart';
import 'widgets/room_skin_sheet.dart';
import 'widgets/gift_sheet.dart';
import 'widgets/live_emoji_sheet.dart';
import 'widgets/live_chat_bubble.dart';
import 'widgets/room_chat_state.dart';
import 'widgets/lucky_box_badge.dart';
import 'widgets/music_sheet.dart';
import 'widgets/live_minimized_bubble.dart';
import 'widgets/seat_room.dart';
import 'widgets/seat_snapshot.dart';
import 'widgets/seat_speaking.dart';
import 'widgets/speaking_waves.dart';
import 'widgets/stream_diamonds.dart';
import 'widgets/tool_grid.dart';
import '../../core/i18n/text.dart';

/// Host's own broadcast view — real Agora publish + real Realtime chat tied
/// to the [LiveStream] row created just before this screen was pushed.
/// [audioOnly] flips it to a voice room with guest seats instead of camera.
class LiveBroadcastScreen extends StatefulWidget {
  const LiveBroadcastScreen({
    super.key,
    required this.stream,
    required this.token,
    this.audioOnly = false,
  });
  final LiveStream stream;
  final AgoraToken token;
  final bool audioOnly;

  @override
  State<LiveBroadcastScreen> createState() => _LiveBroadcastScreenState();
}

class _LiveBroadcastScreenState extends State<LiveBroadcastScreen>
    with WidgetsBindingObserver {
  RtcEngine? _engine;
  int _viewers = 0;
  final List<LiveChatLine> _chat = [];
  RealtimeChannel? _chatChannel;
  RealtimeChannel? _viewerChannel;
  String? _error;
  bool _reconnecting = false;
  String? _connectionFailure;

  final _input = TextEditingController();
  Timer? _ticker;
  // a notifier, so the once-a-second tick repaints just the clock pill, not the whole screen
  final _elapsed = ValueNotifier<Duration>(Duration.zero);
  // The stream's own start time, so the timer is always "now minus start" — it
  // can't restart, drift, or fall behind while the app is in the background.
  late final DateTime _startedAt = widget.stream.startedAt ?? DateTime.now();
  bool _micMuted = false;
  bool _speakerOn = true;

  // Beauty — real Agora clear_vision filter (see AgoraService.setBeautyEffect),
  // not just a UI toggle. Defaults chosen as a mild, natural-looking preset
  // for the moment someone first turns it on — 0 on every slider would mean
  // "on" but invisible, which reads as broken.
  bool _beautyOn = false;
  double _beautySmooth = 0.5;
  double _beautyWhiten = 0.3;
  double _beautyRedness = 0.1;
  double _beautySharpness = 0.1;

  // Seat controls — real and synced everywhere (live_stream_seats /
  // live_streams.seat_count / locked_seats). Video mode shows seats too now
  // (a slim strip, not the full backdrop) but has no add/remove UI — only
  // audio rooms let the host resize the room.
  late int _seatCount = widget.stream.seatCount;
  Set<int> _lockedSeats = {};
  final Map<int, AppUser> _seatOccupants = {};
  final Set<int> _mutedSeats = {};
  // who is talking right now (Agora volume reports mapped back to seats)
  final _speaking = SeatSpeaking();
  Set<int> _speakingSeats = {};
  bool _hostSpeaking = false;
  late final StreamDiamonds _diamonds =
      StreamDiamonds(widget.stream.id, onChanged: () {
        if (mounted) setState(() {});
      });
  RealtimeChannel? _seatsChannel;

  /// Bumped whenever a seat changes hands, so a profile lookup that finishes late cannot paint the
  /// previous occupant over the current one.
  final Map<int, int> _seatGen = {};
  int _bumpSeat(int seat) => _seatGen[seat] = (_seatGen[seat] ?? 0) + 1;

  /// Seats whose guest's Agora connection ended (they quit or dropped) -> that guest's id. Hidden at
  /// once instead of waiting for the server to sweep the seat; shown again if they reconnect.
  final Map<int, String> _goneSeats = {};

  void _hideGoneSeat(int uid) {
    final seat = _speaking.seatOfUid(uid);
    if (seat == null || !mounted) return;
    final occupant = _seatOccupants[seat];
    if (occupant == null || occupant.id == widget.stream.host.id) return;
    setState(() {
      _goneSeats[seat] = occupant.id;
      _seatOccupants.remove(seat);
      _mutedSeats.remove(seat);
      _speakingSeats = {..._speakingSeats}..remove(seat);
    });
  }

  void _showBackSeat(int uid) {
    final seat = _speaking.seatOfUid(uid);
    if (seat != null && _goneSeats.remove(seat) != null) unawaited(_reconcileSeats());
  }

  // Video-only: empty seats are host-approval-gated (same request_pk_seat/
  // approve_pk_seat_request flow PK battles use), so viewers can't just
  // self-serve claim one the way audio-room guests still can.
  final List<({String requestId, AppUser requester})> _pendingSeatRequests = [];
  RealtimeChannel? _seatRequestsChannel;

  Timer? _heartbeat;

  late final ActiveLiveSessionController _session;

  @override
  void initState() {
    super.initState();
    // For didPopRoute() below — this screen is mounted by the app-root
    // overlay in app.dart, not pushed as a Navigator route, so there's no
    // ModalRoute for the usual PopScope/BackButtonListener mechanisms to
    // attach to. WidgetsBindingObserver.didPopRoute() intercepts the
    // system back button/gesture at the binding level instead, independent
    // of Route nesting.
    WidgetsBinding.instance.addObserver(this);
    _session = context.read<ActiveLiveSessionController>()..backHandler = _end;
    if (widget.audioOnly) _diamonds.start();
    // Keeps the screen (and the Agora publish + heartbeat timers) from
    // being suspended by a display timeout mid-broadcast — that was
    // dropping the whole stream for every viewer, not just this device.
    WakelockPlus.enable().catchError((_) {});
    _join();
    _subscribeChat();
    _loadSeatLockState();
    _subscribeViewerCount();
    _subscribeSeats();
    if (!widget.audioOnly) _subscribeSeatRequests();
    if (widget.audioOnly) {
      // Audio rooms no longer give the host a seat of their own outside the
      // numbered grid — the host just occupies seat 1 like anyone else,
      // and can move to any other open seat via the seat menu below.
      // Shown immediately (before the claim RPC even lands) so the host
      // sees themself seated the instant the room opens, not after a
      // round trip through the server and back via Realtime.
      _seatOccupants[1] = widget.stream.host;
      _autoClaimHostSeat();
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        final d = DateTime.now().difference(_startedAt);
        _elapsed.value = d.isNegative ? Duration.zero : d;
      }
    });
    // Keeps the stream row from being auto-ended as stale while this
    // screen is genuinely up and broadcasting.
    final liveStreams = context.read<LiveStreamsController>();
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      liveStreams.heartbeat(widget.stream.id);
      // BUG FIX: this never existed before — in an audio room the host
      // occupies a real live_stream_seats row (seat 1) same as any guest,
      // but nothing ever refreshed its last_heartbeat_at. Every audio
      // broadcast's own host seat went stale and got swept by
      // finalize_stale_presence ~90-150s in, every single time (not an
      // intermittent network thing like the viewer-side bug — this one
      // was 100% guaranteed since the call was simply missing).
      if (widget.audioOnly) {
        supabase
            .rpc('heartbeat_seat', params: {'p_stream_id': widget.stream.id})
            .catchError((e) => debugPrint('host heartbeat_seat failed: $e'));
      }
    });
  }

  Future<void> _join() async {
    try {
      final engine = await AgoraService.instance.ensureEngine();
      engine.registerEventHandler(
        RtcEngineEventHandler(
          onAudioVolumeIndication: (connection, speakers, speakerNumber, totalVolume) {
            final next = _speaking.seatsFor(
              speakers,
              occupants: _seatOccupants,
              hostId: widget.stream.host.id,
              mySeat: [for (final e in _seatOccupants.entries) if (e.value.id == widget.stream.host.id) e.key].firstOrNull,
              meMuted: _micMuted,
            );
            final hostNow = _speaking.hostTalking(
              speakers,
              iAmHost: true,
              meMuted: _micMuted,
            );
            if (mounted &&
                (!SeatSpeaking.same(next, _speakingSeats) || hostNow != _hostSpeaking)) {
              setState(() {
                _speakingSeats = next;
                _hostSpeaking = hostNow;
              });
            }
          },
          // A guest on a seat leaving (or dropping) frees their seat on this screen now, not when
          // the server sweeps it. Agora only reports people who were publishing.
          onUserOffline: (connection, remoteUid, reason) => _hideGoneSeat(remoteUid),
          onUserJoined: (connection, remoteUid, elapsed) => _showBackSeat(remoteUid),
          onError: (err, msg) {
            if (mounted) setState(() => _error = agoraErrorMessage(err, msg));
          },
          onConnectionStateChanged: (connection, state, reason) {
            if (!mounted) return;
            setState(() {
              _reconnecting =
                  state == ConnectionStateType.connectionStateReconnecting;
              _connectionFailure =
                  state == ConnectionStateType.connectionStateFailed
                      ? agoraFailureMessage(reason)
                      : null;
            });
          },
          // Persist the host's actual assigned uid so viewers can tell
          // them apart from a seat-holder who also becomes a broadcaster
          // in this same channel — onUserJoined alone no longer uniquely
          // identifies "the host" once more than one broadcaster can join.
          onJoinChannelSuccess: (connection, elapsed) {
            final uid = connection.localUid;
            if (uid != null) {
              supabase
                  .rpc(
                    'set_host_agora_uid',
                    params: {'p_stream_id': widget.stream.id, 'p_uid': uid},
                  )
                  .catchError((e) {
                    debugPrint('set_host_agora_uid failed: $e');
                  });
            }
          },
        ),
      );
      AgoraService.instance.registerAutoTokenRenewal(
        engine,
        channelName: widget.token.channelName,
        asBroadcaster: true,
      );
      if (widget.audioOnly) {
        await engine.enableLocalVideo(false);
      } else {
        await engine.startPreview();
      }
      await engine.enableAudioVolumeIndication(
        interval: 300,
        smooth: 3,
        reportVad: true,
      );
      await engine.joinChannel(
        token: widget.token.token,
        channelId: widget.token.channelName,
        uid: widget.token.uid,
        options: ChannelMediaOptions(
          channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          // Left implicit, these default to "on" per Agora's docs, but that
          // default has already proven unreliable on this SDK build for the
          // audience's autoSubscribe flags (see watch_live_screen.dart) —
          // explicit here too, since this is the actual camera/mic publish
          // every viewer depends on.
          publishCameraTrack: !widget.audioOnly,
          publishMicrophoneTrack: true,
        ),
      );
      if (mounted) setState(() => _engine = engine);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  void _subscribeChat() {
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
          callback: (payload) => _appendChatRow(payload.newRecord),
        )
        .subscribe();
  }

  /// One-time fetch of the stream's actual current lock/seat-count state.
  /// Without this, `_lockedSeats`/`_seatCount` start from whatever
  /// `widget.stream` happened to hold at navigation time (often stale/empty)
  /// and only self-correct once some *other* live_streams update happens to
  /// fire — so re-entering this screen with seats already locked would
  /// wrongly show them unlocked until then.
  Future<void> _loadSeatLockState() async {
    final row = await supabase
        .from('live_streams')
        .select('locked_seats, seat_count, room_skin_item_id, pinned_notice, chat_cleared_at')
        .eq('id', widget.stream.id)
        .maybeSingle();
    if (row == null || !mounted) return;
    unawaited(_applySkin(row['room_skin_item_id'] as String?));
    final locked = row['locked_seats'] as List?;
    final seatCount = row['seat_count'] as int?;
    _room.apply(row, initial: true);
    setState(() {
      if (locked != null) _lockedSeats = locked.cast<int>().toSet();
      if (seatCount != null) _seatCount = seatCount;
    });
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

  /// Viewer count comes from the DB, not Agora's onUserJoined/onUserOffline
  /// — Agora's Live Broadcasting profile doesn't report audience-role joins
  /// to other participants (by design, for scale to large audiences), so
  /// those callbacks never actually fired for real viewers. Each watch
  /// screen logs its own presence via join_live_stream/leave_live_stream,
  /// and a trigger keeps live_streams.viewer_count accurate from that.
  void _subscribeViewerCount() {
    _viewerChannel = supabase
        .channel('live-viewers-${widget.stream.id}')
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
            final count = payload.newRecord['viewer_count'] as int?;
            final locked = payload.newRecord['locked_seats'] as List?;
            final seatCount = payload.newRecord['seat_count'] as int?;
            if (!mounted) return;
            // the host equipped / removed a room skin
            if (payload.newRecord.containsKey('room_skin_item_id')) {
              unawaited(
                _applySkin(payload.newRecord['room_skin_item_id'] as String?),
              );
            }
            final cleared = _room.apply(payload.newRecord);
            setState(() {
              if (cleared) _chat.clear();
              if (count != null) _viewers = count;
              if (locked != null) {
                _lockedSeats = locked.cast<int>().toSet();
              }
              if (seatCount != null) _seatCount = seatCount;
            });
          },
        )
        .subscribe();
  }

  /// Live seat occupancy — who's actually sitting where, kept in sync across
  /// the host and every viewer via the same live_stream_seats row set.
  Timer? _seatSyncTimer;
  bool _sittingHostDown = false;

  /// Re-read the seats on a timer (see SeatSnapshot for why Realtime alone isn't
  /// enough) and make sure the host is on a seat in an audio room.
  void _startSeatSync() {
    _seatSyncTimer?.cancel();
    _seatSyncTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_reconcileSeats()),
    );
  }

  Future<void> _reconcileSeats() async {
    if (!mounted) return;
    final snap = await fetchSeatSnapshot(widget.stream.id);
    if (snap == null || !mounted) return;
    final occupants = Map<int, AppUser>.of(snap.occupants);
    // hidden-because-gone seats stay hidden only while the same guest is still on them
    _goneSeats.removeWhere((seat, id) => occupants[seat]?.id != id);
    for (final seat in _goneSeats.keys) {
      occupants.remove(seat);
    }
    setState(() {
      for (final seat in _seatOccupants.keys) {
        if (!occupants.containsKey(seat)) {
          _speaking.unbindSeat(seat);
          _bumpSeat(seat);
        }
      }
      _seatOccupants
        ..clear()
        ..addAll(occupants);
      _mutedSeats
        ..clear()
        ..addAll(snap.muted);
      for (final e in snap.agoraUids.entries) {
        if (occupants.containsKey(e.key) || _goneSeats.containsKey(e.key)) {
          _speaking.bindSeat(e.key, e.value);
        }
      }
      if (snap.locked != null) _lockedSeats = snap.locked!;
      if (snap.seatCount != null) _seatCount = snap.seatCount!;
    });
    if (widget.audioOnly && snap.seatOf(widget.stream.host.id) == null) {
      unawaited(_sitHostDown(snap));
    }
  }

  /// The host of an audio room always has a seat. If theirs was freed (a lapse in
  /// heartbeats, a clean-up) and a guest has since taken seat 1, any free seat will do —
  /// the host must never be missing from their own room.
  Future<void> _sitHostDown(SeatSnapshot snap) async {
    if (_sittingHostDown) return;
    _sittingHostDown = true;
    try {
      // look again first: the opening claim may simply not have landed when the
      // snapshot was read, and claiming a second seat would move the host
      var fresh = await fetchSeatSnapshot(widget.stream.id) ?? snap;
      final hostId = widget.stream.host.id;
      final count = snap.seatCount ?? _seatCount;
      for (var seat = 1; seat <= count && fresh.seatOf(hostId) == null; seat++) {
        final locked = fresh.locked ?? _lockedSeats;
        if (fresh.occupants.containsKey(seat) || locked.contains(seat)) continue;
        try {
          await supabase.rpc(
            'claim_seat',
            params: {'p_stream_id': widget.stream.id, 'p_seat': seat},
          );
          await supabase.rpc(
            'heartbeat_seat',
            params: {'p_stream_id': widget.stream.id},
          );
          break;
        } catch (_) {
          // someone just took it (or it was ours all along) — look again, then move on
          fresh = await fetchSeatSnapshot(widget.stream.id) ?? fresh;
        }
      }
    } finally {
      _sittingHostDown = false;
    }
    if (mounted) unawaited(_reconcileSeats());
  }

  Future<void> _subscribeSeats() async {
    final rows = await supabase
        .from('live_stream_seats')
        .select(
          'seat_number, is_muted, agora_uid, profiles!live_stream_seats_occupant_id_fkey(*)',
        )
        .eq('live_stream_id', widget.stream.id);
    if (mounted) {
      setState(() {
        for (final r in rows as List) {
          final profileRow = r['profiles'] as Map<String, dynamic>?;
          if (profileRow != null) {
            final seat = r['seat_number'] as int;
            _speaking.bindSeat(seat, r['agora_uid'] as int?);
            _seatOccupants[seat] = AppUser.fromRow(profileRow);
            if (r['is_muted'] as bool? ?? false) _mutedSeats.add(seat);
          }
        }
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
            final gen = _bumpSeat(seat);
            _goneSeats.remove(seat);
            final profileRow = await ProfileCache.instance.get(occupantId);
            // the seat changed hands (or emptied) while the profile was on its way
            if (!mounted || profileRow == null || _seatGen[seat] != gen) return;
            setState(() {
              _seatOccupants[seat] = AppUser.fromRow(profileRow);
              _mutedSeats.remove(seat);
            });
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
            if (seat != null) {
              _speaking.unbindSeat(seat);
              _bumpSeat(seat);
              _goneSeats.remove(seat);
            }
            if (mounted && seat != null) {
              setState(() {
                _seatOccupants.remove(seat);
                _mutedSeats.remove(seat);
              });
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
  }

  /// Pending "may I have a seat?" requests for this video stream — mirrors
  /// pk_battle_screen.dart's own _subscribeSeatRequests exactly, reusing the
  /// same pk_seat_requests table/RPCs (a seat request isn't a PK-specific
  /// thing, just host-approval-gated seating, same as PK's own side).
  Future<void> _subscribeSeatRequests() async {
    Future<void> load() async {
      final rows =
          (await supabase
                      .from('pk_seat_requests')
                      .select(
                        'id, profiles!pk_seat_requests_requester_id_fkey(*)',
                      )
                      .eq('live_stream_id', widget.stream.id)
                      .eq('status', 'pending')
                  as List)
              .cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _pendingSeatRequests
          ..clear()
          ..addAll([
            for (final r in rows)
              if (r['profiles'] != null)
                (
                  requestId: r['id'] as String,
                  requester: AppUser.fromRow(
                    r['profiles'] as Map<String, dynamic>,
                  ),
                ),
          ]);
      });
    }

    await load();
    _seatRequestsChannel = supabase
        .channel('live-seatreqs-${widget.stream.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'pk_seat_requests',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'live_stream_id',
            value: widget.stream.id,
          ),
          callback: (_) => load(),
        )
        .subscribe();
  }

  Future<void> _autoClaimHostSeat() async {
    try {
      await supabase.rpc(
        'claim_seat',
        params: {'p_stream_id': widget.stream.id, 'p_seat': 1},
      );
      // Narrows the window before the periodic heartbeat's next (up to
      // 30s-away) tick has to land cleanly — see the fix in initState.
      await supabase.rpc(
        'heartbeat_seat',
        params: {'p_stream_id': widget.stream.id},
      );
    } catch (e) {
      debugPrint('auto-claim host seat failed: $e');
    }
  }

  int? _firstEmptySeat() {
    for (var i = 1; i <= _seatCount; i++) {
      if (!_seatOccupants.containsKey(i)) return i;
    }
    return null;
  }

  // Removes the request from _pendingSeatRequests immediately on success
  // rather than waiting for the Realtime round-trip back through
  // _subscribeSeatRequests — the request sheet is a separate StatefulBuilder
  // route, not part of this State's own widget tree, so a plain setState()
  // here (paired with the sheet's own setSheetState call) is what actually
  // makes the badge count and the open sheet agree immediately.
  Future<void> _approveSeatRequest(String requestId, int seat) async {
    try {
      await supabase.rpc(
        'approve_pk_seat_request',
        params: {'p_request_id': requestId, 'p_seat': seat},
      );
      if (mounted) {
        setState(
          () =>
              _pendingSeatRequests.removeWhere((r) => r.requestId == requestId),
        );
      }
    } catch (e) {
      if (mounted) _snack(friendlyError(e));
    }
  }

  Future<void> _declineSeatRequest(String requestId) async {
    try {
      await supabase.rpc(
        'decline_pk_seat_request',
        params: {'p_request_id': requestId},
      );
      if (mounted) {
        setState(
          () =>
              _pendingSeatRequests.removeWhere((r) => r.requestId == requestId),
        );
      }
    } catch (e) {
      if (mounted) _snack(friendlyError(e));
    }
  }

  final _effects = RoomEffectController();
  final _room = RoomChatState();
  String? _skinUrl;

  Future<void> _appendChatRow(Map<String, dynamic> row) async {
    final senderId = row['sender_id'] as String;
    final profileRow = await ProfileCache.instance.get(senderId);
    final sender = profileRow != null
        ? AppUser.fromRow(profileRow)
        : AppUser(id: senderId, name: 'Someone', username: '@user');
    if (!mounted) return;
    if (row['kind'] == 'gift') _diamonds.onGift();
    // A gift or an entry from a viewer: play it on screen, not just as a line.
    unawaited(
      _effects.handleRow(
        row,
        meId: supabase.auth.currentUser?.id,
        senderName: sender.name,
        giftById: context.read<WalletController>().giftById,
        loadItems: StoreRepository().itemsByIds,
      ),
    );
    // someone the user blocked: no chat line
    if (BlocksController.instance.isBlocked(senderId)) return;
    setState(() {
      _chat.add(
        LiveChatLine(
          sender,
          row['body'] as String,
          gift: row['kind'] == 'gift',
          system: row['kind'] == 'system',
          pinned: row['pinned'] as bool? ?? false,
          stickerUrl: row['kind'] == 'sticker'
              ? row['sticker_url'] as String?
              : null,
        ),
      );
    });
  }

  /// Emoji / GIF picker — its contents are managed from the admin panel. A
  /// plain emoji goes out as a normal chat message; a GIF as its own message.
  Future<void> _openQuickEmoji() async {
    final picked = await showLiveEmojiSheet(context);
    if (picked == null || !mounted) return;
    if (picked.isGif) {
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
    _input.text = picked.emoji ?? '';
    await _sendChat();
  }

  Future<void> _sendChat() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final me = supabase.auth.currentUser;
    try {
      await supabase.from('live_chat_messages').insert({
        'live_stream_id': widget.stream.id,
        'sender_id': me?.id,
        'body': text,
        'kind': 'text',
      });
      // The insert lands back via the live-chat Realtime subscription
      // (_appendChatRow), which appends it to _chat — no local echo here,
      // or it would show twice.
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_session.backHandler == _end) _session.backHandler = null;
    _diamonds.dispose();
    _music?.dispose();
    WakelockPlus.disable().catchError((_) {});
    _ticker?.cancel();
    _elapsed.dispose();
    _heartbeat?.cancel();
    _input.dispose();
    _effects.dispose();
    _chatChannel?.unsubscribe();
    _viewerChannel?.unsubscribe();
    _seatSyncTimer?.cancel();
    _seatsChannel?.unsubscribe();
    _seatRequestsChannel?.unsubscribe();
    AgoraService.instance.release();
    super.dispose();
  }


  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_reconcileSeats());
  }

  /// "Minimize" is hidden while already minimized (tapping the bubble's own
  /// X) — offering to minimize what's already minimized was confusing.
  Future<void> _end() async {
    final session = context.read<ActiveLiveSessionController>();
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('End live stream?'),
        content: Text(
          'You streamed for ${_fmt(_elapsed.value)} to $_viewers viewer${_viewers == 1 ? '' : 's'}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'keep'),
            child: const Text('Keep going'),
          ),
          if (!session.isMinimized)
            TextButton(
              onPressed: () => Navigator.pop(context, 'minimize'),
              child: const Text('Minimize'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'end'),
            child: const Text('End', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'minimize') {
      session.minimize();
      return;
    }
    if (choice != 'end') return;
    try {
      await context.read<LiveStreamsController>().endStream(widget.stream.id);
    } catch (_) {
      /* row may be gone; ending locally matters more */
    }
    // Ends the session slot — the root overlay (app.dart) stops building
    // this widget, which is what actually triggers dispose() (and all the
    // real cleanup above) now that this isn't a pushed route to pop.
    session.end();
  }

  static String _fmt(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String get _roomIdLabel => 'Room ID: ${shortDisplayId(widget.stream.id)}';

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
  );

  void _soon(String what) => _snack('$what — coming soon');

  Future<void> _toggleMic() async {
    setState(() => _micMuted = !_micMuted);
    try {
      await _engine?.muteLocalAudioStream(_micMuted);
    } catch (_) {}
    // Audio rooms: the host occupies a numbered seat like anyone else, so
    // their own mute needs to update that seat's is_muted too — otherwise
    // everyone else's seat shows the mic-off badge when muted, but the
    // host's own seat never did, since this only ever touched the local
    // Agora stream, never the DB flag the seat grid actually renders from.
    if (widget.audioOnly) {
      int? mySeat;
      for (final entry in _seatOccupants.entries) {
        if (entry.value.id == widget.stream.host.id) {
          mySeat = entry.key;
          break;
        }
      }
      if (mySeat case final seat?) {
        setState(() {
          if (_micMuted) {
            _mutedSeats.add(seat);
          } else {
            _mutedSeats.remove(seat);
          }
        });
      }
      try {
        await supabase.rpc(
          'set_seat_mute',
          params: {'p_stream_id': widget.stream.id, 'p_muted': _micMuted},
        );
      } catch (_) {}
    }
  }

  Future<void> _toggleSpeaker() async {
    setState(() => _speakerOn = !_speakerOn);
    try {
      await _engine?.setEnableSpeakerphone(_speakerOn);
    } catch (_) {}
  }

  Future<void> _applyBeauty() async {
    final engine = _engine;
    if (engine == null) return;
    await AgoraService.instance.setBeautyEffect(
      engine,
      enabled: _beautyOn,
      options: BeautyOptions(
        lighteningContrastLevel: LighteningContrastLevel.lighteningContrastNormal,
        smoothnessLevel: _beautySmooth,
        lighteningLevel: _beautyWhiten,
        rednessLevel: _beautyRedness,
        sharpnessLevel: _beautySharpness,
      ),
    );
  }

  Future<void> _openBeautyPanel() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          Future<void> apply() async {
            setSheetState(() {});
            setState(() {});
            await _applyBeauty();
          }

          Widget slider(String label, double value, ValueChanged<double> onChanged) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                Slider(
                  value: value,
                  onChanged: _beautyOn
                      ? (v) {
                          onChanged(v);
                          apply();
                        }
                      : null,
                  activeColor: AppColors.primaryBright,
                ),
              ],
            );
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Beauty',
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const Spacer(),
                      Switch(
                        value: _beautyOn,
                        activeThumbColor: AppColors.primaryBright,
                        onChanged: (v) {
                          _beautyOn = v;
                          apply();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  slider('Smooth', _beautySmooth, (v) => _beautySmooth = v),
                  slider('Whiten', _beautyWhiten, (v) => _beautyWhiten = v),
                  slider('Redness', _beautyRedness, (v) => _beautyRedness = v),
                  slider('Sharpen', _beautySharpness, (v) => _beautySharpness = v),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ─────────────────────────────────────────────────────── Tools sheet
  Future<void> _openTools() async {
    final tools = <ToolSpec>[
      ToolSpec(
        Icons.bolt_rounded,
        'Invite PK',
        const Color(0xFFFF7A45),
        () => _soon('PK battles'),
      ),
      ToolSpec(
        Icons.casino_rounded,
        'Random PK',
        const Color(0xFFFF5C5C),
        () => _soon('PK battles'),
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
      // Songs from the phone: the host of an audio room only.
      if (widget.audioOnly)
        ToolSpec(
          Icons.music_note_rounded,
          'Play music',
          AppColors.pink,
          _openMusic,
        ),
      ToolSpec(
        Icons.campaign_rounded,
        'Funny voice',
        AppColors.magenta,
        () => _soon('Voice effects'),
      ),
      ToolSpec(
        Icons.wallpaper_rounded,
        'Room skin',
        const Color(0xFF2DD4BF),
        () {
          if (widget.audioOnly) {
            showRoomSkinSheet(context);
          } else {
            _snack('Room skins are for audio rooms');
          }
        },
      ),
      ToolSpec(
        Icons.ios_share_rounded,
        'Share',
        AppColors.diamond,
        _shareStream,
      ),
      ToolSpec(Icons.inbox_rounded, 'Inbox', const Color(0xFF818CF8), () {
        AppNav.open(context, const MessagesScreen());
      }),
      ToolSpec(
        Icons.settings_voice_rounded,
        'Voice Control',
        const Color(0xFF34D399),
        () {
          _toggleMic();
          _snack(_micMuted ? 'Microphone muted' : 'Microphone on');
        },
      ),
      ToolSpec(Icons.volume_up_rounded, 'Speaker', AppColors.success, () {
        _toggleSpeaker();
        _snack(_speakerOn ? 'Speaker on' : 'Speaker off');
      }),
      ToolSpec(
        Icons.assignment_rounded,
        'Notice',
        AppColors.goldDeep,
        _editNotice,
      ),
      ToolSpec(
        Icons.speaker_notes_off_rounded,
        'Clear chat',
        const Color(0xFFFB923C),
        _clearChat,
      ),
      ToolSpec(
        Icons.block_rounded,
        'Block viewer',
        AppColors.danger,
        _blockViewer,
      ),
    ];

    await showToolGridSheet(context, title: 'Tools', tools: tools);
  }

  /// Gifting targets a seated participant — only people actually on a seat
  /// are real enough participants to gift, per Rey's scoping. Who it goes to
  /// (one seated person, or everyone via "All") is now picked inside the
  /// gift sheet itself via its avatar row, not a separate picker step.
  /// Everyone worth gifting: the host themself plus anyone currently
  /// seated, deduped by id. Previously only seated guests were offered —
  /// a video host (who, unlike audio, doesn't auto-occupy a seat) had no
  /// way to gift themselves at all. Matches the same helper on the
  /// viewer screens.
  List<AppUser> _giftRecipients() {
    final byId = <String, AppUser>{widget.stream.host.id: widget.stream.host};
    for (final u in _seatOccupants.values) {
      byId[u.id] = u;
    }
    return byId.values.toList();
  }

  Future<void> _pickGift() async {
    final choice = await showGiftSheet(
      context,
      hostName: widget.stream.host.name,
      recipients: _giftRecipients(),
    );
    if (choice == null || !mounted) return;
    if (choice.sendToAll) {
      // Send All always sends exactly one copy per recipient regardless of
      // the quantity picker — quantity × every seated guest could add up to
      // a very large, surprising coin spend in one tap otherwise. It is one server
      // action (send_gift_to_all): charged up front, one chat line "sent <gift> to All".
      await _sendGiftToAll(choice.gift);
      return;
    }
    final recipient = choice.recipient;
    if (recipient == null) return;
    await _sendGift(choice.gift, recipient, quantity: choice.quantity);
  }

  Future<void> _sendGiftToAll(Gift gift) async {
    final wallet = context.read<WalletController>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await wallet.sendGiftToAll(
        gift,
        liveStreamId: widget.stream.id,
        fallbackRecipients: _giftRecipients(),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
      return;
    }
    if (!mounted) return;
    _effects.enqueue(
      RoomEffect.gift(
        gift: gift,
        senderName: 'You',
        senderId: supabase.auth.currentUser?.id,
        toAll: true,
      ),
    );
  }

  // No local chat echo here anymore — send_gift now inserts a real kind
  // 'gift' live_chat_messages row server-side (one per unit sent), which
  // arrives back through this screen's own Realtime chat subscription like
  // any other message, visible to the host AND every viewer, not just
  // whoever tapped Send. Adding a local echo on top would double it up.
  // The gift ANIMATION is different: rows from this user are skipped by the
  // effect controller, so the sender plays their own here.
  Future<void> _sendGift(
    Gift gift,
    AppUser recipient, {
    int quantity = 1,
  }) async {
    final wallet = context.read<WalletController>();
    final messenger = ScaffoldMessenger.of(context);
    var sent = 0;
    try {
      for (var i = 0; i < quantity; i++) {
        await wallet.sendGift(gift, recipient, liveStreamId: widget.stream.id);
        sent++;
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
    if (sent > 0 && mounted) {
      _effects.enqueue(
        RoomEffect.gift(
          gift: gift,
          senderName: 'You',
          senderId: supabase.auth.currentUser?.id,
          count: sent,
        ),
      );
    }
  }

  /// Removes a viewer from this live and stops them rejoining it.
  Future<void> _blockViewer() async {
    final viewer = await pickViewer(
      context,
      streamId: widget.stream.id,
      hostId: widget.stream.host.id,
    );
    if (viewer == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: Text('Remove ${viewer.name}?'),
        content: const Text(
          "They'll be taken out of this live and won't be able to rejoin it.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Remove',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await SocialRepository().blockViewer(widget.stream.id, viewer.id);
      _snack('${viewer.name} was removed');
    } catch (e) {
      _snack(friendlyError(e));
    }
  }

  Future<void> _shareStream() => showShareSheet(
    context,
    title: '${widget.stream.host.name} is live on SABALIVE — join now!',
    url: liveShareUrl(widget.stream.id),
  );

  LocalMusicController? _music;

  /// Songs from the phone, played into the live (see LocalMusicController).
  void _openMusic() {
    final engine = _engine;
    if (engine == null) {
      _snack('Still connecting — try again in a moment');
      return;
    }
    showMusicSheet(context, _music ??= LocalMusicController(engine));
  }

  /// Clears the chat for everyone in the room: the server stamps the stream, and
  /// every screen (this one included) drops the lines it holds when that arrives.
  Future<void> _clearChat() async {
    try {
      await supabase.rpc('clear_live_chat', params: {'p_stream_id': widget.stream.id});
      if (!mounted) return;
      setState(_chat.clear);
      _snack('Chat cleared for everyone');
    } catch (e) {
      if (mounted) _snack(friendlyError(e));
    }
  }

  /// The room notice: pinned above the chat for every viewer (including anyone who
  /// joins later) until the host unpins it. Lives on the stream row, so pinning,
  /// editing and unpinning reach everyone straight away.
  Future<void> _editNotice() async {
    final existing = _room.notice;
    final controller = TextEditingController(text: existing ?? '');
    const unpinResult = '__unpin__';
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('Room notice'),
        content: TextField(
          controller: controller,
          maxLength: 120,
          maxLines: 2,
          decoration: InputDecoration(
            hintText: tr('Pin a message for viewers'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          if (existing != null)
            TextButton(
              onPressed: () => Navigator.pop(context, unpinResult),
              child: const Text(
                'Unpin',
                style: TextStyle(color: AppColors.danger),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Pin'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    if (result != unpinResult && result.isEmpty) return;
    try {
      final notice = result == unpinResult ? null : result;
      await supabase.rpc(
        'set_live_notice',
        params: {'p_stream_id': widget.stream.id, 'p_notice': notice},
      );
      if (!mounted) return;
      setState(() => _room.notice = notice);
      _snack(notice == null ? 'Notice unpinned' : 'Notice pinned');
    } catch (e) {
      if (mounted) _snack(friendlyError(e));
    }
  }

  Future<void> _changeSeatCount(int delta) async {
    final next = (_seatCount + delta).clamp(5, 25);
    setState(() => _seatCount = next);
    try {
      await supabase.rpc(
        'set_seat_count',
        params: {'p_stream_id': widget.stream.id, 'p_count': next},
      );
    } catch (e) {
      if (mounted) _snack(friendlyError(e));
    }
  }

  Future<void> _seatMenu(int seat) async {
    final locked = _lockedSeats.contains(seat);
    final muted = _mutedSeats.contains(seat);
    final myId = supabase.auth.currentUser?.id;
    final occupant = _seatOccupants[seat];
    final isMySeat = occupant?.id == myId;
    // Audio rooms only — the host can move into any open seat, same as
    // guests, instead of only ever occupying a separate seat of their own.
    final canSitHere = widget.audioOnly && !isMySeat && occupant == null;
    final canModerate = occupant != null && !isMySeat;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                occupant != null
                    ? 'Seat $seat · ${occupant.name}'
                    : 'Seat $seat',
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (canSitHere)
              ListTile(
                leading: const Icon(Icons.event_seat_rounded),
                title: const Text('Sit here'),
                onTap: () => Navigator.pop(context, 'sit'),
              ),
            ListTile(
              leading: Icon(
                locked ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
              ),
              title: Text(locked ? 'Unlock seat' : 'Lock seat'),
              onTap: () => Navigator.pop(context, 'lock'),
            ),
            if (canModerate) ...[
              ListTile(
                leading: Icon(
                  muted ? Icons.mic_rounded : Icons.mic_off_rounded,
                ),
                title: Text(muted ? 'Unmute' : 'Mute'),
                onTap: () => Navigator.pop(context, 'mute'),
              ),
              ListTile(
                leading: const Icon(Icons.person_remove_rounded),
                title: const Text('Kick from seat'),
                onTap: () => Navigator.pop(context, 'kick'),
              ),
              ListTile(
                leading: const Icon(
                  Icons.block_rounded,
                  color: AppColors.danger,
                ),
                title: const Text(
                  'Ban from seats',
                  style: TextStyle(color: AppColors.danger),
                ),
                onTap: () => Navigator.pop(context, 'ban'),
              ),
            ] else if (!widget.audioOnly && occupant == null) ...[
              // Video seats are request-only — an empty seat's tap shows
              // whoever's asked to join, approving them straight into this
              // seat, instead of the old fake "Invite someone" stub.
              if (_pendingSeatRequests.isEmpty)
                const ListTile(
                  leading: Icon(
                    Icons.info_outline_rounded,
                    color: AppColors.textMuted,
                  ),
                  title: Text(
                    'No pending seat requests',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                )
              else
                for (final r in _pendingSeatRequests)
                  ListTile(
                    leading: AppAvatar(
                      name: r.requester.name,
                      imageUrl: r.requester.avatarUrl,
                      size: 36,
                    ),
                    title: Text(r.requester.name),
                    trailing: const Text('Approve'),
                    onTap: () =>
                        Navigator.pop(context, 'approve:${r.requestId}'),
                  ),
            ] else
              ListTile(
                leading: const Icon(Icons.person_add_alt_1_rounded),
                title: const Text('Invite someone'),
                onTap: () => Navigator.pop(context, 'invite'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'sit') {
      try {
        await supabase.rpc(
          'claim_seat',
          params: {'p_stream_id': widget.stream.id, 'p_seat': seat},
        );
      } catch (e) {
        if (mounted) _snack(friendlyError(e));
      }
    } else if (choice == 'mute') {
      try {
        await supabase.rpc(
          'host_set_seat_mute',
          params: {
            'p_stream_id': widget.stream.id,
            'p_seat': seat,
            'p_muted': !muted,
          },
        );
        if (mounted) {
          _snack(
            '${occupant?.name ?? 'Seat $seat'} ${!muted ? 'muted' : 'unmuted'}',
          );
        }
      } catch (e) {
        if (mounted) _snack(friendlyError(e));
      }
    } else if (choice == 'kick') {
      try {
        await supabase.rpc(
          'kick_seat_occupant',
          params: {'p_stream_id': widget.stream.id, 'p_seat': seat},
        );
        if (mounted) {
          setState(() {
            _seatOccupants.remove(seat);
            _mutedSeats.remove(seat);
            _speaking.unbindSeat(seat);
          });
        }
        if (mounted)
          _snack('${occupant?.name ?? 'User'} removed from the seat');
      } catch (e) {
        if (mounted) _snack(friendlyError(e));
      }
    } else if (choice == 'ban') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppColors.bgElevated,
          title: const Text('Ban from seats?'),
          content: Text(
            '${occupant?.name ?? 'This user'} won\'t be able to take a seat in this stream again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Ban'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      try {
        await supabase.rpc(
          'ban_seat_occupant',
          params: {'p_stream_id': widget.stream.id, 'p_seat': seat},
        );
        if (mounted) {
          setState(() {
            _seatOccupants.remove(seat);
            _mutedSeats.remove(seat);
            _speaking.unbindSeat(seat);
          });
        }
        if (mounted) _snack('${occupant?.name ?? 'User'} banned from seats');
      } catch (e) {
        if (mounted) _snack(friendlyError(e));
      }
    } else if (choice == 'lock') {
      final wantLocked = !locked;
      setState(() {
        if (wantLocked) {
          _lockedSeats.add(seat);
        } else {
          _lockedSeats.remove(seat);
        }
      });
      try {
        await supabase.rpc(
          'set_seat_lock',
          params: {
            'p_stream_id': widget.stream.id,
            'p_seat': seat,
            'p_locked': wantLocked,
          },
        );
        if (mounted) _snack('Seat $seat ${wantLocked ? 'locked' : 'unlocked'}');
      } catch (e) {
        // Roll back the optimistic change — otherwise a failed write here
        // leaves the UI showing "locked" while the DB (and everyone else)
        // still sees it unlocked, until the next unrelated live_streams
        // update silently snaps the display back — looking like the lock
        // randomly reverted itself.
        if (mounted) {
          setState(() {
            if (wantLocked) {
              _lockedSeats.remove(seat);
            } else {
              _lockedSeats.add(seat);
            }
          });
          _snack(friendlyError(e));
        }
      }
    } else if (choice == 'invite') {
      _soon('Seat invites');
    } else if (choice != null && choice.startsWith('approve:')) {
      await _approveSeatRequest(choice.substring('approve:'.length), seat);
    }
  }

  Future<void> _openRequests() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Seat requests',
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 16),
                if (_pendingSeatRequests.isEmpty) ...[
                  Icon(
                    Icons.group_add_rounded,
                    size: 40,
                    color: AppColors.textMuted.withValues(alpha: 0.6),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'No one has asked to join yet.',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12.5,
                    ),
                  ),
                ] else
                  for (final r in _pendingSeatRequests)
                    ListTile(
                      leading: AppAvatar(
                        name: r.requester.name,
                        imageUrl: r.requester.avatarUrl,
                        size: 40,
                      ),
                      title: Text(r.requester.name),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.close_rounded,
                              color: AppColors.danger,
                            ),
                            onPressed: () async {
                              await _declineSeatRequest(r.requestId);
                              setSheetState(() {});
                            },
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.check_rounded,
                              color: AppColors.success,
                            ),
                            onPressed: () async {
                              final seat = _firstEmptySeat();
                              if (seat == null) {
                                _snack('No empty seats right now');
                                return;
                              }
                              await _approveSeatRequest(r.requestId, seat);
                              setSheetState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────── build
  //
  // This widget is mounted by the app-root overlay in app.dart (via
  // ActiveLiveSessionController), not pushed as a Navigator route. Back
  // button handling is didPopRoute() above (WidgetsBindingObserver), not
  // PopScope/BackButtonListener — see that method's own doc comment. When
  // minimized, this returns just the bare bubble Stack with nothing
  // wrapping it, so taps/back-navigation flow straight through to
  // whatever's actually on screen underneath.
  @override
  Widget build(BuildContext context) {
    final minimized = context.watch<ActiveLiveSessionController>().isMinimized;
    return minimized ? _buildMinimized() : _buildFull(context);
  }

  Widget _buildMinimized() {
    // No Material wrapper here on purpose — LiveMinimizedBubble doesn't use
    // any Material-dependent widgets (no InkWell/splash), and Material's own
    // ink-detection layer claims hit-tests across its ENTIRE bounds even
    // with type: transparency and nothing painted. A bare Stack only
    // hit-tests where its children actually are, letting empty space fall
    // through to whatever's underneath.
    return Stack(
      children: [
        LiveMinimizedBubble(
          host: widget.stream.host,
          onTap: () => context.read<ActiveLiveSessionController>().restore(),
          onClose: _end,
        ),
      ],
    );
  }

  Widget _buildFull(BuildContext context) {
    final diamonds = context.watch<WalletController>().diamonds;

    return Scaffold(
      backgroundColor: Colors.black,
      // The camera stage keeps its size when the keyboard opens (resizing a live video
      // surface on every keyboard frame is slow and can crash some phones).
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.audioOnly)
            SeatRoom(
              hostId: widget.stream.host.id,
              skinUrl: _skinUrl,
              error: _error,
              seatCount: _seatCount,
              lockedSeats: _lockedSeats,
              occupants: _seatOccupants,
              mutedSeats: _mutedSeats,
              speakingSeats: _speakingSeats,
              diamonds: _diamonds.all,
              onSeatTap: _seatMenu,
              onAddSeat: _seatCount >= 25 ? null : () => _changeSeatCount(5),
              onRemoveSeat: _seatCount <= 5 ? null : () => _changeSeatCount(-5),
            )
          else if (_engine != null)
            AgoraVideoView(
              controller: VideoViewController(
                rtcEngine: _engine!,
                canvas: const VideoCanvas(uid: 0),
              ),
            )
          else
            ColoredBox(
              color: Colors.black,
              child: Center(
                child: _error != null
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      )
                    : CircularProgressIndicator(
                        color: AppColors.primaryBright,
                      ),
              ),
            ),

          // subtle top + bottom scrims for legibility
          const _Scrim(),

          // gift animation, for everyone in the room
          Positioned.fill(child: RoomEffectLayer(controller: _effects)),

          // The keyboard moves nothing here: only the chat and the input bar are painted higher
          // (KeyboardStable / KeyboardLift); the rail and the seat strip stay behind the keyboard.
          KeyboardStable(
            child: SafeArea(
              bottom: false,
              child: Stack(
                children: [
                  // ── top bar
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 6,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ConnectionBanner(reconnecting: _reconnecting, failure: _connectionFailure),
                        Row(
                          children: [
                            _hostChip(),
                            const Spacer(),
                            _circle(
                              '$_viewers',
                              onTap: () =>
                                  showViewerListSheet(context, widget.stream.id),
                            ),
                            const SizedBox(width: 8),
                            _circle(
                              null,
                              icon: Icons.close_rounded,
                              iconColor: AppColors.danger,
                              onTap: _end,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            ValueListenableBuilder<Duration>(
                              valueListenable: _elapsed,
                              builder: (_, elapsed, _) =>
                                  _miniPill(Icons.schedule_rounded, _fmt(elapsed)),
                            ),
                            const SizedBox(width: 8),
                            _miniPill(
                              Icons.diamond_rounded,
                              compactCount(diamonds),
                              tint: AppColors.diamond,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // ── Lucky Box (left, under the time / diamonds pills) — a real
                  //    video live only; counts down to the host's reward
                  if (!widget.audioOnly && isRealId(widget.stream.id))
                    Positioned(
                      left: 12,
                      top: 100,
                      child: LuckyBoxBadge(streamId: widget.stream.id),
                    ),

                  // ── beauty (top-right, below the top bar) — video only
                  if (!widget.audioOnly)
                    Positioned(
                      right: 12,
                      top: 58,
                      child: GestureDetector(
                        onTap: _openBeautyPanel,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            gradient: AppColors.primaryGradient,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _beautyOn
                                    ? Icons.auto_awesome_rounded
                                    : Icons.auto_awesome_outlined,
                                size: 14,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 5),
                              const Text(
                                'Beauty',
                                style: TextStyle(
                                  fontFamily: 'Poppins',
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // ── bottom stack: warning + chat + right rail + bar
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [if (_chat.isNotEmpty) KeyboardLift(child: _chatList())],
                              ),
                            ),
                            _rightRail(),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (!widget.audioOnly) ...[
                          CompactSeatStrip(
                            seatCount: _seatCount,
                            occupants: _seatOccupants,
                            lockedSeats: _lockedSeats,
                            mutedSeats: _mutedSeats,
                            speakingSeats: _speakingSeats,
                            onSeatTap: _seatMenu,
                          ),
                          const SizedBox(height: 6),
                        ],
                        const SizedBox(height: 6),
                        KeyboardLift(child: _bottomBar()),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Smaller, Instagram/TikTok-Live-style minimal host badge — was a larger
  // chip showing the HOST's own id; now shows the ROOM's id instead (a
  // stream is its own thing, distinct from whoever's hosting it), reusing
  // the same shortDisplayId hash already used for user ids elsewhere, just
  // fed the stream's id instead of a profile's.
  Widget _hostChip() {
    return Container(
      padding: const EdgeInsets.fromLTRB(3, 3, 10, 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(26),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SpeakingWaves(
            active: _hostSpeaking,
            diameter: 24,
            child: AppAvatar(
              name: widget.stream.host.name,
              imageUrl: widget.stream.host.avatarUrl,
              frameUrl: widget.stream.host.frameUrl,
              size: 24,
            ),
          ),
          const SizedBox(width: 6),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 110),
                child: Text(
                  widget.stream.host.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                    color: Colors.white,
                  ),
                ),
              ),
              Text(
                _roomIdLabel,
                style: const TextStyle(fontSize: 8.5, color: Colors.white70),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniPill(IconData icon, String label, {Color tint = Colors.white}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: tint),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'Poppins',
              fontWeight: FontWeight.w600,
              fontSize: 11,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _circle(
    String? label, {
    IconData? icon,
    Color iconColor = Colors.white,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.42),
          shape: BoxShape.circle,
        ),
        child: icon != null
            ? Icon(icon, size: 18, color: iconColor)
            : Text(
                label ?? '',
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: Colors.white,
                ),
              ),
      ),
    );
  }

  Widget _iconCircle(IconData icon, VoidCallback onTap, {double size = 40}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.42),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.5),
      ),
    );
  }

  Widget _chatList() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 190),
      padding: const EdgeInsets.only(left: 14, right: 8),
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
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: GestureDetector(
                      onTap: isRealId(line.user.id)
                          ? () => AppNav.userProfile(context, line.user)
                          : null,
                      child: LiveChatLineBubble(key: ObjectKey(line), line: line, backgroundAlpha: 0.36, pinnedAlpha: 0.5),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _rightRail() {
    return Padding(
      padding: const EdgeInsets.only(right: 12, bottom: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _iconCircle(
            _micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
            _toggleMic,
          ),
          // Co-host requests — video only. Audio rooms already have real
          // self-serve seating (claim_seat), so a separate "ask to co-host"
          // queue doesn't apply there.
          if (!widget.audioOnly) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: _openRequests,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 64,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      gradient: AppColors.primaryGradient,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Column(
                      children: [
                        Icon(
                          Icons.person_add_alt_1_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                        SizedBox(height: 3),
                        Text(
                          'REQUESTS',
                          style: TextStyle(
                            fontFamily: 'Poppins',
                            fontWeight: FontWeight.w700,
                            fontSize: 8,
                            letterSpacing: 0.3,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_pendingSeatRequests.isNotEmpty)
                    Positioned(
                      right: -4,
                      top: -4,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: AppColors.danger,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '${_pendingSeatRequests.length}',
                          style: const TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _bottomBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        8 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _iconCircle(Icons.more_horiz_rounded, _openTools, size: 34),
          const SizedBox(width: 6),
          _iconCircle(Icons.emoji_emotions_outlined, _openQuickEmoji, size: 34),
          const SizedBox(width: 6),
          _iconCircle(Icons.card_giftcard_rounded, _pickGift, size: 34),
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
                controller: _input,
                style: const TextStyle(fontSize: 13, color: Colors.white),
                minLines: 1,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: tr('Say something'),
                  hintStyle: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _sendChat,
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
}

// ─────────────────────────────────────────────────────── helper widgets

class _Scrim extends StatelessWidget {
  const _Scrim();
  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.35),
              Colors.transparent,
              Colors.transparent,
              Colors.black.withValues(alpha: 0.45),
            ],
            stops: const [0, 0.18, 0.68, 1],
          ),
        ),
      ),
    );
  }
}
