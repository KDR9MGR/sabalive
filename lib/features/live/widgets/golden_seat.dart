import 'package:flutter/material.dart' hide Text;
import 'package:flutter_svga/flutter_svga.dart';

import '../../../core/widgets/remote_media.dart';

/// The picture of an EMPTY seat in an audio room (owner, 2026-11-06: "use this as seats"): a golden throne inside a golden ring that shimmers, the owner's
/// `goldan seat.svga` (159 x 159, 20 fps, 30 frames, a plain flip-book of pictures), bundled as `assets/seat/golden_seat.svga`.
///
/// One decoded movie is shared by every empty seat of the room (a room has up to 16): it is read once per run, never disposed (`autorelease` off, like the
/// notice strip and the gift movies), and each seat only plays it. It replaces the grey circle with a chair icon of an empty seat; a LOCKED seat keeps its
/// padlock, and an occupied seat shows its person as before. Until the file is read (or if it cannot be) the old grey circle stands in, so a seat is never blank.
abstract final class GoldenSeatArt {
  static const asset = 'assets/seat/golden_seat.svga';

  /// The file's own square canvas.
  static const double canvas = 159;

  /// The golden ring spans pixels 28..131 of the 159 px canvas (measured on the frames), the rest is see-through margin: the ring is this much of the picture.
  static const double ringFraction = 104 / 159;

  static Future<MovieEntity>? _movie;

  /// The decoded file, read once per run and kept.
  static Future<MovieEntity> movie({SvgaLoader? loader}) {
    return _movie ??= (loader ?? debugLoader ?? _decodeAsset)(asset).then((m) {
      m.autorelease = false;
      return m;
    }, onError: (Object e) {
      _movie = null; // try again next time
      throw e;
    });
  }

  static Future<MovieEntity> _decodeAsset(String path) => SVGAParser.shared.decodeFromAssets(path);

  /// Tests put a fake reader here so a seat grid never decodes the real file.
  @visibleForTesting
  static SvgaLoader? debugLoader;

  @visibleForTesting
  static void forget() => _movie = null;
}

/// The golden seat, drawn so that its RING is [ring] logical pixels across (the picture itself is bigger: it has see-through margins). It is meant to sit in a
/// box smaller than itself and overflow it (see [SeatCircle]); with "remove animations" on, it shows a single frame instead of playing.
class GoldenSeat extends StatelessWidget {
  const GoldenSeat({super.key, required this.ring, this.fallback});

  final double ring;

  /// What shows until the file is read, or if it cannot be (the grey circle of an empty seat).
  final Widget? fallback;

  /// The side of the whole picture for a ring of [ring].
  static double sideFor(double ring) => ring / GoldenSeatArt.ringFraction;

  @override
  Widget build(BuildContext context) {
    final side = sideFor(ring);
    return SizedBox(
      width: side,
      height: side,
      child: RemoteMedia(
        GoldenSeatArt.asset,
        key: const ValueKey('golden-seat'),
        svgaLoader: (_) => GoldenSeatArt.movie(),
        fit: BoxFit.contain,
        loop: true,
        animate: !MediaQuery.disableAnimationsOf(context),
        fallback: fallback == null ? null : Center(child: fallback),
      ),
    );
  }
}
