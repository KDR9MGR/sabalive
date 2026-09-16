import 'dart:async';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/supabase_client.dart';
import '../../core/utils/errors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/connection_banner.dart';
import '../../data/models.dart';
import '../../router/app_nav.dart';
import '../../services/agora_service.dart';
import '../../state/live_streams_controller.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';
import '../messages/messages_screen.dart';
import 'widgets/gift_sheet.dart';
import 'widgets/gift_tray.dart';

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

class _LiveBroadcastScreenState extends State<LiveBroadcastScreen> {
  RtcEngine? _engine;
  int _viewers = 0;
  final List<LiveChatLine> _chat = [];
  RealtimeChannel? _chatChannel;
  RealtimeChannel? _viewerChannel;
  String? _error;
  bool _reconnecting = false;

  final _input = TextEditingController();
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  bool _micMuted = false;
  bool _speakerOn = true;
  bool _beautyOn = false;
  bool _showWarning = true;
  bool _showPip = true;
  Offset _pipPos = const Offset(-1, -1); // resolved on first layout

  // audio-room seat controls (host only, local for the alpha)
  int _seatCount = 8;
  final Set<int> _lockedSeats = {};

  Timer? _heartbeat;

  @override
  void initState() {
    super.initState();
    _join();
    _subscribeChat();
    _subscribeViewerCount();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });
    Future.delayed(const Duration(seconds: 12), () {
      if (mounted) setState(() => _showWarning = false);
    });
    // Keeps the stream row from being auto-ended as stale while this
    // screen is genuinely up and broadcasting.
    final liveStreams = context.read<LiveStreamsController>();
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      liveStreams.heartbeat(widget.stream.id);
    });
  }

  Future<void> _join() async {
    try {
      final engine = await AgoraService.instance.ensureEngine();
      engine.registerEventHandler(RtcEngineEventHandler(
        onError: (err, msg) {
          if (mounted) setState(() => _error = msg);
        },
        onConnectionStateChanged: (connection, state, reason) {
          if (mounted) {
            setState(() =>
                _reconnecting = state == ConnectionStateType.connectionStateReconnecting);
          }
        },
      ));
      AgoraService.instance.registerAutoTokenRenewal(engine,
          channelName: widget.token.channelName, asBroadcaster: true);
      if (widget.audioOnly) {
        await engine.enableLocalVideo(false);
      } else {
        await engine.startPreview();
      }
      await engine.joinChannel(
        token: widget.token.token,
        channelId: widget.token.channelName,
        uid: widget.token.uid,
        options: const ChannelMediaOptions(
          channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
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
            if (mounted && count != null) setState(() => _viewers = count);
          },
        )
        .subscribe();
  }

  Future<void> _appendChatRow(Map<String, dynamic> row) async {
    final senderId = row['sender_id'] as String;
    final profileRow =
        await supabase.from('profiles').select().eq('id', senderId).maybeSingle();
    final sender = profileRow != null
        ? AppUser.fromRow(profileRow)
        : AppUser(id: senderId, name: 'Someone', username: '@user');
    if (!mounted) return;
    setState(() {
      _chat.add(LiveChatLine(sender, row['body'] as String,
          gift: row['kind'] == 'gift', pinned: row['pinned'] as bool? ?? false));
    });
  }

  Future<void> _sendChat() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final me = supabase.auth.currentUser;
    setState(() {
      _chat.add(LiveChatLine(widget.stream.host, text));
    });
    try {
      await supabase.from('live_chat_messages').insert({
        'live_stream_id': widget.stream.id,
        'sender_id': me?.id,
        'body': text,
        'kind': 'text',
      });
    } catch (_) {/* optimistic line already shown */}
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _heartbeat?.cancel();
    _input.dispose();
    _chatChannel?.unsubscribe();
    _viewerChannel?.unsubscribe();
    AgoraService.instance.release();
    super.dispose();
  }

  Future<void> _end() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('End live stream?'),
        content: Text(
            'You streamed for ${_fmt(_elapsed)} to $_viewers viewer${_viewers == 1 ? '' : 's'}.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep going')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('End', style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (leave != true || !mounted) return;
    try {
      await context.read<LiveStreamsController>().endStream(widget.stream.id);
    } catch (_) {/* row may be gone; ending locally matters more */}
    if (mounted) Navigator.pop(context);
  }

  static String _fmt(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String get _hostIdLabel {
    final n = widget.stream.host.id.hashCode.abs() % 900000 + 100000;
    return 'ID: $n';
  }

  void _snack(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));

  void _soon(String what) => _snack('$what — coming soon');

  Future<void> _toggleMic() async {
    setState(() => _micMuted = !_micMuted);
    try {
      await _engine?.muteLocalAudioStream(_micMuted);
    } catch (_) {}
  }

  Future<void> _toggleSpeaker() async {
    setState(() => _speakerOn = !_speakerOn);
    try {
      await _engine?.setEnableSpeakerphone(_speakerOn);
    } catch (_) {}
  }

  // ─────────────────────────────────────────────────────── Tools sheet
  Future<void> _openTools() async {
    final tools = <_ToolSpec>[
      _ToolSpec(Icons.bolt_rounded, 'Invite PK', const Color(0xFFFF7A45),
          () => _soon('PK battles')),
      _ToolSpec(Icons.casino_rounded, 'Random PK', const Color(0xFFFF5C5C),
          () => _soon('PK battles')),
      _ToolSpec(Icons.sports_esports_rounded, 'Games', AppColors.primaryBright,
          () => AppNav.games(context)),
      _ToolSpec(Icons.savings_rounded, 'Coin Bag', AppColors.gold,
          () => AppNav.wallet(context)),
      _ToolSpec(Icons.music_note_rounded, 'Play music', AppColors.pink,
          () => _soon('Music')),
      _ToolSpec(Icons.campaign_rounded, 'Funny voice', AppColors.magenta,
          () => _soon('Voice effects')),
      _ToolSpec(Icons.wallpaper_rounded, 'Room skin', const Color(0xFF2DD4BF),
          () => _soon('Room skins')),
      _ToolSpec(Icons.ios_share_rounded, 'Share', AppColors.diamond, _shareStream),
      _ToolSpec(Icons.inbox_rounded, 'Inbox', const Color(0xFF818CF8), () {
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const MessagesScreen()));
      }),
      _ToolSpec(Icons.settings_voice_rounded, 'Voice Control',
          const Color(0xFF34D399), () {
        _toggleMic();
        _snack(_micMuted ? 'Microphone muted' : 'Microphone on');
      }),
      _ToolSpec(Icons.volume_up_rounded, 'Speaker', AppColors.success, () {
        _toggleSpeaker();
        _snack(_speakerOn ? 'Speaker on' : 'Speaker off');
      }),
      _ToolSpec(Icons.assignment_rounded, 'Notice', AppColors.goldDeep,
          _editNotice),
      _ToolSpec(Icons.speaker_notes_off_rounded, 'Clear chat',
          const Color(0xFFFB923C), () {
        setState(_chat.clear);
        _snack('Chat cleared');
      }),
      _ToolSpec(Icons.block_rounded, 'Block', AppColors.danger,
          () => _soon('Viewer moderation')),
    ];

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Tools',
                  style: TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w700,
                      fontSize: 16)),
              const SizedBox(height: 12),
              const Divider(color: AppColors.stroke, height: 1),
              const SizedBox(height: 16),
              GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 14,
                crossAxisSpacing: 12,
                childAspectRatio: 0.86,
                children: [
                  for (final t in tools)
                    _ToolTile(
                      spec: t,
                      onTap: () {
                        Navigator.pop(context);
                        t.onTap();
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickGift() async {
    final gift = await showGiftSheet(context, hostName: widget.stream.host.name);
    if (gift != null) await _sendGift(gift);
  }

  /// Self-gift — really runs `send_gift` (coins → diamonds, backs your room).
  Future<void> _sendGift(Gift gift) async {
    final wallet = context.read<WalletController>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await wallet.sendGift(gift, widget.stream.host,
          liveStreamId: widget.stream.id);
      if (mounted) {
        setState(() => _chat.add(LiveChatLine(
            widget.stream.host, 'sent ${gift.name} ${gift.emoji}', gift: true)));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  Future<void> _shareStream() async {
    await Clipboard.setData(
        ClipboardData(text: 'https://sabalive.app/live/${widget.stream.id}'));
    if (mounted) _snack('Stream link copied');
  }

  Future<void> _editNotice() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('Room notice'),
        content: TextField(
          controller: controller,
          maxLength: 120,
          maxLines: 2,
          decoration: const InputDecoration(hintText: 'Pin a message for viewers'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Pin')),
        ],
      ),
    );
    if (text != null && text.isNotEmpty && mounted) {
      setState(() => _chat.add(LiveChatLine(
          widget.stream.host, text,
          pinned: true)));
      _snack('Notice pinned');
    }
  }

  Future<void> _seatMenu(int seat) async {
    final locked = _lockedSeats.contains(seat);
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
              child: Text('Seat $seat',
                  style: const TextStyle(
                      fontFamily: 'Poppins', fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: Icon(locked
                  ? Icons.lock_open_rounded
                  : Icons.lock_outline_rounded),
              title: Text(locked ? 'Unlock seat' : 'Lock seat'),
              onTap: () => Navigator.pop(context, 'lock'),
            ),
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
    if (choice == 'lock') {
      setState(() {
        if (locked) {
          _lockedSeats.remove(seat);
        } else {
          _lockedSeats.add(seat);
        }
      });
      _snack('Seat $seat ${locked ? 'unlocked' : 'locked'}');
    } else if (choice == 'invite') {
      _soon('Seat invites');
    }
  }

  Future<void> _openRequests() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Co-host requests',
                  style: TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w700,
                      fontSize: 15)),
              const SizedBox(height: 16),
              Icon(Icons.group_add_rounded,
                  size: 40, color: AppColors.textMuted.withValues(alpha: 0.6)),
              const SizedBox(height: 10),
              const Text('No one has asked to join yet.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12.5)),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────── build
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    if (_pipPos.dx < 0) {
      _pipPos = Offset(size.width - 132, size.height * 0.16);
    }
    final diamonds = context.watch<WalletController>().diamonds;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.audioOnly)
            _SeatRoom(
              host: widget.stream.host,
              error: _error,
              seatCount: _seatCount,
              lockedSeats: _lockedSeats,
              onSeatTap: _seatMenu,
              onAddSeat: _seatCount >= 12
                  ? null
                  : () => setState(() => _seatCount++),
              onRemoveSeat: _seatCount <= 4
                  ? null
                  : () => setState(() {
                        _lockedSeats.remove(_seatCount);
                        _seatCount--;
                      }),
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
                        child: Text(_error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70)),
                      )
                    : const CircularProgressIndicator(
                        color: AppColors.primaryBright),
              ),
            ),

          // subtle top + bottom scrims for legibility
          const _Scrim(),

          if (!widget.audioOnly && _showPip)
            Positioned(
              left: _pipPos.dx,
              top: _pipPos.dy,
              child: GestureDetector(
                onPanUpdate: (d) => setState(() {
                  _pipPos = Offset(
                    (_pipPos.dx + d.delta.dx).clamp(8.0, size.width - 124),
                    (_pipPos.dy + d.delta.dy).clamp(80.0, size.height - 220),
                  );
                }),
                child: _PipCard(onClose: () => setState(() => _showPip = false)),
              ),
            ),

          SafeArea(
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
                      ConnectionBanner(reconnecting: _reconnecting),
                      Row(
                        children: [
                          _hostChip(),
                          const Spacer(),
                          _circle('$_viewers', onTap: _openRequests),
                          const SizedBox(width: 8),
                          _circle(null,
                              icon: Icons.close_rounded,
                              iconColor: AppColors.danger,
                              onTap: _end),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _miniPill(Icons.schedule_rounded, _fmt(_elapsed)),
                          const SizedBox(width: 8),
                          _miniPill(Icons.diamond_rounded, compactCount(diamonds),
                              tint: AppColors.diamond),
                        ],
                      ),
                    ],
                  ),
                ),

                // ── beauty + flip (top-right, below the top bar)
                Positioned(
                  right: 12,
                  top: 58,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      GestureDetector(
                        onTap: () {
                          setState(() => _beautyOn = !_beautyOn);
                          _snack(_beautyOn ? 'Beauty on' : 'Beauty off');
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 7),
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
                                  color: Colors.white),
                              const SizedBox(width: 5),
                              const Text('Beauty',
                                  style: TextStyle(
                                      fontFamily: 'Poppins',
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                      color: Colors.white)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _iconCircle(Icons.cameraswitch_rounded,
                          () => _engine?.switchCamera()),
                    ],
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
                              children: [
                                if (_showWarning) _warningBanner(),
                                if (_chat.isNotEmpty) _chatList(),
                              ],
                            ),
                          ),
                          _rightRail(),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (widget.audioOnly)
                        GiftTray(onSelect: _sendGift),
                      const SizedBox(height: 6),
                      _bottomBar(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _hostChip() {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppAvatar(name: widget.stream.host.name, size: 30),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(widget.stream.host.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: 'Poppins',
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        color: Colors.white)),
              ),
              Text(_hostIdLabel,
                  style: const TextStyle(
                      fontSize: 9.5, color: Colors.white70)),
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
          Text(label,
              style: const TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                  color: Colors.white)),
        ],
      ),
    );
  }

  Widget _circle(String? label,
      {IconData? icon, Color iconColor = Colors.white, VoidCallback? onTap}) {
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
            : Text(label ?? '',
                style: const TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: Colors.white)),
      ),
    );
  }

  Widget _iconCircle(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.42),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }

  Widget _warningBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 8, 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Text(
        'Any sexual or violent content is strictly prohibited — violators are '
        'banned. Do not share personal info such as phone or location.',
        style: TextStyle(
            color: Color(0xFFFF6B6B),
            fontSize: 11,
            height: 1.35,
            fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _chatList() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 190),
      padding: const EdgeInsets.only(left: 14, right: 8),
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
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: line.pinned
                      ? AppColors.primary.withValues(alpha: 0.5)
                      : Colors.black.withValues(alpha: 0.36),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: RichText(
                  text: TextSpan(
                    style: const TextStyle(
                        fontFamily: 'Poppins', fontSize: 11.5),
                    children: [
                      if (line.pinned)
                        const TextSpan(
                            text: '📌 ',
                            style: TextStyle(fontSize: 11)),
                      TextSpan(
                        text: '${line.user.name}  ',
                        style: TextStyle(
                            color: line.gift
                                ? AppColors.gold
                                : AppColors.primaryBright,
                            fontWeight: FontWeight.w600),
                      ),
                      TextSpan(
                          text: line.text,
                          style: TextStyle(
                              color:
                                  line.gift ? AppColors.gold : Colors.white)),
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

  Widget _rightRail() {
    return Padding(
      padding: const EdgeInsets.only(right: 12, bottom: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _iconCircle(
              _micMuted ? Icons.mic_off_rounded : Icons.mic_rounded, _toggleMic),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _openRequests,
            child: Container(
              width: 64,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                gradient: AppColors.primaryGradient,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Column(
                children: [
                  Icon(Icons.person_add_alt_1_rounded,
                      color: Colors.white, size: 20),
                  SizedBox(height: 3),
                  Text('REQUESTS',
                      style: TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w700,
                          fontSize: 8,
                          letterSpacing: 0.3,
                          color: Colors.white)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(
          12, 8, 12, 8 + MediaQuery.of(context).padding.bottom),
      child: Row(
        children: [
          _iconCircle(Icons.more_horiz_rounded, _openTools),
          const SizedBox(width: 8),
          _iconCircle(Icons.emoji_emotions_outlined,
              () => _soon('Emoji picker')),
          const SizedBox(width: 8),
          _iconCircle(Icons.card_giftcard_rounded, _pickGift),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.42),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white24),
              ),
              child: TextField(
                controller: _input,
                style: const TextStyle(fontSize: 13, color: Colors.white),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendChat(),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Say something…',
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
              child: const Icon(Icons.send_rounded,
                  color: Colors.white, size: 19),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────── helper widgets

class _ToolSpec {
  _ToolSpec(this.icon, this.label, this.color, this.onTap);
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.spec, required this.onTap});
  final _ToolSpec spec;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: spec.color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: spec.color.withValues(alpha: 0.35)),
            ),
            child: Icon(spec.icon, color: spec.color, size: 26),
          ),
          const SizedBox(height: 6),
          Text(spec.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5, color: AppColors.textPrimary)),
        ],
      ),
    );
  }
}

/// Voice-room stage: host on top, a ring of empty guest seats below.
class _SeatRoom extends StatelessWidget {
  const _SeatRoom({
    required this.host,
    this.error,
    required this.seatCount,
    required this.lockedSeats,
    required this.onSeatTap,
    this.onAddSeat,
    this.onRemoveSeat,
  });
  final AppUser host;
  final String? error;
  final int seatCount;
  final Set<int> lockedSeats;
  final void Function(int seat) onSeatTap;
  final VoidCallback? onAddSeat;
  final VoidCallback? onRemoveSeat;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1B1140), Color(0xFF0B0716)],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 90, 20, 0),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AppColors.primaryGradient,
                  boxShadow: [
                    BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.5),
                        blurRadius: 26),
                  ],
                ),
                child: AppAvatar(name: host.name, size: 88),
              ),
              const SizedBox(height: 8),
              Text(host.name,
                  style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: Colors.white)),
              const Text('Host',
                  style: TextStyle(fontSize: 10, color: Colors.white60)),
              const SizedBox(height: 24),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70)),
                )
              else ...[
                Wrap(
                  spacing: 18,
                  runSpacing: 18,
                  alignment: WrapAlignment.center,
                  children: [
                    for (var i = 1; i <= seatCount; i++)
                      GestureDetector(
                        onTap: () => onSeatTap(i),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 58,
                              height: 58,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withValues(alpha: 0.06),
                                border: Border.all(
                                    color: lockedSeats.contains(i)
                                        ? AppColors.gold.withValues(alpha: 0.7)
                                        : Colors.white.withValues(alpha: 0.18)),
                              ),
                              child: Icon(
                                  lockedSeats.contains(i)
                                      ? Icons.lock_rounded
                                      : Icons.mic_none_rounded,
                                  color: lockedSeats.contains(i)
                                      ? AppColors.gold
                                      : Colors.white38,
                                  size: 22),
                            ),
                            const SizedBox(height: 4),
                            Text('Seat $i',
                                style: const TextStyle(
                                    fontSize: 9.5, color: Colors.white38)),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _seatBtn(Icons.remove_rounded, 'Remove seat', onRemoveSeat),
                    const SizedBox(width: 12),
                    _seatBtn(Icons.add_rounded, 'Add seat', onAddSeat),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _seatBtn(IconData icon, String label, VoidCallback? onTap) {
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: Colors.white),
            const SizedBox(width: 5),
            Text(label,
                style: const TextStyle(fontSize: 11.5, color: Colors.white)),
          ]),
        ),
      ),
    );
  }
}

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

/// Small draggable "featured live" window, dismissible. Placeholder content —
/// wire to a real co-host / multi-guest feed later.
class _PipCard extends StatelessWidget {
  const _PipCard({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 116,
      height: 168,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF5279B), Color(0xFFF5A623)],
        ),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            left: 6,
            top: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('LIVE',
                  style: TextStyle(
                      fontSize: 7,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ),
          ),
          Positioned(
            right: 4,
            top: 4,
            child: GestureDetector(
              onTap: onClose,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.4),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close_rounded,
                    size: 12, color: Colors.white),
              ),
            ),
          ),
          const Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: Text('Featured live',
                style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
