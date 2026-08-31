import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/formatters.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/app_thumb.dart';
import '../../core/widgets/pills.dart';
import '../../data/mock_data.dart';
import '../../data/models.dart';
import '../../state/session_controller.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';
import 'widgets/gift_sheet.dart';

class WatchLiveScreen extends StatefulWidget {
  const WatchLiveScreen({super.key, required this.stream});
  final LiveStream stream;

  @override
  State<WatchLiveScreen> createState() => _WatchLiveScreenState();
}

class _WatchLiveScreenState extends State<WatchLiveScreen>
    with TickerProviderStateMixin {
  final _chat = Mock.liveChat();
  final _msgController = TextEditingController();
  final _rand = math.Random();
  final List<_Heart> _hearts = [];
  Gift? _giftBurst;
  int _likes = 0;

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
  }

  @override
  void dispose() {
    _msgController.dispose();
    _burstCtl.dispose();
    super.dispose();
  }

  void _like() {
    setState(() {
      _likes++;
      _hearts.add(_Heart(
        key: UniqueKey(),
        left: 8 + _rand.nextDouble() * 24,
        hue: _rand.nextDouble(),
        onDone: (k) => setState(() => _hearts.removeWhere((h) => h.key == k)),
      ));
    });
    context.read<SessionController>().toggleLike(widget.stream.id);
  }

  void _send() {
    final text = _msgController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _chat.add(LiveChatLine(Mock.me, text));
      _msgController.clear();
    });
  }

  Future<void> _openGifts() async {
    final gift = await showGiftSheet(context, hostName: widget.stream.host.name);
    if (gift == null || !mounted) return;
    final ok = context.read<WalletController>().sendGift(gift, widget.stream.host.name);
    if (!ok) return;
    setState(() {
      _giftBurst = gift;
      _chat.add(LiveChatLine(Mock.me, 'sent ${gift.name}', gift: true));
    });
    _burstCtl.forward(from: 0);
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
          AppThumb(seed: '${widget.stream.id}watch', borderRadius: 0, overlayOpacity: 0.1),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black54, Colors.transparent, Colors.black54, Colors.black87],
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
          // floating hearts
          Positioned(
            right: 6,
            bottom: 140,
            width: 60,
            height: 320,
            child: Stack(children: _hearts),
          ),
          // gift burst
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
                      child: Text(_giftBurst!.emoji,
                          style: const TextStyle(fontSize: 90)),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _topBar(BuildContext context, bool following, SessionController session) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
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
                AppAvatar(name: widget.stream.host.name, size: 32),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.stream.host.name,
                        style: const TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          color: Colors.white,
                        )),
                    Text('${compactCount(widget.stream.viewers)} watching',
                        style: const TextStyle(
                            fontSize: 9.5, color: Colors.white70)),
                  ],
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => session.toggleFollow(widget.stream.host.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      gradient: following ? null : AppColors.primaryGradient,
                      color: following ? Colors.white24 : null,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(following ? 'Following' : 'Follow',
                        style: const TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w600,
                          fontSize: 10.5,
                          color: Colors.white,
                        )),
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
              child: const Icon(Icons.close_rounded,
                  size: 18, color: Colors.white),
            ),
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
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: line.pinned
                    ? AppColors.primary.withValues(alpha: 0.35)
                    : Colors.black.withValues(alpha: 0.32),
                borderRadius: BorderRadius.circular(14),
              ),
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(fontFamily: 'Poppins', fontSize: 11.5),
                  children: [
                    if (line.pinned)
                      const WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: EdgeInsets.only(right: 4),
                          child: Icon(Icons.push_pin_rounded,
                              size: 11, color: Colors.white),
                        ),
                      ),
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
                        color: line.gift ? AppColors.gold : Colors.white,
                        fontWeight: line.gift ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _sideRail() {
    Widget item(IconData icon, String label, VoidCallback onTap,
        {Color? color}) {
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
              Text(label,
                  style: const TextStyle(fontSize: 10, color: Colors.white)),
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
          item(Icons.favorite_rounded, compactCount(_likes), _like,
              color: AppColors.live),
          item(Icons.card_giftcard_rounded, compactCount(widget.stream.gifts),
              _openGifts,
              color: AppColors.gold),
          item(Icons.reply_rounded, 'Share', () {}),
          item(Icons.group_add_rounded, 'Guest', () {}),
        ],
      ),
    );
  }

  Widget _inputBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.32),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.add_rounded, color: Colors.white),
          ),
          const SizedBox(width: 8),
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
              child: const Icon(Icons.favorite_rounded,
                  color: Colors.white, size: 20),
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
