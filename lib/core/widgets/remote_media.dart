import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svga/flutter_svga.dart';
import 'package:video_player/video_player.dart';

enum MediaKind { svga, video, animatedImage, image }

/// What a panel-uploaded file is, from its extension (ignoring any query string,
/// e.g. a signed URL). The panel accepts SVGA, MP4, WebP, GIF and PNG/JPG; GIF
/// and WebP may be animated, anything unrecognised is treated as a still image.
MediaKind mediaKindFor(String url) {
  final path = Uri.tryParse(url)?.path ?? url;
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'svga' => MediaKind.svga,
    'mp4' || 'webm' || 'mov' || 'm4v' => MediaKind.video,
    'gif' || 'webp' => MediaKind.animatedImage,
    _ => MediaKind.image,
  };
}

typedef SvgaLoader = Future<MovieEntity> Function(String url);
typedef ImageBytesLoader = Future<Uint8List> Function(String url);

/// How long a GIF / WebP frame is held. A frame that asks for under 20 ms
/// (converters often write 0 or 10 ms) is shown for 100 ms, as browsers do —
/// Flutter's own `Image.network` honours the raw value and plays those files
/// far too fast.
Duration normalizedFrameDelay(Duration d) =>
    d < const Duration(milliseconds: 20) ? const Duration(milliseconds: 100) : d;

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
    this.imageLoader,
  });

  final String url;
  final BoxFit fit;
  final bool loop;

  /// False for small thumbnails (a grid of gifts): an SVGA shows its first
  /// frame without playing, an MP4 shows its first frame paused (a few at a
  /// time — video decoders are limited; the rest show the [fallback]), and a
  /// GIF / WebP shows its first frame.
  final bool animate;
  final bool muted;
  final VoidCallback? onFinished;

  /// The file could not be loaded or played. Called just before [onFinished],
  /// so a caller can show something else (a gift falls back to its emoji).
  final VoidCallback? onError;
  final Widget? fallback;

  /// Injectable for tests; defaults to downloading (and caching) the file.
  final SvgaLoader? svgaLoader;
  final ImageBytesLoader? imageLoader;

  @override
  Widget build(BuildContext context) {
    final blank = fallback ?? const SizedBox.shrink();
    final kind = mediaKindFor(url);
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
          still: !animate,
          onFinished: onFinished,
          onError: onError,
          fallback: blank,
        ),
      MediaKind.animatedImage => _AnimatedImageMedia(
          key: ValueKey(url),
          url: url,
          fit: fit,
          loop: loop,
          animate: animate,
          onFinished: onFinished,
          onError: onError,
          fallback: blank,
          loader: imageLoader ?? _downloadImageBytes,
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
    required this.still,
    required this.onFinished,
    required this.onError,
    required this.fallback,
  });
  final String url;
  final BoxFit fit;
  final bool loop;
  final bool muted;

  /// A thumbnail: show the first frame, paused.
  final bool still;
  final VoidCallback? onFinished;
  final VoidCallback? onError;
  final Widget fallback;

  @override
  State<_VideoMedia> createState() => _VideoMediaState();
}

class _VideoMediaState extends State<_VideoMedia> {
  /// Video decoders are scarce (a phone has only a handful), so only this many
  /// still thumbnails are held at once; the rest show their fallback.
  static const _maxStills = 6;
  static int _activeStills = 0;

  VideoPlayerController? _c;
  bool _ready = false;
  bool _failed = false;
  bool _finished = false;
  bool _holdsStill = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    if (widget.still) {
      if (_activeStills >= _maxStills) {
        setState(() => _failed = true); // fallback shows; not an error
        return;
      }
      _activeStills++;
      _holdsStill = true;
    }
    final c = VideoPlayerController.networkUrl(
      Uri.parse(widget.url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _c = c;
    try {
      await c.initialize();
      if (!mounted) return;
      if (widget.still) {
        await c.setVolume(0);
        await c.seekTo(Duration.zero);
        if (mounted) setState(() => _ready = true);
        return;
      }
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
    if (_holdsStill) _activeStills--;
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


final Map<String, Uint8List> _imageBytesCache = {};

Future<Uint8List> _downloadImageBytes(String url) async {
  final cached = _imageBytesCache[url];
  if (cached != null) return cached;
  final data = await NetworkAssetBundle(Uri.parse(url)).load('');
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  if (_imageBytesCache.length >= 24) {
    _imageBytesCache.remove(_imageBytesCache.keys.first);
  }
  return _imageBytesCache[url] = bytes;
}

/// Plays an animated GIF / WebP at the right speed (see [normalizedFrameDelay]).
class _AnimatedImageMedia extends StatefulWidget {
  const _AnimatedImageMedia({
    super.key,
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
  final ImageBytesLoader loader;

  @override
  State<_AnimatedImageMedia> createState() => _AnimatedImageMediaState();
}

class _AnimatedImageMediaState extends State<_AnimatedImageMedia> {
  ui.Codec? _codec;
  ui.Image? _image;
  Timer? _timer;
  bool _failed = false;
  bool _finished = false;
  int _shown = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.loader(widget.url);
      final codec = await ui.instantiateImageCodec(bytes);
      if (!mounted) {
        codec.dispose();
        return;
      }
      _codec = codec;
      await _nextFrame();
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
      widget.onError?.call();
      _done();
    }
  }

  Future<void> _nextFrame() async {
    final codec = _codec;
    if (codec == null || !mounted) return;
    final frame = await codec.getNextFrame();
    if (!mounted) {
      frame.image.dispose();
      return;
    }
    final old = _image;
    setState(() => _image = frame.image);
    old?.dispose();
    _shown++;

    final single = codec.frameCount <= 1;
    final passDone = _shown >= codec.frameCount;
    if (!widget.animate || single) {
      if (!widget.loop || single) _done();
      return;
    }
    if (passDone && !widget.loop) {
      _done();
      return;
    }
    _timer = Timer(normalizedFrameDelay(frame.duration), _nextFrame);
  }

  void _done() {
    if (_finished || !mounted) return;
    _finished = true;
    widget.onFinished?.call();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _image?.dispose();
    _codec?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (_failed || image == null) return widget.fallback;
    return RawImage(image: image, fit: widget.fit);
  }
}
