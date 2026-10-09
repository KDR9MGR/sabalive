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
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/connection_banner.dart';
import '../../core/widgets/pills.dart';
import '../../data/models.dart';
import '../../data/profile_cache.dart';
import '../../data/pk_battles_repository.dart';
import '../../router/app_nav.dart';
import '../../services/agora_service.dart';
import '../../state/auth_controller.dart';
import '../../state/live_streams_controller.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';
import '../messages/messages_screen.dart';
import 'widgets/gift_sheet.dart';
import 'widgets/pk_arena.dart';
import 'widgets/pk_opponent_picker_sheet.dart';
import 'widgets/pk_score_bar.dart';
import 'widgets/tool_grid.dart';
import '../../core/i18n/text.dart';

/// Host-side PK battle room. Room chat/gifts and your own audio are real, as
/// always. The opponent and scoring are now real too: `pk_battles` is the
/// single source of truth (server-driven invite → accept → live → finished
/// state machine), never a client-side simulation — see
/// `PkBattlesRepository`.
class PkBattleScreen extends StatefulWidget {
  const PkBattleScreen({super.key, required this.stream, required this.token});
  final LiveStream stream;
  final AgoraToken token;

  @override
  State<PkBattleScreen> createState() => _PkBattleScreenState();
}

class _PkBattleScreenState extends State<PkBattleScreen>
    with SingleTickerProviderStateMixin {
  final _pkRepo = PkBattlesRepository();

  // Gift burst — reacts to _battle.lastGiftSeq (see _onBattleUpdate), so it
  // plays for the host regardless of who sent the gift or which side it
  // landed on, not just when this screen's own owner taps send.
  Gift? _giftBurst;
  bool _giftBurstOnSideA = true;
  late final AnimationController _burstCtl =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1400),
      )..addStatusListener((s) {
        if (s == AnimationStatus.completed && mounted) {
          setState(() => _giftBurst = null);
        }
      });

  RtcEngine? _engine;
  RealtimeChannel? _chatChannel;
  RealtimeChannel? _viewerChannel;
  int _viewers = 0;
  bool _reconnecting = false;
  bool _micMuted = false;

  // Real join/leave lines now come from live_chat_messages itself (see
  // join_live_stream/leave_live_stream) — these used to be hardcoded fake
  // seed users that never actually existed.
  final List<LiveChatLine> _chat = [];
  final _input = TextEditingController();

  // The opponent's side (right) stays host-local/decorative — approving
  // seats there is that host's own business, from their own screen. My own
  // side (left) is real: real occupants + real pending requests, below.
  int _seatsPerSide = 2;
  final Set<String> _lockedSeats = {}; // keys like 'L1', 'R2'

  final Map<int, AppUser> _mySeatOccupants = {};
  final List<({String requestId, AppUser requester})> _pendingSeatRequests = [];
  RealtimeChannel? _mySeatsChannel;
  RealtimeChannel? _seatRequestsChannel;

  Timer? _heartbeat;
  Timer? _clockTicker;

  PkBattleInfo? _battle;
  AppUser? _opponentUser;
  RealtimeChannel? _inviteChannel;
  RealtimeChannel? _battleChannel;
  bool _battleBusy = false;
  String? _agoraChannelTarget;

  @override
  void initState() {
    super.initState();
    // See the same note in live_broadcast_screen.dart.
    WakelockPlus.enable().catchError((_) {});
    _join();
    _subscribeChat();
    _subscribeViewerCount();
    _subscribeMySeats();
    _subscribeSeatRequests();
    _loadBattle();
    _inviteChannel = _pkRepo.subscribeIncomingInvites(_onBattleUpdate);
    final liveStreams = context.read<LiveStreamsController>();
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      liveStreams.heartbeat(widget.stream.id);
    });
    // Purely a display tick — recomputes remaining time from the server's
    // own ends_at every second, never owns or decrements a duration itself.
    _clockTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _battle?.isLive == true) setState(() {});
    });
  }

  Future<void> _join() async {
    try {
      final engine = await AgoraService.instance.ensureEngine();
      _engine = engine;
      engine.registerEventHandler(
        RtcEngineEventHandler(
          onError: (err, msg) {},
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
        channelName: widget.token.channelName,
        asBroadcaster: true,
      );
      await engine.enableLocalVideo(false);
      await engine.joinChannel(
        token: widget.token.token,
        channelId: widget.token.channelName,
        uid: widget.token.uid,
        options: const ChannelMediaOptions(
          channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
        ),
      );
      _agoraChannelTarget = widget.stream.id;
    } catch (e) {
      if (mounted) _toast(friendlyError(e));
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(m), duration: const Duration(seconds: 2)),
  );

  void _subscribeChat() {
    _chatChannel = supabase
        .channel('pk-chat-${widget.stream.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'live_chat_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'live_stream_id',
            value: widget.stream.id,
          ),
          callback: (payload) => _appendRow(payload.newRecord),
        )
        .subscribe();
  }

  /// See the same note in live_broadcast_screen.dart — Agora's
  /// onUserJoined/onUserOffline doesn't report audience-role joins in Live
  /// Broadcasting mode, so viewer count comes from the DB instead.
  void _subscribeViewerCount() {
    _viewerChannel = supabase
        .channel('pk-viewers-${widget.stream.id}')
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
            if (mounted && count != null) setState(() => _viewers = count);
          },
        )
        .subscribe();
  }

  /// My own side's real seat occupancy — reuses the exact same
  /// live_stream_seats table/RLS/realtime shape already proven for audio
  /// and video rooms; PK seats are just guest seats on this stream too,
  /// only gated by host-approval instead of self-serve (see claim_seat).
  Future<void> _subscribeMySeats() async {
    final rows = await supabase
        .from('live_stream_seats')
        .select('seat_number, profiles!live_stream_seats_occupant_id_fkey(*)')
        .eq('live_stream_id', widget.stream.id);
    if (mounted) {
      setState(() {
        for (final r in rows as List) {
          final profileRow = r['profiles'] as Map<String, dynamic>?;
          if (profileRow != null) {
            _mySeatOccupants[r['seat_number'] as int] = AppUser.fromRow(
              profileRow,
            );
          }
        }
      });
    }
    _mySeatsChannel = supabase
        .channel('pk-myseats-${widget.stream.id}')
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
            final profileRow = await ProfileCache.instance.get(occupantId);
            if (mounted && profileRow != null) {
              setState(
                () => _mySeatOccupants[seat] = AppUser.fromRow(profileRow),
              );
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
            if (mounted && seat != null) {
              setState(() => _mySeatOccupants.remove(seat));
            }
          },
        )
        .subscribe();
  }

  /// Pending "may I have a seat?" requests for my own side.
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
        .channel('pk-seatreqs-${widget.stream.id}')
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

  Future<void> _onSeatTapA(int seat) async {
    final occupant = _mySeatOccupants[seat];
    if (occupant != null) {
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
                  'Seat $seat · ${occupant.name}',
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w600,
                  ),
                ),
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
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (choice == 'kick') {
        try {
          await supabase.rpc(
            'kick_seat_occupant',
            params: {'p_stream_id': widget.stream.id, 'p_seat': seat},
          );
        } catch (e) {
          if (mounted) _toast(friendlyError(e));
        }
      } else if (choice == 'ban') {
        try {
          await supabase.rpc(
            'ban_seat_occupant',
            params: {'p_stream_id': widget.stream.id, 'p_seat': seat},
          );
        } catch (e) {
          if (mounted) _toast(friendlyError(e));
        }
      }
      return;
    }

    if (_pendingSeatRequests.isEmpty) {
      _toast('No pending seat requests');
      return;
    }
    final chosen = await showModalBottomSheet<String>(
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
                'Seat $seat requests',
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final r in _pendingSeatRequests)
              ListTile(
                leading: AppAvatar(
                  name: r.requester.name,
                  imageUrl: r.requester.avatarUrl,
                  size: 36,
                ),
                title: Text(r.requester.name),
                trailing: TextButton(
                  onPressed: () => Navigator.pop(context, r.requestId),
                  child: const Text('Approve'),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    try {
      await supabase.rpc(
        'approve_pk_seat_request',
        params: {'p_request_id': chosen, 'p_seat': seat},
      );
    } catch (e) {
      if (mounted) _toast(friendlyError(e));
    }
  }

  // ─────────────────────────────────────── real PK battle state machine

  Future<void> _loadBattle() async {
    final battle = await _pkRepo.currentBattleFor(widget.stream.id);
    if (battle != null) await _onBattleUpdate(battle);
  }

  Future<void> _onBattleUpdate(PkBattleInfo battle) async {
    if (!mounted) return;
    final wasId = _battle?.id;
    final prevStatus = _battle?.status;
    final prevGiftSeq = _battle?.lastGiftSeq ?? 0;
    setState(() => _battle = battle);

    if (battle.lastGiftSeq > prevGiftSeq && battle.lastGiftId != null) {
      _playGiftBurst(battle.lastGiftId!, battle.lastGiftSide == 'a');
    }

    if (wasId != battle.id) {
      _battleChannel?.unsubscribe();
      _battleChannel = _pkRepo.subscribeBattle(battle.id, _onBattleUpdate);
    }

    if (_opponentUser == null || wasId != battle.id) {
      final opponentId = battle.hostAId == widget.stream.host.id
          ? battle.hostBId
          : battle.hostAId;
      final profile = await _pkRepo.profile(opponentId);
      if (mounted) setState(() => _opponentUser = profile);
    }

    await _syncAgoraChannel(battle);

    if (battle.status == 'accepted' && prevStatus != 'accepted') {
      _startCountdown(battle.id);
    }
    if (battle.status == 'finished' && prevStatus != 'finished') {
      _showResult(battle);
    }
    if (battle.isTerminal) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && _battle?.id == battle.id) setState(() => _battle = null);
      });
    }
  }

  Future<void> _syncAgoraChannel(PkBattleInfo battle) async {
    final engine = _engine;
    if (engine == null) return;
    final target = battle.isLive ? battle.agoraChannel : widget.stream.id;
    if (_agoraChannelTarget == target) return;
    _agoraChannelTarget = target;
    try {
      await AgoraService.instance.switchChannel(
        engine,
        newChannelName: target,
        asBroadcaster: true,
      );
    } catch (e) {
      if (mounted) _toast(friendlyError(e));
    }
  }

  void _startCountdown(String battleId) async {
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted || _battle?.id != battleId || _battle?.status != 'accepted')
      return;
    try {
      final updated = await _pkRepo.begin(battleId);
      await _onBattleUpdate(updated);
    } catch (_) {
      // The other host may have already started it, or it ended meanwhile.
    }
  }

  Future<void> _cancelBattle(String battleId) async {
    setState(() => _battleBusy = true);
    try {
      await _pkRepo.cancel(battleId);
    } catch (e) {
      if (mounted) _toast(friendlyError(e));
    } finally {
      if (mounted) setState(() => _battleBusy = false);
    }
  }

  Future<void> _respond(String battleId, bool accept) async {
    setState(() => _battleBusy = true);
    try {
      final updated = await _pkRepo.respond(battleId, accept);
      await _onBattleUpdate(updated);
    } catch (e) {
      if (mounted) _toast(friendlyError(e));
    } finally {
      if (mounted) setState(() => _battleBusy = false);
    }
  }

  Future<void> _showResult(PkBattleInfo battle) async {
    final youAreA = battle.hostAId == widget.stream.host.id;
    final myScore = youAreA ? battle.scoreA : battle.scoreB;
    final oppScore = youAreA ? battle.scoreB : battle.scoreA;
    final youWin =
        (youAreA && battle.winner == 'a') || (!youAreA && battle.winner == 'b');
    final draw = battle.winner == 'draw';
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: Text(draw ? 'Draw!' : (youWin ? 'You win! 🏆' : 'You lost')),
        content: Text(
          'Final score  ${compactCount(myScore)}  vs  ${compactCount(oppScore)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _appendRow(Map<String, dynamic> row) async {
    final senderId = row['sender_id'] as String?;
    final prof = senderId == null ? null : await ProfileCache.instance.get(senderId);
    final sender = prof != null
        ? AppUser.fromRow(prof)
        : AppUser(id: senderId ?? 'x', name: 'Someone', username: '@u');
    final isGift = row['kind'] == 'gift';
    if (!mounted) return;
    setState(() {
      _chat.add(
        LiveChatLine(sender, row['body'] as String? ?? '', gift: isGift),
      );
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    try {
      await supabase.from('live_chat_messages').insert({
        'live_stream_id': widget.stream.id,
        'sender_id': supabase.auth.currentUser?.id,
        'body': text,
        'kind': 'text',
      });
      // Realtime echoes it back via _appendRow — no local add here, or it
      // would show twice.
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  /// Real battle: no local call needed — sendGift updates the pk_battles
  /// row's last_gift_seq, which arrives back through this same screen's own
  /// _onBattleUpdate subscription, so triggering it here too would double it.
  void _playGiftBurst(String giftId, bool onSideA) {
    final gifts = context.read<WalletController>().gifts;
    Gift? gift;
    for (final g in gifts) {
      if (g.id == giftId) {
        gift = g;
        break;
      }
    }
    if (gift == null || !mounted) return;
    setState(() {
      _giftBurst = gift;
      _giftBurstOnSideA = onSideA;
    });
    _burstCtl.forward(from: 0);
  }

  Future<void> _pickGift() async {
    final choice = await showGiftSheet(
      context,
      hostName: widget.stream.host.name,
    );
    if (choice == null) return;
    await _onGift(choice.gift, quantity: choice.quantity);
  }

  // send_gift/send_pk_gift now insert a real kind 'gift' live_chat_messages
  // row server-side per unit sent, landing on whichever stream the
  // RECEIVING side actually belongs to. For a self-gift (or a battle gift
  // to my own side), that's this screen's own widget.stream.id, so it
  // arrives back through the existing chat Realtime subscription for free
  // — no local echo needed there. A battle gift to the OPPONENT's side
  // lands on THEIR stream instead, which this screen never subscribes to,
  // so that one case still needs a local line or the sender would see
  // nothing at all.
  Future<void> _onGift(Gift g, {int quantity = 1}) async {
    final battle = _battle;
    if (battle == null || !battle.isLive) {
      // No live battle — same self-gift behavior this screen always had.
      try {
        for (var i = 0; i < quantity; i++) {
          await context.read<WalletController>().sendGift(
            g,
            widget.stream.host,
            liveStreamId: widget.stream.id,
          );
        }
        if (!mounted) return;
        _playGiftBurst(g.id, true);
      } catch (e) {
        if (mounted) _toast(friendlyError(e));
      }
      return;
    }

    final mySide = battle.sideFor(widget.stream.id)!;
    final oppName = _opponentUser?.name ?? 'Opponent';
    var pickedIndex = 0; // 0 = me, 1 = opponent
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: AppColors.bgElevated,
          title: const Text('Send to'),
          content: SegmentedTabs(
            tabs: ['Me', oppName],
            index: pickedIndex,
            onChanged: (i) => setDialogState(() => pickedIndex = i),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Send'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    final side = pickedIndex == 0 ? mySide : (mySide == 'a' ? 'b' : 'a');
    try {
      for (var i = 0; i < quantity; i++) {
        await _pkRepo.sendGift(battle.id, side, g);
      }
      if (mounted && side != mySide) {
        final label = quantity > 1
            ? 'sent ${quantity}x ${g.name} ${g.emoji}'
            : 'sent ${g.name} ${g.emoji}';
        setState(() {
          _chat.add(LiveChatLine(widget.stream.host, label, gift: true));
        });
      }
    } catch (e) {
      if (mounted) _toast(friendlyError(e));
    }
  }

  Future<void> _toggleMic() async {
    setState(() => _micMuted = !_micMuted);
    try {
      await _engine?.muteLocalAudioStream(_micMuted);
    } catch (_) {}
  }

  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'PK Battle Settings',
                style: TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: Icon(
                  Icons.wallpaper_rounded,
                  color: AppColors.primaryBright,
                ),
                title: const Text('Change my arena wallpaper'),
                trailing: const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textMuted,
                ),
                onTap: () {
                  Navigator.pop(context);
                  _pickWallpaper();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickWallpaper() async {
    final auth = context.read<AuthController>();
    final current = auth.user?.pkWallpaper;
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Choose your wallpaper',
                style: TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 16),
              GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                children: [
                  for (final (i, colors) in AppColors.tints.indexed)
                    GestureDetector(
                      onTap: () => Navigator.pop(context, i),
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: colors),
                          borderRadius: BorderRadius.circular(14),
                          border: current == i
                              ? Border.all(color: Colors.white, width: 3)
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await auth.updateProfile(pkWallpaper: picked);
      // widget.stream.host is a separate AppUser instance from
      // AuthController's own copy (constructed from a different query), so
      // PkArena's hostA won't pick up the change on its own — mutate it
      // directly (AppUser's fields are deliberately non-final for this).
      if (mounted) setState(() => widget.stream.host.pkWallpaper = picked);
    } catch (e) {
      if (mounted) _toast(friendlyError(e));
    }
  }

  Future<void> _end() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('End PK battle?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('End', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (leave != true || !mounted) return;
    final battle = _battle;
    if (battle != null && !battle.isTerminal) {
      try {
        if (battle.isLive) {
          await _pkRepo.finalizeNow(battle.id);
        } else {
          await _pkRepo.cancel(battle.id);
        }
      } catch (_) {
        /* ending the stream matters more than tidy cleanup */
      }
    }
    if (!mounted) return;
    try {
      await context.read<LiveStreamsController>().endStream(widget.stream.id);
    } catch (_) {}
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    WakelockPlus.disable().catchError((_) {});
    _heartbeat?.cancel();
    _clockTicker?.cancel();
    _input.dispose();
    _burstCtl.dispose();
    _chatChannel?.unsubscribe();
    _viewerChannel?.unsubscribe();
    _mySeatsChannel?.unsubscribe();
    _seatRequestsChannel?.unsubscribe();
    _inviteChannel?.unsubscribe();
    _battleChannel?.unsubscribe();
    AgoraService.instance.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final battle = _battle;
    final mySide = battle?.sideFor(widget.stream.id);
    final displayScoreA = battle == null
        ? 0
        : (mySide == 'b' ? battle.scoreB : battle.scoreA);
    final displayScoreB = battle == null
        ? 0
        : (mySide == 'b' ? battle.scoreA : battle.scoreB);
    final secondsLeft = battle?.endsAt == null
        ? 0
        : battle!.endsAt!
              .difference(DateTime.now().toUtc())
              .inSeconds
              .clamp(0, 1 << 30);
    final arenaH = MediaQuery.of(context).size.height * 0.42;

    return Scaffold(
      backgroundColor: const Color(0xFF07040F),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                ConnectionBanner(reconnecting: _reconnecting),
                _topBar(),
                const SizedBox(height: 6),
                PkArenaHeader(
                  giftTotal: widget.stream.gifts,
                  statusLabel: _statusLabel,
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: arenaH,
                  child: PkArena(
                    hostA: widget.stream.host,
                    hostB: _opponentUser,
                    seatsPerSide: _seatsPerSide,
                    lockedSeats: _lockedSeats,
                    onSeatTap: (key) => setState(() {
                      if (_lockedSeats.contains(key)) {
                        _lockedSeats.remove(key);
                      } else {
                        _lockedSeats.add(key);
                      }
                    }),
                    onAddSeat: () => setState(() => _seatsPerSide++),
                    bottomBar: _battleActionBar(),
                    occupantsA: _mySeatOccupants,
                    pendingRequestCountA: _pendingSeatRequests.length,
                    onSeatTapA: _onSeatTapA,
                  ),
                ),
                if (battle?.isLive == true)
                  PkScoreBar(
                    scoreA: displayScoreA,
                    scoreB: displayScoreB,
                    secondsLeft: secondsLeft,
                  ),
                const SizedBox(height: 6),
                Expanded(child: _chatFeed()),
                _inputBar(),
              ],
            ),
            if (_giftBurst != null)
              Align(
                alignment: _giftBurstOnSideA
                    ? const Alignment(-0.5, -0.1)
                    : const Alignment(0.5, -0.1),
                child: AnimatedBuilder(
                  animation: _burstCtl,
                  builder: (context, _) {
                    final v = Curves.easeOut.transform(_burstCtl.value);
                    return IgnorePointer(
                      child: Opacity(
                        opacity: (1 - v).clamp(0.0, 1.0),
                        child: Transform.translate(
                          offset: Offset(0, -v * 40),
                          child: Transform.scale(
                            scale: 0.7 + v * 0.5,
                            child: Text(
                              _giftBurst!.emoji,
                              style: const TextStyle(fontSize: 44),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────── top
  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 0),
      child: Row(
        children: [
          AppAvatar(
            name: widget.stream.host.name,
            imageUrl: widget.stream.host.avatarUrl,
            size: 34,
          ),
          const SizedBox(width: 8),
          Text(
            widget.stream.host.name,
            style: const TextStyle(
              fontFamily: 'Poppins',
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: Colors.white,
            ),
          ),
          const Spacer(),
          const _Dot(color: AppColors.live),
          const SizedBox(width: 4),
          const Text(
            'LIVE',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 11,
              color: AppColors.live,
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => showViewerListSheet(context, widget.stream.id),
            child: Row(
              children: [
                const Icon(
                  Icons.graphic_eq_rounded,
                  size: 15,
                  color: Colors.white70,
                ),
                const SizedBox(width: 3),
                Text(
                  '$_viewers',
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _toggleMic,
            child: Icon(
              _micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
              size: 19,
              color: _micMuted ? AppColors.danger : Colors.white70,
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _openSettings,
            child: const Icon(
              Icons.settings_rounded,
              size: 19,
              color: Colors.white70,
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _end,
            child: const Icon(
              Icons.close_rounded,
              size: 22,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  String get _statusLabel => switch (_battle?.status) {
    null => 'Waiting for opponent',
    'invited' => 'Invite sent',
    'accepted' => 'Starting…',
    'live' => 'Live battle',
    _ => 'PK Battle',
  };

  Widget _battleActionBar() {
    final battle = _battle;
    final myId = widget.stream.host.id;

    if (battle == null) {
      return GestureDetector(
        onTap: () async {
          final created = await showPkOpponentPicker(
            context,
            myStreamId: widget.stream.id,
          );
          if (created != null) await _onBattleUpdate(created);
        },
        child: _pillRow(
          'Invite an opponent',
          trailing: Icon(
            Icons.add_rounded,
            color: AppColors.primaryDeep,
            size: 20,
          ),
        ),
      );
    }
    if (battle.status == 'invited' && battle.hostAId == myId) {
      return _pillRow(
        'Waiting for ${_opponentUser?.name ?? '…'}…',
        trailing: GestureDetector(
          onTap: _battleBusy ? null : () => _cancelBattle(battle.id),
          child: const Icon(
            Icons.close_rounded,
            color: Colors.white70,
            size: 20,
          ),
        ),
      );
    }
    if (battle.status == 'invited' && battle.hostBId == myId) {
      return Row(
        children: [
          Expanded(
            child: _actionButton(
              'Decline',
              AppColors.danger,
              () => _respond(battle.id, false),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _actionButton(
              'Accept',
              AppColors.success,
              () => _respond(battle.id, true),
            ),
          ),
        ],
      );
    }
    if (battle.status == 'accepted') {
      return _pillRow('Starting…');
    }
    return const SizedBox.shrink();
  }

  Widget _pillRow(String text, {Widget? trailing}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(26),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13.5),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  Widget _actionButton(String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: _battleBusy ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(26),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 13.5,
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────── chat + input
  Widget _chatFeed() {
    return Stack(
      children: [
        ListView.builder(
          padding: const EdgeInsets.fromLTRB(14, 4, 90, 6),
          itemCount: _chat.length,
          itemBuilder: (context, i) {
            final line = _chat[i];
            final joined = line.text == 'has joined the Chatroom';
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: GestureDetector(
                onTap: isRealId(line.user.id)
                    ? () => AppNav.userProfile(context, line.user)
                    : null,
                child: RichText(
                  text: TextSpan(
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontSize: 11.5,
                    ),
                    children: [
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
                          color: joined
                              ? Colors.white54
                              : (line.gift ? AppColors.gold : Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        Positioned(
          right: 14,
          bottom: 6,
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.event_seat_rounded,
                      color: Color(0xFF1B1140),
                      size: 24,
                    ),
                  ),
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: AppColors.live,
                        shape: BoxShape.circle,
                      ),
                      child: const Text(
                        '9',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              const Text(
                'Join Call',
                style: TextStyle(fontSize: 9, color: Colors.white70),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Matches the other 3 live screens: a "More" tile grid (same shared
  // tool_grid.dart widget) — PK never had one at all before. Gift stays as
  // its own dedicated icon (already in this bar), so it's not duplicated
  // inside the grid, same as the host's own Tools sheet.
  Future<void> _moreActions() async {
    await showToolGridSheet(
      context,
      title: 'More',
      tools: [
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

  Widget _inputBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          GestureDetector(
            onTap: _moreActions,
            child: const Icon(Icons.more_horiz_rounded, color: Colors.white70),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 40),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
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
                  hintText: tr('Say Hi!'),
                  hintStyle: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _send,
            child: const Icon(Icons.send_rounded, color: Colors.white70),
          ),
          const SizedBox(width: 14),
          GestureDetector(
            onTap: _pickGift,
            child: const Icon(
              Icons.card_giftcard_rounded,
              color: AppColors.gold,
            ),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
