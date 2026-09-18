import 'dart:async';
import 'dart:math' as math;

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/supabase_client.dart';
import '../../core/utils/errors.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/ids.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/connection_banner.dart';
import '../../core/widgets/pills.dart';
import '../../data/mock_data.dart';
import '../../data/models.dart';
import '../../router/app_nav.dart';
import '../../services/agora_service.dart';
import '../../state/auth_controller.dart';
import '../../state/session_controller.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';
import 'widgets/gift_sheet.dart';
import 'widgets/seat_room.dart';

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
    with TickerProviderStateMixin {
  late final bool _isReal = isRealId(widget.stream.id);
  final List<LiveChatLine> _chat = [];
  final _msgController = TextEditingController();
  final _rand = math.Random();
  final List<_Heart> _hearts = [];
  Gift? _giftBurst;
  int _likes = 0;

  int? _remoteUid;
  RealtimeChannel? _chatChannel;
  String? _joinError;
  bool _reconnecting = false;
  Timer? _waitTimer;
  bool _waitingTooLong = false;

  RtcEngine? _engine;
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

  late final AnimationController _burstCtl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    _likes = widget.stream.likes;
    _burstCtl.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _giftBurst = null);
      }
    });
    if (_isReal) {
      _joinReal();
      _loadRealChat();
      _logViewerJoin();
      _subscribeSeats();
      // Mirrors the host's own heartbeat: keeps this viewer (and, while
      // seated, this seat) from being swept by finalize_stale_presence if
      // the connection silently dies instead of a clean dispose.
      _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
        supabase.rpc('heartbeat_viewer', params: {'p_stream_id': widget.stream.id});
        if (_mySeat != null) {
          supabase.rpc('heartbeat_seat', params: {'p_stream_id': widget.stream.id});
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
    } catch (_) {
      /* best-effort — a missed count beats a broken screen */
    }
  }

  /// Live seat occupancy + locks — mirrors the host's own subscription in
  /// live_broadcast_screen.dart so both sides see the identical room state.
  Future<void> _subscribeSeats() async {
    final rows = await supabase
        .from('live_stream_seats')
        .select(
            'seat_number, is_muted, profiles!live_stream_seats_occupant_id_fkey(*)')
        .eq('live_stream_id', widget.stream.id);
    final streamRow = await supabase
        .from('live_streams')
        .select('locked_seats, seat_count')
        .eq('id', widget.stream.id)
        .maybeSingle();
    if (mounted) {
      setState(() {
        for (final r in rows as List) {
          final profileRow = r['profiles'] as Map<String, dynamic>?;
          if (profileRow != null) {
            final seat = r['seat_number'] as int;
            _seatOccupants[seat] = AppUser.fromRow(profileRow);
            if (r['is_muted'] as bool? ?? false) _mutedSeats.add(seat);
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
            if (mounted && seat != null && muted != null) {
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
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'live_stream_id',
            value: widget.stream.id,
          ),
          callback: (payload) {
            final seat = payload.oldRecord['seat_number'] as int?;
            if (mounted && seat != null) {
              setState(() {
                _seatOccupants.remove(seat);
                _mutedSeats.remove(seat);
                if (_mySeat == seat) _mySeat = null;
              });
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
            if (!mounted) return;
            setState(() {
              if (locked != null) _lockedSeats = locked.cast<int>().toSet();
              if (count != null) _seatCount = count;
            });
          },
        )
        .subscribe();
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
      pinned: row['pinned'] as bool? ?? false,
    );
  }

  @override
  void dispose() {
    _waitTimer?.cancel();
    _heartbeat?.cancel();
    _msgController.dispose();
    _burstCtl.dispose();
    _chatChannel?.unsubscribe();
    _seatsChannel?.unsubscribe();
    _seatStreamChannel?.unsubscribe();
    if (_isReal) {
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
      await supabase.rpc('set_seat_mute', params: {
        'p_stream_id': widget.stream.id,
        'p_muted': next,
      });
    } catch (e) {
      if (mounted) {
        setState(() => _myMuted = !next);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
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

  Future<void> _openGifts() async {
    final gift = await showGiftSheet(
      context,
      hostName: widget.stream.host.name,
    );
    if (gift == null || !mounted) return;
    final me = context.read<AuthController>().user ?? Mock.me;
    try {
      await context.read<WalletController>().sendGift(
        gift,
        widget.stream.host,
        liveStreamId: _isReal ? widget.stream.id : null,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendlyError(e))));
      return;
    }
    if (!mounted) return;
    if (!_isReal) {
      setState(() {
        _giftBurst = gift;
        _chat.add(LiveChatLine(me, 'sent ${gift.name}', gift: true));
      });
    } else {
      setState(() => _giftBurst = gift);
    }
    _burstCtl.forward(from: 0);
  }

  Future<void> _moreActions() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(
                Icons.card_giftcard_rounded,
                color: AppColors.gold,
              ),
              title: Text('Send a gift · ${compactCount(widget.stream.gifts)}'),
              onTap: () => Navigator.pop(context, 'gift'),
            ),
            ListTile(
              leading: const Icon(Icons.reply_rounded),
              title: const Text('Share'),
              onTap: () => Navigator.pop(context, 'share'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == 'gift') await _openGifts();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final following = session.isFollowing(widget.stream.host.id);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          SeatRoom(
            host: widget.stream.host,
            error:
                _joinError ??
                (_waitingTooLong
                    ? "Still nothing from the host — they may have ended, "
                          "or there's a connection issue."
                    : null),
            seatCount: _seatCount,
            lockedSeats: _lockedSeats,
            occupants: _seatOccupants,
            mutedSeats: _mutedSeats,
            onSeatTap: _seatTap,
          ),
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
                const Spacer(),
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
          if (_giftBurst != null)
            Center(
              child: AnimatedBuilder(
                animation: _burstCtl,
                builder: (context, _) {
                  final v = Curves.easeOut.transform(_burstCtl.value);
                  return Opacity(
                    opacity: (1 - v).clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: 0.6 + v * 1.8,
                      child: Text(
                        _giftBurst!.emoji,
                        style: const TextStyle(fontSize: 90),
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
                          AppAvatar(name: widget.stream.host.name, size: 32),
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
                              Text(
                                '${compactCount(widget.stream.viewers)} in room',
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  color: Colors.white70,
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
                onTap: () => Navigator.pop(context),
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
      child: ListView.builder(
        reverse: true,
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
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: line.pinned
                      ? AppColors.primary.withValues(alpha: 0.35)
                      : Colors.black.withValues(alpha: 0.32),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: RichText(
                  text: TextSpan(
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontSize: 11.5,
                    ),
                    children: [
                      if (line.pinned)
                        const WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.push_pin_rounded,
                              size: 11,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      TextSpan(
                        text: '${line.user.name}  ',
                        style: TextStyle(
                          color: line.gift
                              ? AppColors.gold
                              : AppColors.primaryBright,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(
                        text: line.text,
                        style: TextStyle(
                          color: line.gift ? AppColors.gold : Colors.white,
                          fontWeight: line.gift
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
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
          item(Icons.more_horiz_rounded, 'More', _moreActions),
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

  Widget _inputBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white24),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _msgController,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      cursorColor: AppColors.primaryBright,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'Say something nice…',
                        hintStyle: TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                        ),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  GestureDetector(
                    onTap: _send,
                    child: const Icon(
                      Icons.send_rounded,
                      color: AppColors.primaryBright,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _like,
            child: Container(
              width: 42,
              height: 42,
              decoration: const BoxDecoration(
                gradient: AppColors.liveGradient,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.favorite_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
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
