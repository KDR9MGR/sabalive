import 'dart:async';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/supabase_client.dart';
import '../../core/utils/errors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/connection_banner.dart';
import '../../data/models.dart';
import '../../services/agora_service.dart';
import '../../state/live_streams_controller.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';
import 'widgets/gift_tray.dart';

/// Host-side PK battle room. Your side (audio) + room chat + gift tray are
/// real; the opponent and the tug-of-war score are a local practice battle
/// until live matchmaking (`pk_battles`) is wired.
class PkBattleScreen extends StatefulWidget {
  const PkBattleScreen({super.key, required this.stream, required this.token});
  final LiveStream stream;
  final AgoraToken token;

  @override
  State<PkBattleScreen> createState() => _PkBattleScreenState();
}

class _PkBattleScreenState extends State<PkBattleScreen> {
  RealtimeChannel? _chatChannel;
  int _viewers = 0;
  bool _reconnecting = false;

  final List<LiveChatLine> _chat = [
    LiveChatLine(AppUser(id: 'sys1', name: 'TDP, SREENIV', username: '@u'),
        'has joined the Chatroom'),
    LiveChatLine(AppUser(id: 'sys2', name: 'Neha khan 78', username: '@u'),
        'has joined the Chatroom'),
  ];
  final _input = TextEditingController();

  // practice battle state
  final _opponent = AppUser(id: 'demo-opp', name: 'Challenger', username: '@vs');
  int _scoreA = 0;
  int _seatsPerSide = 2; // host-adjustable, local for the alpha
  final Set<String> _lockedSeats = {}; // keys like 'L1', 'R2'
  int _scoreB = 0;
  Duration _left = const Duration(minutes: 3);
  Timer? _timer;
  Timer? _oppTrickle;
  Timer? _heartbeat;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _join();
    _subscribeChat();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _left -= const Duration(seconds: 1);
        if (_left <= Duration.zero && !_finished) {
          _left = Duration.zero;
          _finished = true;
          _showResult();
        }
      });
    });
    // opponent gets the occasional gift so the bar actually moves
    _oppTrickle = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && !_finished) setState(() => _scoreB += 10 + (_scoreA ~/ 20));
    });
    // Keeps the underlying stream row from being auto-ended as stale.
    final liveStreams = context.read<LiveStreamsController>();
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      liveStreams.heartbeat(widget.stream.id);
    });
  }

  Future<void> _join() async {
    try {
      final engine = await AgoraService.instance.ensureEngine();
      engine.registerEventHandler(RtcEngineEventHandler(
        onUserJoined: (c, uid, e) {
          if (mounted) setState(() => _viewers++);
        },
        onUserOffline: (c, uid, r) {
          if (mounted) setState(() => _viewers = (_viewers - 1).clamp(0, 1 << 30));
        },
        onError: (err, msg) {},
        onConnectionStateChanged: (connection, state, reason) {
          if (mounted) {
            setState(() =>
                _reconnecting = state == ConnectionStateType.connectionStateReconnecting);
          }
        },
      ));
      AgoraService.instance.registerAutoTokenRenewal(engine,
          channelName: widget.token.channelName, asBroadcaster: true);
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
    } catch (e) {
      if (mounted) _toast(friendlyError(e));
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));

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

  Future<void> _appendRow(Map<String, dynamic> row) async {
    final senderId = row['sender_id'] as String?;
    final prof = senderId == null
        ? null
        : await supabase.from('profiles').select().eq('id', senderId).maybeSingle();
    final sender = prof != null
        ? AppUser.fromRow(prof)
        : AppUser(id: senderId ?? 'x', name: 'Someone', username: '@u');
    final isGift = row['kind'] == 'gift';
    if (!mounted) return;
    setState(() {
      _chat.add(LiveChatLine(sender, row['body'] as String? ?? '', gift: isGift));
      if (isGift) _scoreA += 20; // gifts in the room back the host
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
    // Self-gift: really moves coins→diamonds via send_gift and backs your side.
    try {
      await context
          .read<WalletController>()
          .sendGift(g, widget.stream.host, liveStreamId: widget.stream.id);
      if (!mounted) return;
      setState(() {
        _scoreA += g.price;
        _chat.add(LiveChatLine(
            widget.stream.host, 'sent ${g.name} ${g.emoji}', gift: true));
      });
    } catch (e) {
      if (mounted) _toast(friendlyError(e));
    }
  }

  Future<void> _showResult() async {
    final youWin = _scoreA > _scoreB;
    final draw = _scoreA == _scoreB;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: Text(draw ? 'Draw!' : (youWin ? 'You win! 🏆' : 'You lost')),
        content: Text(
            'Final score  ${compactCount(_scoreA)}  vs  ${compactCount(_scoreB)}'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _scoreA = 0;
                _scoreB = 0;
                _left = const Duration(minutes: 3);
                _finished = false;
              });
            },
            child: const Text('Rematch'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
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
              child: const Text('Stay')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('End', style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (leave != true || !mounted) return;
    try {
      await context.read<LiveStreamsController>().endStream(widget.stream.id);
    } catch (_) {}
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _oppTrickle?.cancel();
    _heartbeat?.cancel();
    _input.dispose();
    _chatChannel?.unsubscribe();
    AgoraService.instance.release();
    super.dispose();
  }

  String get _clock {
    final m = _left.inMinutes.toString().padLeft(2, '0');
    final s = (_left.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final total = (_scoreA + _scoreB).clamp(1, 1 << 30);
    final ratioA = _scoreA / total;
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
            _subRow(),
            const SizedBox(height: 8),
            SizedBox(
              height: arenaH,
              child: _arena(),
            ),
            _tugBar(ratioA),
            const SizedBox(height: 8),
            _scoreRow(),
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
          Text(widget.stream.host.name,
              style: const TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: Colors.white)),
          const Spacer(),
          const _Dot(color: AppColors.live),
          const SizedBox(width: 4),
          const Text('LIVE',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                  color: AppColors.live)),
          const SizedBox(width: 8),
          const Icon(Icons.graphic_eq_rounded, size: 15, color: Colors.white70),
          const SizedBox(width: 3),
          Text('$_viewers',
              style: const TextStyle(fontSize: 12, color: Colors.white)),
          const SizedBox(width: 10),
          const Icon(Icons.settings_rounded, size: 19, color: Colors.white70),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _end,
            child: const Icon(Icons.close_rounded, size: 22, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _subRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Text('🎁', style: TextStyle(fontSize: 12)),
              SizedBox(width: 4),
              Text('0',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.white)),
            ]),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Text('Practice PK',
                  style: TextStyle(fontSize: 10, color: Colors.white70)),
              SizedBox(width: 3),
              Icon(Icons.chevron_right_rounded, size: 14, color: Colors.white70),
            ]),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────── arena
  Widget _arena() {
    return Stack(
      children: [
        Row(
          children: [
            Expanded(child: _corner(true)),
            Expanded(child: _corner(false)),
          ],
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 8,
          child: GestureDetector(
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('Live opponent matchmaking — coming soon')),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(26),
              ),
              child: Row(
                children: [
                  Text(_opponent.name,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13.5)),
                  const Spacer(),
                  Container(
                    width: 30,
                    height: 30,
                    decoration: const BoxDecoration(
                        color: Colors.white, shape: BoxShape.circle),
                    child: const Icon(Icons.add_rounded,
                        color: AppColors.primaryDeep, size: 20),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _corner(bool left) {
    final user = left ? widget.stream.host : _opponent;
    final glow = left ? AppColors.live : AppColors.diamond;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: left
              ? [const Color(0xFFB1122B), const Color(0xFF3A0A16)]
              : [const Color(0xFF11489B), const Color(0xFF0A1B3A)],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: glow, width: 3),
              boxShadow: [BoxShadow(color: glow.withValues(alpha: 0.6), blurRadius: 18)],
            ),
            child: AppAvatar(name: user.name, size: 72),
          ),
          const SizedBox(height: 6),
          Text(user.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: Colors.white)),
          const SizedBox(height: 14),
          Wrap(
            spacing: 14,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (var i = 1; i <= _seatsPerSide; i++)
                _seat(left ? 'L$i' : 'R$i', 'No. $i'),
              if (_seatsPerSide < 4)
                GestureDetector(
                  onTap: () => setState(() => _seatsPerSide++),
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                    child: const Icon(Icons.add_rounded,
                        color: Colors.white, size: 20),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _seat(String key, String label) {
    final locked = _lockedSeats.contains(key);
    return GestureDetector(
      onTap: () {
        setState(() {
          if (locked) {
            _lockedSeats.remove(key);
          } else {
            _lockedSeats.add(key);
          }
        });
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.25),
              border: Border.all(color: AppColors.gold.withValues(alpha: 0.7)),
            ),
            child: Icon(
                locked ? Icons.lock_rounded : Icons.event_seat_rounded,
                color: AppColors.gold,
                size: 20),
          ),
          const SizedBox(height: 3),
          Text(locked ? 'Locked' : label,
              style: const TextStyle(fontSize: 9, color: Colors.white70)),
        ],
      ),
    );
  }

  // ─────────────────────────────────────── tug bar + scores
  Widget _tugBar(double ratioA) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      return SizedBox(
        height: 26,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Row(children: [
              Expanded(
                flex: (ratioA * 1000).round().clamp(1, 999),
                child: Container(
                  height: 10,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                        colors: [Color(0xFFFF2D55), Color(0xFFFF7A9C)]),
                  ),
                ),
              ),
              Expanded(
                flex: ((1 - ratioA) * 1000).round().clamp(1, 999),
                child: Container(
                  height: 10,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                        colors: [Color(0xFF9CC6FF), Color(0xFF2D6BFF)]),
                  ),
                ),
              ),
            ]),
            const Positioned(
                left: 4,
                child: Text('🥊', style: TextStyle(fontSize: 18))),
            const Positioned(
                right: 4,
                child: Text('🥊', style: TextStyle(fontSize: 18))),
            Positioned(
              left: (w * ratioA - 9).clamp(0.0, w - 18),
              child: const Icon(Icons.diamond_rounded,
                  color: AppColors.primaryBright, size: 18),
            ),
          ],
        ),
      );
    });
  }

  Widget _scoreRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(child: _scorePanel(_scoreA, AppColors.live)),
          const SizedBox(width: 8),
          Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  gradient: AppColors.goldGradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text('VS',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 11,
                        color: Color(0xFF3A1A5E))),
              ),
              const SizedBox(height: 3),
              Text(_clock,
                  style: const TextStyle(fontSize: 11, color: Colors.white70)),
            ],
          ),
          const SizedBox(width: 8),
          Expanded(child: _scorePanel(_scoreB, AppColors.diamond)),
        ],
      ),
    );
  }

  Widget _scorePanel(int score, Color tint) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          for (final m in const ['🥇', '🥈', '🥉'])
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.08),
                ),
                child: Text(m, style: const TextStyle(fontSize: 11)),
              ),
            ),
          const Spacer(),
          const Icon(Icons.diamond_rounded, size: 12, color: AppColors.diamond),
          const SizedBox(width: 3),
          Text(compactCount(score),
              style: const TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: Colors.white)),
        ],
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
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(fontFamily: 'Poppins', fontSize: 11.5),
                  children: [
                    TextSpan(
                        text: '${line.user.name}  ',
                        style: TextStyle(
                            color: line.gift
                                ? AppColors.gold
                                : AppColors.primaryBright,
                            fontWeight: FontWeight.w600)),
                    TextSpan(
                        text: line.text,
                        style: TextStyle(
                            color: joined
                                ? Colors.white54
                                : (line.gift ? AppColors.gold : Colors.white))),
                  ],
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
                    child: const Icon(Icons.event_seat_rounded,
                        color: Color(0xFF1B1140), size: 24),
                  ),
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                          color: AppColors.live, shape: BoxShape.circle),
                      child: const Text('9',
                          style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              const Text('Join Call',
                  style: TextStyle(fontSize: 9, color: Colors.white70)),
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
      decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}
