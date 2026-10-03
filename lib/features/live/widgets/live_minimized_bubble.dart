import 'package:flutter/material.dart';

import '../../../core/widgets/app_avatar.dart';
import '../../../data/models.dart';
import '../../../theme/app_colors.dart';

/// The floating draggable "you're still live" bubble shown when a broadcast
/// is minimized. Deliberately tiny and self-contained — everything outside
/// its own bounds must stay hit-test-transparent so the app underneath
/// (rendered by the same, now non-opaque, route's Navigator) stays usable.
class LiveMinimizedBubble extends StatefulWidget {
  const LiveMinimizedBubble({
    super.key,
    required this.host,
    required this.onTap,
    required this.onClose,
  });

  final AppUser host;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  State<LiveMinimizedBubble> createState() => _LiveMinimizedBubbleState();
}

class _LiveMinimizedBubbleState extends State<LiveMinimizedBubble> {
  Offset? _pos;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final pos = _pos ?? Offset(size.width - 88, size.height * 0.5);
    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: GestureDetector(
        onTap: widget.onTap,
        onPanUpdate: (d) => setState(() {
          _pos = Offset(
            (pos.dx + d.delta.dx).clamp(8.0, size.width - 76),
            (pos.dy + d.delta.dy).clamp(40.0, size.height - 120),
          );
        }),
        child: Container(
          width: 68,
          height: 68,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: AppColors.liveGradient,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              ClipOval(
                child: AppAvatar(
                  name: widget.host.name,
                  imageUrl: widget.host.avatarUrl,
                  frameUrl: widget.host.frameUrl,
                  size: 62,
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 4,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'LIVE',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              Positioned(
                right: -4,
                top: -4,
                child: GestureDetector(
                  onTap: widget.onClose,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: const BoxDecoration(
                      color: AppColors.bgElevated,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      size: 13,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
