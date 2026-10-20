import 'package:flutter/material.dart';
import 'package:flutter_svga/flutter_svga.dart';

import '../../../core/widgets/remote_media.dart';
import '../../../state/pk_theme_store.dart';

/// The PK animations bundled in `assets/pk/` (see `tool/pk_assets/README.md` for what each one is).
abstract final class PkAsset {
  static const _dir = 'assets/pk';

  static const matching = '$_dir/pk_matching.svga';
  static const invite = '$_dir/pk_svga.svga';
  static const logo = '$_dir/pk_start_anim.svga';
  static const gloves = '$_dir/pk_anim.svga';
  static const countdown = '$_dir/pk_count_down.svga';
  static const versus = '$_dir/room_battle_start_animator.svga';
  static const hero = '$_dir/live_pk.svga';
  static const badge = '$_dir/pk_progress_battle.svga';
  static const win = '$_dir/live_pk_win_icon.svga';
  static const lose = '$_dir/live_pk_lose_icon.svga';
  static const draw = '$_dir/live_pk_draw_icon.svga';
  static const loseEmoji = '$_dir/lose.svga';

  /// A side's striped score bar.
  static String bar(PkTeam team) => team == PkTeam.mine ? '$_dir/pk_progress_red.svga' : '$_dir/pk_progress_blue.svga';

  /// A side's sword. [rtl]: the mirrored file for right-to-left languages, where the bar's ends swap sides.
  static String sword(PkTeam team, {bool rtl = false}) =>
      '$_dir/pk_mic_${team == PkTeam.mine ? 'red' : 'blue'}${rtl ? '_rtl' : ''}.svga';
}

/// Plays one of the bundled PK animations.
///
///  * [loop] repeats it; otherwise it plays once and calls [onFinished] (also when it can't be played or animations are off, so
///    nothing waits on it forever);
///  * [fallback] is the plain visual the screen had before the animations existed. It shows INSTEAD of the animation when the panel
///    has the PK animations switched off or when the file can't be played, and never while the file is still loading (that would
///    flash it for a moment before the animation replaced it);
///  * [team] marks the red / blue art: when the panel gave that side another colour its hue is turned to it.
///
/// [RemoteMedia] puts the moving picture in its own repaint layer, so it never makes whatever is around it paint again (the live
/// screen's lag fix: an SVGA repaints on every display refresh).
class PkSvga extends StatefulWidget {
  const PkSvga(this.asset, {super.key, this.loop = false, this.loopFrom = 0, this.fit = BoxFit.contain, this.team, this.onFinished, this.fallback, this.speed = 1});

  final String asset;
  final bool loop;

  /// See [RemoteMedia.loopFrom]: with [loop], play once, then repeat only from this share of the file on.
  final double loopFrom;
  final BoxFit fit;
  final PkTeam? team;
  final VoidCallback? onFinished;
  final Widget? fallback;
  final double speed;

  /// How a bundled file is read. Replaced in tests.
  static SvgaLoader loader = SVGAParser.shared.decodeFromAssets;

  @override
  State<PkSvga> createState() => _PkSvgaState();
}

class _PkSvgaState extends State<PkSvga> {
  bool _failed = false;

  @override
  void didUpdateWidget(PkSvga old) {
    super.didUpdateWidget(old);
    if (old.asset != widget.asset) _failed = false;
  }

  Widget get _plain => widget.fallback ?? const SizedBox.shrink();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PkThemeStore.instance,
      builder: (context, _) {
        final theme = PkThemeStore.instance.theme;
        if (!theme.animations) {
          if (widget.onFinished != null) {
            // a one-shot says it is done at once: there is nothing to wait for
            WidgetsBinding.instance.addPostFrameCallback((_) => widget.onFinished?.call());
          }
          return _plain;
        }
        if (_failed) return _plain;
        // RemoteMedia gives a moving picture its own repaint layer
        Widget media = RemoteMedia(
          widget.asset,
          svgaLoader: PkSvga.loader,
          loop: widget.loop,
          loopFrom: widget.loopFrom,
          fit: widget.fit,
          speed: widget.speed,
          onFinished: widget.onFinished,
          onError: () {
            if (mounted) setState(() => _failed = true);
          },
        );
        final team = widget.team;
        final shift = team == null ? 0.0 : theme.hueShift(team);
        if (shift.abs() >= 4) {
          media = ColorFiltered(colorFilter: ColorFilter.matrix(pkHueMatrix(shift)), child: media);
        }
        return media;
      },
    );
  }
}
