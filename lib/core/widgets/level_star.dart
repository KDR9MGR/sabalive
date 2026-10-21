import 'dart:io';

import 'package:flutter/material.dart' hide Text;

import '../../data/level_images.dart';
import '../../theme/app_colors.dart';
import '../i18n/text.dart';
import '../media/effect_file_cache.dart';

enum LevelStarKind { wealth, charm }

/// How much the star glints.
enum StarShimmer { none, once, loop }

/// A level badge: a star with the level number inside it, or, where the panel set a picture for that level (Master -> Levels), the picture.
///  - Wealth (coins spent): gold star.
///  - Charm (value received): shiny purple star.
/// Used on the profile screens, in live chat and next to a name when someone joins a live. A picture replaces the star (see [LevelImageStore]); until it
/// is on the phone, and whenever it can't be shown, the star is drawn.
class LevelStar extends StatefulWidget {
  const LevelStar.wealth({
    super.key,
    required this.level,
    this.size = 22,
    this.shimmer = StarShimmer.none,
  }) : kind = LevelStarKind.wealth;

  const LevelStar.charm({
    super.key,
    required this.level,
    this.size = 22,
    this.shimmer = StarShimmer.loop,
  }) : kind = LevelStarKind.charm;

  final LevelStarKind kind;
  final int level;
  final double size;
  final StarShimmer shimmer;

  @override
  State<LevelStar> createState() => _LevelStarState();
}

class _LevelStarState extends State<LevelStar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  bool get _charm => widget.kind == LevelStarKind.charm;

  @override
  void initState() {
    super.initState();
    _sync();
    // the pictures are read once for the whole app; this only makes sure that has started
    LevelImageStore.instance.ensureLoaded();
  }

  @override
  void didUpdateWidget(LevelStar old) {
    super.didUpdateWidget(old);
    if (old.shimmer != widget.shimmer) _sync();
  }

  void _sync() {
    switch (widget.shimmer) {
      case StarShimmer.none:
        _ctl.stop();
        _ctl.value = 0;
      case StarShimmer.once:
        _ctl.forward(from: 0);
      case StarShimmer.loop:
        _ctl.repeat();
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  static const _gold = [Color(0xFFFFE69A), AppColors.gold, AppColors.goldDeep];
  // follows the panel's branding, so not const
  static List<Color> get _purple => [
    Color(0xFFE6C2FF),
    AppColors.primaryBright,
    AppColors.primaryDeep,
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: LevelImageStore.instance,
      builder: (context, _) {
        final star = _star();
        final url = LevelImageStore.instance.urlFor(_charm ? 'charm' : 'wealth', widget.level);
        if (url == null) return star;
        return Semantics(
          label: '${_charm ? 'Charm' : 'Wealth'} level ${widget.level}',
          excludeSemantics: true,
          child: LevelPicture(key: ValueKey('level-picture-$url'), url: url, size: widget.size, fallback: star),
        );
      },
    );
  }

  Widget _star() {
    final size = widget.size;
    final star = Icon(Icons.star_rounded, size: size, color: Colors.white);
    return Semantics(
      label: '${_charm ? 'Charm' : 'Wealth'} level ${widget.level}',
      // announce just "Wealth level 12", not the label and then the bare "12"
      excludeSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (r) => LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: _charm ? _purple : _gold,
              ).createShader(r),
              child: star,
            ),
            if (widget.shimmer != StarShimmer.none)
              AnimatedBuilder(
                animation: _ctl,
                builder: (_, _) {
                  // a bright band sweeping across the star, in the star's own shape
                  final c = _ctl.value * 1.7 - 0.35;
                  double s(double v) => v.clamp(0.0, 1.0);
                  return ShaderMask(
                    blendMode: BlendMode.srcIn,
                    shaderCallback: (r) => LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.transparent,
                        Colors.white.withValues(alpha: 0.9),
                        Colors.transparent,
                      ],
                      stops: [s(c - 0.16), s(c), s(c + 0.16)],
                    ).createShader(r),
                    child: star,
                  );
                },
              ),
            Padding(
              padding: EdgeInsets.only(top: size * 0.05),
              child: SizedBox(
                width: size * 0.56,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${widget.level}',
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w800,
                      fontSize: size * 0.42,
                      height: 1,
                      color: _charm ? Colors.white : const Color(0xFF5A3A00),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The panel's picture for a level, kept on the phone (the app's file cache) so each one is downloaded once, then drawn [size] tall at its own width.
/// While it is not on the phone yet, and if it can't be read or drawn, [fallback] (the star) is shown, so a level never shows nothing.
class LevelPicture extends StatefulWidget {
  const LevelPicture({super.key, required this.url, required this.size, required this.fallback, this.loader});

  final String url;
  final double size;
  final Widget fallback;

  /// Replaces the file cache (tests).
  final Future<File?> Function(String url)? loader;

  @override
  State<LevelPicture> createState() => _LevelPictureState();
}

class _LevelPictureState extends State<LevelPicture> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final url = widget.url;
    File? file;
    try {
      final load = widget.loader;
      file = load != null ? await load(url) : (await EffectFileCache.instance.cached(url) ?? await EffectFileCache.instance.fetch(url));
    } catch (_) {
      file = null;
    }
    if (mounted && url == widget.url && file != null) setState(() => _file = file);
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    if (file == null) return widget.fallback;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Image.file(
      file,
      key: const ValueKey('level-picture'),
      height: widget.size,
      fit: BoxFit.contain,
      cacheHeight: (widget.size * dpr).ceil(), // decode small: the file may be a large join picture
      gaplessPlayback: true,
      // the star stays until the picture has really been decoded (no blank gap), and comes back if it can't be
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) => frame == null && !wasSynchronouslyLoaded ? widget.fallback : child,
      errorBuilder: (_, _, _) => widget.fallback,
    );
  }
}

/// Wealth (gold) and Charm (purple) side by side.
class LevelStars extends StatelessWidget {
  const LevelStars({
    super.key,
    required this.wealth,
    required this.charm,
    this.size = 22,
    this.gap = 4,
    this.charmShimmer = StarShimmer.loop,
  });

  final int wealth;
  final int charm;
  final double size;
  final double gap;
  final StarShimmer charmShimmer;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        LevelStar.wealth(level: wealth, size: size),
        SizedBox(width: gap),
        LevelStar.charm(level: charm, size: size, shimmer: charmShimmer),
      ],
    );
  }
}
