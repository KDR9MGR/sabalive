import 'dart:async';

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
import '../../data/models.dart';
import '../../data/pk_battles_repository.dart';
import '../../router/app_nav.dart';
import '../../services/agora_service.dart';
import '../../state/live_streams_controller.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';
import 'widgets/gift_tray.dart';
import 'widgets/pk_arena.dart';
import 'widgets/pk_opponent_picker_sheet.dart';
import 'widgets/pk_score_bar.dart';

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

class _PkBattleScreenState extends State<PkBattleScreen> {
  final _pkRepo = PkBattlesRepository();

  RtcEngine? _engine;
  RealtimeChannel? _chatChannel;
  RealtimeChannel? _viewerChannel;
  int _viewers = 0;
  bool _reconnecting = false;

  final List<LiveChatLine> _chat = [
    LiveChatLine(
      AppUser(id: 'sys1', name: 'TDP, SREENIV', username: '@u'),
      'has joined the Chatroom',
    ),
    LiveChatLine(
      AppUser(id: 'sys2', name: 'Neha khan 78', username: '@u'),
      'has joined the Chatroom',
    ),
  ];
  final _input = TextEditingController();

  // seat chrome stays host-local/decorative — unrelated to the real battle
  int _seatsPerSide = 2;
  final Set<String> _lockedSeats = {}; // keys like 'L1', 'R2'

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
    _join();
    _subscribeChat();
    _subscribeViewerCount();
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

  // ─────────────────────────────────────── real PK battle state machine

  Future<void> _loadBattle() async {
    final battle = await _pkRepo.currentBattleFor(widget.stream.id);
    if (battle != null) await _onBattleUpdate(battle);
  }

  Future<void> _onBattleUpdate(PkBattleInfo battle) async {
    if (!mounted) return;
    final wasId = _battle?.id;
    final prevStatus = _battle?.status;
    setState(() => _battle = battle);

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
    final prof = senderId == null
        ? null
        : await supabase
              .from('profiles')
              .select()
              .eq('id', senderId)
              .maybeSingle();
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
    setState(() => _chat.add(LiveChatLine(widget.stream.host, text)));
    try {
      await supabase.from('live_chat_messages').insert({
        'live_stream_id': widget.stream.id,
        'sender_id': supabase.auth.currentUser?.id,
        'body': text,
        'kind': 'text',
      });
    } catch (_) {}
  }

  Future<void> _onGift(Gift g) async {
    final battle = _battle;
    if (battle == null || !battle.isLive) {
      // No live battle — same self-gift behavior this screen always had.
      try {
        await context.read<WalletController>().sendGift(
          g,
          widget.stream.host,
          liveStreamId: widget.stream.id,
        );
        if (!mounted) return;
        setState(() {
          _chat.add(
            LiveChatLine(
              widget.stream.host,
              'sent ${g.name} ${g.emoji}',
              gift: true,
            ),
          );
        });
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
      await _pkRepo.sendGift(battle.id, side, g);
      if (mounted) {
        setState(() {
          _chat.add(
            LiveChatLine(
              widget.stream.host,
              'sent ${g.name} ${g.emoji}',
              gift: true,
            ),
          );
        });
      }
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
    _heartbeat?.cancel();
    _clockTicker?.cancel();
    _input.dispose();
    _chatChannel?.unsubscribe();
    _viewerChannel?.unsubscribe();
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
        child: Column(
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
            GiftTray(onSelect: _onGift),
            _inputBar(),
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
          AppAvatar(name: widget.stream.host.name, size: 34),
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
          const Icon(Icons.graphic_eq_rounded, size: 15, color: Colors.white70),
          const SizedBox(width: 3),
          Text(
            '$_viewers',
            style: const TextStyle(fontSize: 12, color: Colors.white),
          ),
          const SizedBox(width: 10),
          const Icon(Icons.settings_rounded, size: 19, color: Colors.white70),
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
          trailing: const Icon(
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

  Widget _inputBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(22),
              ),
              child: TextField(
                controller: _input,
                style: const TextStyle(fontSize: 13, color: Colors.white),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Say Hi!',
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
          const Icon(Icons.card_giftcard_rounded, color: AppColors.gold),
          const SizedBox(width: 14),
          const Icon(Icons.favorite_rounded, color: AppColors.magenta),
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
