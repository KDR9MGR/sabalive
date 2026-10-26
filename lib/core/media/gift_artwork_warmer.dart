import 'dart:async';

import 'package:flutter_svga/flutter_svga.dart' show SVGACache;
import 'package:http/http.dart' as http;

import '../../data/models.dart';
import '../widgets/remote_media.dart' show MediaKind, mediaKindFor;
import 'disk_cached_image.dart';
import 'effect_file_cache.dart';

/// Puts the gifts' artwork on the phone BEFORE anyone opens the gift sheet, so its tiles draw at once instead of showing a stand-in while each file downloads.
///
/// Every gift is one file the panel uploaded (an SVGA, MP4, GIF / WebP, SVG or picture) and the sheet draws its first frame, so the first time a phone shows the grid it
/// used to fetch dozens of files together. This reads them quietly in the background, a couple at a time, once the gift list has loaded (and again when the list changes):
///  - pictures, SVG and GIF / WebP go into the picture cache, MP4 into the effect cache, SVGA into the SVGA cache (raw file only: nothing is decoded here, so it costs no
///    CPU worth the name and cannot make a live room stutter);
///  - a file already on the phone is skipped, so a later start downloads nothing;
///  - at most [limit] gifts, the first ones in the panel's order (the Popular tab), and one pass at a time.
/// Nothing here can fail loudly: a file that cannot be fetched is simply fetched when it is needed, as before.
class GiftArtworkWarmer {
  GiftArtworkWarmer({
    this.limit = 60,
    this.parallel = 2,
    Future<bool> Function(String url, MediaKind kind)? warmOne,
  }) : _warmOne = warmOne ?? _defaultWarmOne;

  static final GiftArtworkWarmer instance = GiftArtworkWarmer();

  final int limit;
  final int parallel;
  final Future<bool> Function(String url, MediaKind kind) _warmOne;

  final Set<String> _done = {};
  bool _running = false;
  List<Gift>? _pending;

  /// How many files this has fetched (or found on the phone) so far: for tests and diagnostics.
  int get warmed => _done.length;

  /// Warms [gifts]' artwork. A call while a pass is running replaces what is still waiting (the newest list wins). Returns when the pass ends.
  Future<void> warm(List<Gift> gifts) async {
    _pending = gifts;
    if (_running) return;
    _running = true;
    try {
      while (_pending != null) {
        final batch = _pending!;
        _pending = null;
        final urls = <(String, MediaKind)>[];
        for (final g in batch.take(limit)) {
          final url = g.iconUrl;
          if (url == null || _done.contains(url)) continue;
          urls.add((url, mediaKindFor(url)));
        }
        var next = 0;
        Future<void> worker() async {
          while (next < urls.length) {
            // a newer list arrived: stop this pass and start from that one
            if (_pending != null) return;
            final (url, kind) = urls[next++];
            try {
              if (await _warmOne(url, kind)) _done.add(url);
            } catch (_) {
              // fetched later, when it is needed
            }
          }
        }

        await Future.wait([for (var i = 0; i < parallel; i++) worker()]);
      }
    } finally {
      _running = false;
    }
  }

  static Future<bool> _defaultWarmOne(String url, MediaKind kind) async {
    switch (kind) {
      case MediaKind.video:
        return (await EffectFileCache.instance.cached(url) ?? await EffectFileCache.instance.fetch(url)) != null;
      case MediaKind.svga:
        if (await SVGACache.shared.getRawBytes(url) != null) return true;
        final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 25));
        if (r.statusCode != 200 || r.bodyBytes.isEmpty) return false;
        await SVGACache.shared.putRawBytes(url, r.bodyBytes);
        return true;
      case MediaKind.svg:
      case MediaKind.animatedImage:
      case MediaKind.image:
        return (await imageFileCache.cached(url) ?? await imageFileCache.fetch(url)) != null;
    }
  }
}
