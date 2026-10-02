import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svga/flutter_svga.dart';
import 'package:video_player/video_player.dart';

enum MediaKind { svga, video, image }

/// What a panel-uploaded file is, from its extension (ignoring any query string,
/// e.g. a signed URL). The panel accepts SVGA, MP4, WebP, GIF and PNG/JPG;
/// anything unrecognised is treated as an image.
MediaKind mediaKindFor(String url) {
  final path = Uri.tryParse(url)?.path ?? url;
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'svga' => MediaKind.svga,
    'mp4' || 'webm' || 'mov' || 'm4v' => MediaKind.video,
    _ => MediaKind.image,
  };
}

typedef SvgaLoader = Future<MovieEntity> Function(String url);

/// Plays whatever file the admin panel uploaded — SVGA animations, MP4 video,
/// and animated WebP / GIF / static images — in motion. The app used to show
/// everything with a plain `Image.network`, which cannot play SVGA or MP4 at
/// all, so uploads that "synced" never actually animated.
///
///  - [loop]: repeat forever (banners, store previews). Off for one-shot effects
///    (a gift, an entry effect), which call [onFinished] when they end.
///  - [fallback]: shown while loading and if the file can't be played (usually
///    the emoji), and a one-shot effect still reports [onFinished] after a
///    failure so nothing waits on it forever.
class RemoteMedia extends StatelessWidget {
  const RemoteMedia(
    this.url, {
    super.key,
    this.fit = BoxFit.cover,
    this.loop = true,
    this.animate = true,
    this.muted = true,
    this.onFinished,
    this.onError,
    this.fallback,
    this.svgaLoader,
  });

  final String url;
  final BoxFit fit;
  final bool loop;

  /// False for small thumbnails (a grid of gifts): an SVGA shows its first
  /// frame without playing, and an MP4 isn't loaded at all (the [fallback]
  /// shows) — a screen of players decoding at once would stutter.
  final bool animate;
  final bool muted;
  final VoidCallback? onFinished;

  /// The file could not be loaded or played. Called just before [onFinished],
  /// so a caller can show something else (a gift falls back to its emoji).
  final VoidCallback? onError;
  final Widget? fallback;

  /// Injectable for tests; defaults to downloading (and caching) the file.
  final SvgaLoader? svgaLoader;

  @override
  Widget build(BuildContext context) {
    final blank = fallback ?? const SizedBox.shrink();
    final kind = mediaKindFor(url);
    if (kind == MediaKind.video && !animate) return blank;
    return switch (kind) {
      MediaKind.svga => _SvgaMedia(
          url: url,
          fit: fit,
          loop: loop,
          animate: animate,
          onFinished: onFinished,
          onError: onError,
          fallback: blank,
          loader: svgaLoader ?? SVGAParser.shared.decodeFromURL,
        ),
      MediaKind.video => _VideoMedia(
          key: ValueKey(url),
          url: url,
          fit: fit,
          loop: loop,
          muted: muted,
          onFinished: onFinished,
          onError: onError,
          fallback: blank,
        ),
      MediaKind.image => Image.network(
          url,
          fit: fit,
          gaplessPlayback: true,
          loadingBuilder: (_, child, progress) =>
              progress == null ? child : blank,
          errorBuilder: (_, _, _) {
            if (onError != null || onFinished != null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                onError?.call();
                onFinished?.call();
              });
            }
            return blank;
          },
        ),
    };
  }
}

class _SvgaMedia extends StatefulWidget {
  const _SvgaMedia({
    required this.url,
    required this.fit,
    required this.loop,
    required this.animate,
    required this.onFinished,
    required this.onError,
    required this.fallback,
    required this.loader,
  });
  final String url;
  final BoxFit fit;
  final bool loop;
  final bool animate;
  final VoidCallback? onFinished;
  final VoidCallback? onError;
  final Widget fallback;
  final SvgaLoader loader;

  @override
  State<_SvgaMedia> createState() => _SvgaMediaState();
}

class _SvgaMediaState extends State<_SvgaMedia>
    with SingleTickerProviderStateMixin {
  late final SVGAAnimationController _ctl;
  bool _ready = false;
  bool _failed = false;
  bool _finished = false;
  int _generation = 0; // a slow load for an old url must not replace a newer one

  @override
  void initState() {
    super.initState();
    // Created here, not lazily: a lazy controller would first be built inside
    // dispose() when the file failed before ever touching it.
    _ctl = SVGAAnimationController(vsync: this);
    _load();
  }

  @override
  void didUpdateWidget(_SvgaMedia old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _finished = false;
      _ready = false;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final movie = await widget.loader(widget.url);
      if (!mounted || generation != _generation) {
        if (!mounted) movie.dispose();
        return;
      }
      _ctl.videoItem = movie;
      setState(() => _ready = true);
      if (!widget.animate) return; // first frame only
      if (widget.loop) {
        _ctl.repeat();
      } else {
        _ctl.forward().whenComplete(_done);
      }
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _failed = true);
      widget.onError?.call();
      _done(); // a one-shot effect must never wait forever on a bad file
    }
  }

  void _done() {
    if (_finished || !mounted) return;
    _finished = true;
    widget.onFinished?.call();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed || !_ready) return widget.fallback;
    return SVGAImage(_ctl, fit: widget.fit);
  }
}

class _VideoMedia extends StatefulWidget {
  const _VideoMedia({
    super.key,
    required this.url,
    required this.fit,
    required this.loop,
    required this.muted,
    required this.onFinished,
    required this.onError,
    required this.fallback,
  });
  final String url;
  final BoxFit fit;
  final bool loop;
  final bool muted;
  final VoidCallback? onFinished;
  final VoidCallback? onError;
  final Widget fallback;

  @override
  State<_VideoMedia> createState() => _VideoMediaState();
}

class _VideoMediaState extends State<_VideoMedia> {
  VideoPlayerController? _c;
  bool _ready = false;
  bool _failed = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final c = VideoPlayerController.networkUrl(
      Uri.parse(widget.url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _c = c;
    try {
      await c.initialize();
      if (!mounted) return;
      await c.setLooping(widget.loop);
      await c.setVolume(widget.muted ? 0 : 1);
      c.addListener(_watchEnd);
      await c.play();
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
      widget.onError?.call();
      _done();
    }
  }

  void _watchEnd() {
    final v = _c?.value;
    if (v == null || widget.loop || _finished) return;
    if (v.isInitialized && v.duration > Duration.zero && v.position >= v.duration) {
      _done();
    }
  }

  void _done() {
    if (_finished || !mounted) return;
    _finished = true;
    widget.onFinished?.call();
  }

  @override
  void dispose() {
    _c?.removeListener(_watchEnd);
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (_failed || !_ready || c == null) return widget.fallback;
    final size = c.value.size;
    return ClipRect(
      child: FittedBox(
        fit: widget.fit,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: VideoPlayer(c),
        ),
      ),
    );
  }
}
