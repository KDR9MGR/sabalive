import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svga/flutter_svga.dart';

import '../media/disk_cached_image.dart';
import 'remote_media.dart';

/// The width of a picture [height] tall whose own size is [pictureWidth] x [pictureHeight], capped at [maxWidth] and never absurdly thin or wide.
double labelPictureWidth(double height, double pictureWidth, double pictureHeight, {double maxWidth = 160}) {
  if (pictureWidth <= 0 || pictureHeight <= 0) return height;
  final aspect = (pictureWidth / pictureHeight).clamp(0.3, 8.0);
  return (height * aspect).clamp(height * 0.3, maxWidth);
}

/// The picture a panel uploaded for a BADGE or a TAG, drawn [height] tall at its own width: a still picture (PNG / JPG), an SVG drawing, an animated GIF / WebP,
/// or an SVGA animation (which loops). It is the picture exactly as uploaded, not a stand-in: the badge or tag's own artwork.
///
/// While an SVGA is loading (its size is only known once it is read), and whenever a file can't be drawn (offline, deleted, a video file), [fallback] is shown, so a badge
/// or tag never disappears. Videos (MP4) are not drawn here: a decoder per label on a profile would cost too much battery; [supports] says which files are drawn.
class LabelPicture extends StatefulWidget {
  const LabelPicture({
    super.key,
    required this.url,
    required this.height,
    required this.fallback,
    this.maxWidth = 160,
    this.animate = true,
    this.svgaLoader,
    this.imageLoader,
  });

  final String url;
  final double height;
  final Widget fallback;
  final double maxWidth;

  /// Play an SVGA (false = its first frame).
  final bool animate;

  /// Replaces reading the SVGA file (tests).
  final SvgaLoader? svgaLoader;

  /// Replaces reading an SVG file (tests).
  final ImageBytesLoader? imageLoader;

  /// Can this file be drawn by a [LabelPicture]?
  static bool supports(String url) => mediaKindFor(url) != MediaKind.video;

  @override
  State<LabelPicture> createState() => _LabelPictureState();
}

class _LabelPictureState extends State<LabelPicture> {
  MovieEntity? _movie;
  bool _failed = false;
  int _generation = 0;

  bool get _isSvga => mediaKindFor(widget.url) == MediaKind.svga;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(LabelPicture old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _movie = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    if (!_isSvga) return;
    final generation = ++_generation;
    try {
      final movie = await (widget.svgaLoader ?? SVGAParser.shared.decodeFromURL)(widget.url);
      if (!mounted || generation != _generation) return;
      // a reply that is not an SVGA (an empty or error body) can still come back as an "empty" movie with no size: that is a failure
      if (movie.params.viewBoxWidth <= 0 || movie.params.viewBoxHeight <= 0) {
        setState(() => _failed = true);
        return;
      }
      setState(() => _movie = movie);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final kind = mediaKindFor(widget.url);
    if (_failed || kind == MediaKind.video) return widget.fallback;
    if (kind == MediaKind.svga) {
      final movie = _movie;
      if (movie == null) return widget.fallback;
      final width = labelPictureWidth(widget.height, movie.params.viewBoxWidth, movie.params.viewBoxHeight, maxWidth: widget.maxWidth);
      // Clipped to its own box: the player draws outside its frame by default, and an animation may carry a layer wider than its canvas (the owner's Host tag has a 500 px
      // wide light sweep on a 310 px canvas), which showed as a grey strip beside the tag every time it played. An SVGA is meant to be seen inside its canvas.
      return SizedBox(
        width: width,
        height: widget.height,
        child: ClipRect(
          child: RemoteMedia(
            widget.url,
            key: ValueKey('label-svga-${widget.url}'),
            fit: BoxFit.contain,
            loop: true,
            animate: widget.animate,
            svgaLoader: (_) async => movie,
            // if it cannot play after all, the stand-in scales to the box instead of overflowing it
            fallback: FittedBox(fit: BoxFit.scaleDown, child: widget.fallback),
          ),
        ),
      );
    }
    if (kind == MediaKind.svg) {
      // a vector drawing: read once and drawn at the height asked, so a badge made as an SVG is as sharp as any size needs
      return SizedBox(
        height: widget.height,
        child: RemoteMedia(widget.url, key: ValueKey('label-svg-${widget.url}'), fit: BoxFit.contain, imageLoader: widget.imageLoader, fallback: widget.fallback),
      );
    }
    return Image(
      image: ResizeImage(DiskCachedNetworkImage(widget.url), height: (widget.height * MediaQuery.devicePixelRatioOf(context)).ceil()),
      height: widget.height,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => widget.fallback,
    );
  }
}
