import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/banners_repository.dart';

/// The home-screen banner carousel. Slides on its own every [loadInterval]
/// seconds (the admin panel's Banners -> Auto-slide setting), always forward
/// and wrapping round, and re-reads that setting every few minutes so a panel
/// change takes effect without restarting the app. It waits while a finger is on
/// it, then starts a fresh countdown. One banner (or none) never slides.
class BannerCarousel extends StatefulWidget {
  const BannerCarousel({
    super.key,
    required this.banners,
    required this.itemBuilder,
    required this.loadInterval,
    this.refreshEvery = const Duration(minutes: 5),
    this.slideDuration = const Duration(milliseconds: 450),
  });

  final List<PromoBanner> banners;
  final Widget Function(BuildContext context, PromoBanner banner) itemBuilder;
  final Future<Duration> Function() loadInterval;
  final Duration refreshEvery;
  final Duration slideDuration;

  @override
  State<BannerCarousel> createState() => _BannerCarouselState();
}

class _BannerCarouselState extends State<BannerCarousel> {
  // The PageView has no end (page index modulo the banner count) so sliding
  // forward from the last banner just carries on to the first, instead of
  // spinning back through all of them.
  late final PageController _pages = PageController(
    initialPage: _start(widget.banners.length),
  );
  Timer? _slide;
  Timer? _refresh;
  Duration _interval = defaultBannerInterval;
  int _page = 0;
  bool _touching = false;

  static int _start(int n) => n <= 1 ? 0 : n * 1000;

  @override
  void initState() {
    super.initState();
    _page = _pages.initialPage;
    _applyInterval();
    _refresh = Timer.periodic(widget.refreshEvery, (_) => _applyInterval());
  }

  @override
  void didUpdateWidget(BannerCarousel old) {
    super.didUpdateWidget(old);
    if (old.banners.length != widget.banners.length) _restartSlide();
  }

  @override
  void dispose() {
    _slide?.cancel();
    _refresh?.cancel();
    _pages.dispose();
    super.dispose();
  }

  Future<void> _applyInterval() async {
    final d = await widget.loadInterval();
    if (!mounted) return;
    if (d != _interval || _slide == null) {
      _interval = d;
      _restartSlide();
    }
  }

  void _restartSlide() {
    _slide?.cancel();
    _slide = null;
    if (widget.banners.length < 2) return;
    _slide = Timer.periodic(_interval, (_) => _advance());
  }

  void _advance() {
    if (_touching || !mounted || !_pages.hasClients) return;
    _pages.nextPage(duration: widget.slideDuration, curve: Curves.easeInOut);
  }

  void _touch(bool down) {
    _touching = down;
    // after letting go, give the person the full interval before sliding on
    if (!down) _restartSlide();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.banners.length;
    if (n == 0) return const SizedBox.shrink();
    return Listener(
      onPointerDown: (_) => _touch(true),
      onPointerUp: (_) => _touch(false),
      onPointerCancel: (_) => _touch(false),
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          PageView.builder(
            controller: _pages,
            itemCount: n == 1 ? 1 : null,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) =>
                widget.itemBuilder(context, widget.banners[i % n]),
          ),
          if (n > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < n; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: _page % n == i ? 16 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: _page % n == i
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
