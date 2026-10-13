import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart' hide Text;

import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/level_star.dart';
import '../../../core/widgets/remote_media.dart';
import '../../../data/models.dart';
import '../../../core/i18n/text.dart';

/// One arrival to announce on screen: who walked in, and the picture the panel set for their level.
class JoinBanner {
  const JoinBanner({required this.imageUrl, required this.name, this.who});

  /// The level's join image from the panel (a picture, SVGA, MP4 or GIF).
  final String imageUrl;
  final String name;

  /// Their avatar, frame and level stars, when the screen knows them.
  final AppUser? who;
}

/// Plays join banners one after another, in a lane of their own: they run beside gifts and entry effects, never in
/// front of them in the queue, so a busy room's arrivals can't delay a gift and a gift can't hold a banner back.
/// Only the last few waiting are kept, and with a few waiting each shows a little shorter, so the strip never falls
/// behind the room.
class JoinBannerController extends ChangeNotifier {
  JoinBannerController({
    this.maxQueued = 4,
    this.hold = const Duration(milliseconds: 5200),
    this.hurryAt = 2,
  });

  final int maxQueued;

  /// How long one banner stays: slides in, holds, slides out.
  final Duration hold;

  /// With this many waiting, banners show for 60% of [hold].
  final int hurryAt;

  final Queue<JoinBanner> _queue = Queue();
  JoinBanner? _current;
  Duration _currentDuration = Duration.zero;
  int _playId = 0;
  Timer? _timer;
  bool _disposed = false;

  JoinBanner? get current => _current;
  int get playId => _playId;

  /// How long the banner on screen now was given.
  Duration get currentDuration => _currentDuration;

  void add(JoinBanner banner) {
    if (_disposed) return;
    _queue.add(banner);
    while (_queue.length > maxQueued) {
      _queue.removeFirst();
    }
    _startNext();
  }

  /// The banner [id] has finished (the view calls this itself; a late call for an earlier banner is ignored).
  void finish(int id) {
    if (_disposed || id != _playId || _current == null) return;
    _timer?.cancel();
    _current = null;
    _startNext();
    notifyListeners();
  }

  void _startNext() {
    if (_current != null || _queue.isEmpty) return;
    final hurry = _queue.length > hurryAt;
    _current = _queue.removeFirst();
    _currentDuration = hurry ? hold * 0.6 : hold;
    _playId++;
    final id = _playId;
    _timer?.cancel();
    // the view finishes it when its slide-out ends; this is only the backstop
    _timer = Timer(_currentDuration + const Duration(seconds: 2), () => finish(id));
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// Draws the banner that [controller] is playing: a strip about a third of the way up from the bottom, with the
/// level's picture behind the person's avatar (in their frame), name, level stars and "joined". It is a strip, never
/// the whole screen, and takes no touches.
class JoinBannerLayer extends StatelessWidget {
  const JoinBannerLayer({super.key, required this.controller});

  final JoinBannerController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final banner = controller.current;
        if (banner == null) return const SizedBox.shrink();
        final id = controller.playId;
        return IgnorePointer(
          child: Align(
            alignment: const Alignment(0, 0.38),
            child: _JoinBannerView(
              key: ValueKey(id),
              banner: banner,
              duration: controller.currentDuration,
              onFinished: () => controller.finish(id),
            ),
          ),
        );
      },
    );
  }
}

class _JoinBannerView extends StatefulWidget {
  const _JoinBannerView({super.key, required this.banner, required this.duration, required this.onFinished});

  final JoinBanner banner;
  final Duration duration;
  final VoidCallback onFinished;

  @override
  State<_JoinBannerView> createState() => _JoinBannerViewState();
}

class _JoinBannerViewState extends State<_JoinBannerView> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.duration)
    ..forward().whenComplete(() {
      if (mounted) widget.onFinished();
    });

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Slides in from the right over the first ~16% (about 0.8 s), holds, slides out to the left over the last ~16%.
  static double _offset(double t) {
    if (t < 0.16) return (1 - Curves.easeOutCubic.transform(t / 0.16));
    if (t > 0.84) return -Curves.easeInCubic.transform((t - 0.84) / 0.16);
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.banner;
    final width = MediaQuery.sizeOf(context).width;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => Transform.translate(offset: Offset(_offset(_c.value) * width, 0), child: child),
      child: Container(
        height: 78,
        margin: const EdgeInsets.symmetric(horizontal: 10),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(39),
          border: Border.all(color: Colors.white24),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // the panel's picture for this level, cropped to the strip (never scaled up to the screen)
            RemoteMedia(
              b.imageUrl,
              key: ValueKey(b.imageUrl),
              fit: BoxFit.cover,
              loop: true,
              fallback: const ColoredBox(color: Color(0xFF1B1140)),
            ),
            // keeps the name readable over any picture
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [Color(0x99000000), Color(0x33000000), Color(0x99000000)]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  AppAvatar(
                    name: b.name,
                    imageUrl: b.who?.avatarUrl,
                    frameUrl: b.who?.frameUrl,
                    size: 44,
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          b.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Poppins',
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                            color: Colors.white,
                            shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
                          ),
                        ),
                        Row(
                          children: [
                            if (b.who != null) ...[
                              LevelStars(wealth: b.who!.wealthLevel, charm: b.who!.charmLevel, size: 15),
                              const SizedBox(width: 8),
                            ],
                            Text(
                              tr('joined'),
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                                shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
