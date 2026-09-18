import 'dart:async';
import 'dart:math' as math;

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/supabase_client.dart';
import '../../core/utils/errors.dart';
import '../../core/utils/ids.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/connection_banner.dart';
import '../../core/widgets/pills.dart';
import '../../data/mock_data.dart';
import '../../data/models.dart';
import '../../data/pk_battles_repository.dart';
import '../../services/agora_service.dart';
import '../../state/auth_controller.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';
import 'widgets/gift_sheet.dart';
import 'widgets/pk_score_bar.dart';

/// Viewer of a PK battle — same proven audience-join + chat/gift chrome as
/// [WatchAudioRoomScreen]/[WatchLiveScreen], with a PK-themed shell instead
/// of the seat grid or video canvas.
///
/// `pk_battles` (see [PkBattlesRepository]) is the single real source of
/// truth for the opponent, score, and timer — this screen subscribes to the
/// same row both hosts do, it never simulates or mirrors a broadcast. Before
/// a battle is matched, or once one ends, it shows a real "waiting"/"ended"
/// state rather than a fake number.
class WatchPkBattleScreen extends StatefulWidget {
  const WatchPkBattleScreen({super.key, required this.stream});
  final LiveStream stream;

  @override
  State<WatchPkBattleScreen> createState() => _WatchPkBattleScreenState();
}

class _WatchPkBattleScreenState extends State<WatchPkBattleScreen>
    with TickerProviderStateMixin {
  late final bool _isReal = isRealId(widget.stream.id);
  final _pkRepo = PkBattlesRepository();
  final List<LiveChatLine> _chat = [];
  final _msgController = TextEditingController();
  Gift? _giftBurst;

  RtcEngine? _engine;
  int? _remoteUid;
  RealtimeChannel? _chatChannel;
  String? _joinError;
  bool _reconnecting = false;
  Timer? _waitTimer;
  bool _waitingTooLong = false;

  PkBattleInfo? _battle;
  AppUser? _opponentUser;
  RealtimeChannel? _discoveryChannel;
  RealtimeChannel? _battleChannel;
  Timer? _clockTicker;
  String? _agoraChannelTarget;

  late final AnimationController _burstCtl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    _burstCtl.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _giftBurst = null);
      }
    });
    if (_isReal) {
      _joinReal();
      _loadRealChat();
      _logViewerJoin();
      _loadBattle();
      _clockTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _battle?.isLive == true) setState(() {});
      });
    } else {
      _chat.addAll(Mock.liveChat());
    }
  }

  // ─────────────────────────────────────── real PK battle state machine

  Future<void> _loadBattle() async {
    final battle = await _pkRepo.currentBattleFor(widget.stream.id);
    if (battle != null) {
      await _onBattleUpdate(battle);
    } else {
      _discoveryChannel = _pkRepo.subscribeDiscovery(widget.stream.id, _onBattleUpdate);
    }
  }

  Future<void> _onBattleUpdate(PkBattleInfo battle) async {
    if (!mounted) return;
    final wasId = _battle?.id;
    setState(() => _battle = battle);

    if (wasId != battle.id) {
      _discoveryChannel?.unsubscribe();
      _discoveryChannel = null;
      _battleChannel?.unsubscribe();
      _battleChannel = _pkRepo.subscribeBattle(battle.id, _onBattleUpdate);
    }

    if (_opponentUser == null || wasId != battle.id) {
      final opponentId =
          battle.hostAId == widget.stream.host.id ? battle.hostBId : battle.hostAId;
      final profile = await _pkRepo.profile(opponentId);
      if (mounted) setState(() => _opponentUser = profile);
    }

    await _syncAgoraChannel(battle);
  }

  /// Jittered so a large audience doesn't all leave+rejoin Agora in the
  /// same instant when a battle starts or ends.
  Future<void> _syncAgoraChannel(PkBattleInfo battle) async {
    final engine = _engine;
    if (engine == null) return;
    final target = battle.isLive ? battle.agoraChannel : widget.stream.id;
    if (_agoraChannelTarget == target) return;
    _agoraChannelTarget = target;
    await Future.delayed(Duration(milliseconds: math.Random().nextInt(1500)));
    if (!mounted || _agoraChannelTarget != target) return;
    try {
      await AgoraService.instance
          .switchChannel(engine, newChannelName: target, asBroadcaster: false);
    } catch (_) {
      // Best-effort — connection state / join errors already surface via
      // the registered event handlers.
    }
  }

  Future<void> _logViewerJoin() async {
    try {
      await supabase.rpc('join_live_stream', params: {'p_stream_id': widget.stream.id});
    } catch (_) {/* best-effort — a missed count beats a broken screen */}
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
      _agoraChannelTarget = widget.stream.id;
      _waitTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && _remoteUid == null) setState(() => _waitingTooLong = true);
      });
      if (mounted) setState(() {});
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
        AppUser(id: row['sender_id'] as String, name: 'Someone', username: '@user');
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
    _clockTicker?.cancel();
    _msgController.dispose();
    _burstCtl.dispose();
    _chatChannel?.unsubscribe();
    _discoveryChannel?.unsubscribe();
    _battleChannel?.unsubscribe();
    if (_isReal) {
      AgoraService.instance.release();
      unawaited(
        supabase.rpc('leave_live_stream', params: {'p_stream_id': widget.stream.id}),
      );
    }
    super.dispose();
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
      return;
    }
    final me = context.read<AuthController>().user ?? Mock.me;
    setState(() => _chat.add(LiveChatLine(me, text)));
  }

  Future<void> _openGifts() async {
    final battle = _battle;
    if (battle != null && battle.isLive) {
      await _openBattleGift(battle);
      return;
    }
    final gift = await showGiftSheet(context, hostName: widget.stream.host.name);
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      return;
    }
    if (!mounted) return;
    setState(() {
      _giftBurst = gift;
      if (!_isReal) _chat.add(LiveChatLine(me, 'sent ${gift.name}', gift: true));
    });
    _burstCtl.forward(from: 0);
  }

  Future<void> _openBattleGift(PkBattleInfo battle) async {
    final gift = await showGiftSheet(context, hostName: widget.stream.host.name);
    if (gift == null || !mounted) return;

    final hostSide = battle.sideFor(widget.stream.id)!;
    final oppName = _opponentUser?.name ?? 'Opponent';
    var pickedIndex = 0; // 0 = this stream's host, 1 = the opponent
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: AppColors.bgElevated,
          title: const Text('Send to'),
          content: SegmentedTabs(
            tabs: [widget.stream.host.name, oppName],
            index: pickedIndex,
            onChanged: (i) => setDialogState(() => pickedIndex = i),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Send')),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final side = pickedIndex == 0 ? hostSide : (hostSide == 'a' ? 'b' : 'a');
    try {
      await _pkRepo.sendGift(battle.id, side, gift);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      return;
    }
    if (!mounted) return;
    setState(() => _giftBurst = gift);
    _burstCtl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF07040F),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                ConnectionBanner(reconnecting: _reconnecting),
                _topBar(context),
                const SizedBox(height: 8),
                Expanded(child: _arenaShell()),
                Expanded(child: _chatFeed()),
                GiftTrayButton(onTap: _openGifts),
                _inputBar(),
              ],
            ),
            if (_giftBurst != null)
              Center(
                child: AnimatedBuilder(
                  animation: _burstCtl,
                  builder: (context, _) {
                    final v = Curves.easeOut.transform(_burstCtl.value);
                    return IgnorePointer(
                      child: Opacity(
                        opacity: (1 - v).clamp(0.0, 1.0),
                        child: Transform.scale(
                          scale: 0.6 + v * 1.8,
                          child: Text(_giftBurst!.emoji,
                              style: const TextStyle(fontSize: 90)),
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

  Widget _topBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 12, 0),
      child: Row(
        children: [
          const Icon(Icons.bolt_rounded, color: AppColors.gold, size: 18),
          const SizedBox(width: 6),
          const Text('PK Battle',
              style: TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: Colors.white)),
          const Spacer(),
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close_rounded, size: 18, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _arenaShell() {
    final battle = _battle;
    final mySide = battle?.sideFor(widget.stream.id);
    final displayScoreA =
        battle == null ? 0 : (mySide == 'b' ? battle.scoreB : battle.scoreA);
    final displayScoreB =
        battle == null ? 0 : (mySide == 'b' ? battle.scoreA : battle.scoreB);
    final secondsLeft = battle?.endsAt == null
        ? 0
        : battle!.endsAt!.difference(DateTime.now().toUtc()).inSeconds.clamp(0, 1 << 30);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _cornerAvatar(widget.stream.host.name, AppColors.live),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    gradient: AppColors.goldGradient,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('VS',
                      style: TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                          color: Color(0xFF3A1A5E))),
                ),
              ),
              _cornerAvatar(_opponentUser?.name ?? 'Waiting…', AppColors.diamond,
                  dimmed: _opponentUser == null),
            ],
          ),
          const SizedBox(height: 14),
          if (_joinError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_joinError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
            )
          else if (_waitingTooLong)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                "Still nothing from the host — they may have ended, "
                "or there's a connection issue.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 12.5),
              ),
            )
          else if (_isReal && _remoteUid == null)
            const CircularProgressIndicator(color: AppColors.primaryBright)
          else if (_isReal && battle == null)
            const Text('No opponent yet — solo PK',
                style: TextStyle(color: Colors.white54, fontSize: 11.5))
          else if (_isReal && !battle!.isLive && !battle.isTerminal)
            const Text('An opponent has been found — starting soon',
                style: TextStyle(color: Colors.white54, fontSize: 11.5))
          else if (_isReal)
            const Text("You're watching live — audio is playing",
                style: TextStyle(color: Colors.white54, fontSize: 11.5)),
          if (battle?.isLive == true) ...[
            const SizedBox(height: 16),
            PkScoreBar(
                scoreA: displayScoreA, scoreB: displayScoreB, secondsLeft: secondsLeft),
          ],
        ],
      ),
    );
  }

  Widget _cornerAvatar(String name, Color tint, {bool dimmed = false}) {
    return Opacity(
      opacity: dimmed ? 0.45 : 1,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: tint, width: 2)),
            child: AppAvatar(name: name, size: 64),
          ),
          const SizedBox(height: 6),
          Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                  color: Colors.white)),
        ],
      ),
    );
  }

  Widget _chatFeed() {
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _chat.length,
      itemBuilder: (context, i) {
        final line = _chat[_chat.length - 1 - i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: RichText(
            text: TextSpan(
              style: const TextStyle(fontFamily: 'Poppins', fontSize: 12.5),
              children: [
                TextSpan(
                  text: '${line.user.name}  ',
                  style: TextStyle(
                    color: line.gift ? AppColors.gold : AppColors.primaryBright,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                TextSpan(
                  text: line.text,
                  style: TextStyle(
                    color: line.gift ? AppColors.gold : Colors.white70,
                    fontWeight: line.gift ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _inputBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
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
                        hintText: 'Cheer them on…',
                        hintStyle: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  GestureDetector(
                    onTap: _send,
                    child: const Icon(Icons.send_rounded,
                        color: AppColors.primaryBright, size: 20),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Thin gift-tray entry point matching this screen's chrome — the full
/// gift-selection UI is [showGiftSheet], same as every other watch screen.
class GiftTrayButton extends StatelessWidget {
  const GiftTrayButton({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: AppColors.goldGradient,
            borderRadius: BorderRadius.circular(21),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.card_giftcard_rounded, size: 18, color: Color(0xFF3A1A5E)),
              SizedBox(width: 6),
              Text('Send a gift',
                  style: TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: Color(0xFF3A1A5E))),
            ],
          ),
        ),
      ),
    );
  }
}
