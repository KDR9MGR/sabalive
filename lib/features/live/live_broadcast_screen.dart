import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/utils/formatters.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/app_thumb.dart';
import '../../core/widgets/pills.dart';
import '../../data/mock_data.dart';
import '../../data/models.dart';
import '../../theme/app_colors.dart';

/// Host's own broadcast view — reached from Go Live setup. Viewer count and
/// chat tick up on a timer to fake a live room.
class LiveBroadcastScreen extends StatefulWidget {
  const LiveBroadcastScreen({super.key, required this.title, required this.category});
  final String title;
  final String category;

  @override
  State<LiveBroadcastScreen> createState() => _LiveBroadcastScreenState();
}

class _LiveBroadcastScreenState extends State<LiveBroadcastScreen> {
  int _viewers = 3;
  int _gifts = 0;
  final List<LiveChatLine> _chat = [];
  Timer? _timer;
  final _fakeLines = [
    LiveChatLine(Mock.nisha, 'joined 👋'),
    LiveChatLine(Mock.arjun, 'Looking good! 🔥'),
    LiveChatLine(Mock.rocky, 'sent Rose', gift: true),
    LiveChatLine(Mock.sweetheart, 'Hi from Pune!'),
    LiveChatLine(Mock.dreamGirl, 'sent Diamond', gift: true),
    LiveChatLine(Mock.lovelyAngel, 'love the vibe 💜'),
  ];
  int _cursor = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 1400), (_) {
      if (!mounted) return;
      setState(() {
        _viewers += 1 + (_viewers ~/ 20);
        final line = _fakeLines[_cursor % _fakeLines.length];
        _chat.add(line);
        if (line.gift) _gifts++;
        _cursor++;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _end() async {
    _timer?.cancel();
    final leave = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('End live stream?'),
        content: Text(
            'You streamed to $_viewers viewers and received $_gifts gifts.'),
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
    if (leave == true && mounted) {
      Navigator.pop(context);
    } else {
      _timer = Timer.periodic(const Duration(milliseconds: 1400), (_) {
        if (mounted) setState(() => _viewers++);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          AppThumb(seed: 'my-broadcast', borderRadius: 0, overlayOpacity: 0.05),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AppAvatar(name: Mock.me.name, size: 30),
                            const SizedBox(width: 8),
                            const Text('You',
                                style: TextStyle(
                                    fontFamily: 'Poppins',
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                    color: Colors.white)),
                            const SizedBox(width: 8),
                            const LiveBadge(dense: true),
                          ],
                        ),
                      ),
                      const Spacer(),
                      CountChip(
                          icon: Icons.visibility_rounded,
                          label: compactCount(_viewers)),
                      const SizedBox(width: 6),
                      CountChip(
                          icon: Icons.card_giftcard_rounded,
                          label: '$_gifts',
                          color: AppColors.gold),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: _end,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            gradient: AppColors.liveGradient,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text('End',
                              style: TextStyle(
                                  fontFamily: 'Poppins',
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                  color: Colors.white)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text('${widget.title} · ${widget.category}',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 11.5)),
                    ),
                  ),
                ),
                const Spacer(),
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  padding: const EdgeInsets.only(left: 14, right: 60),
                  child: ListView.builder(
                    reverse: true,
                    padding: EdgeInsets.zero,
                    itemCount: _chat.length,
                    itemBuilder: (context, i) {
                      final line = _chat[_chat.length - 1 - i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.32),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: RichText(
                            text: TextSpan(
                              style: const TextStyle(
                                  fontFamily: 'Poppins', fontSize: 11.5),
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
                                      color: line.gift
                                          ? AppColors.gold
                                          : Colors.white),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: EdgeInsets.only(
                      bottom: MediaQuery.of(context).padding.bottom + 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _tool(Icons.cameraswitch_rounded, 'Flip'),
                      _tool(Icons.auto_awesome_rounded, 'Beauty'),
                      _tool(Icons.mic_rounded, 'Mic'),
                      _tool(Icons.group_add_rounded, 'Guests'),
                      _tool(Icons.bolt_rounded, 'PK'),
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

  Widget _tool(IconData icon, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.35),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 10)),
      ],
    );
  }
}
