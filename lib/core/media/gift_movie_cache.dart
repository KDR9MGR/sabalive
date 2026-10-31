import 'dart:async';
import 'dart:collection';

import 'package:flutter_svga/flutter_svga.dart' show MovieEntity, SVGACache, SVGAParser;

/// Decoded SVGA animations kept in memory, so a gift tile or a repeated gift effect draws at once.
///
/// flutter_svga keeps only the raw FILE on disk: every time a tile was built the file was inflated and parsed again on the UI thread, so opening the gift sheet a second
/// time was as slow as the first, and sixty tiles meant sixty decodes. Here a decoded movie is kept and a decode that is already running is shared by everyone asking for
/// the same file.
///
/// Two rules keep that safe:
///  * A movie from here is SHARED, so it is marked `autorelease = false`: flutter_svga's player otherwise frees a movie's pictures when the player goes away, which would
///    leave the next user of the cached movie with nothing to draw. Nothing here frees one by hand either (a movie that is still on screen when it is pushed out is simply
///    forgotten and the garbage collector releases it once it is off screen).
///  * The memory is bounded in BYTES, not only in number: a gift file is a full-screen effect and its decoded pictures can be several megabytes, so only the most recently
///    used movies that fit in [maxBytes] (and [capacity]) are kept; a movie bigger than [maxBytes] on its own is used and not kept.
class GiftMovieCache {
  GiftMovieCache({
    this.capacity = 48,
    this.maxBytes = 64 * 1024 * 1024,
    Future<MovieEntity> Function(String url)? decode,
    int Function(MovieEntity movie)? sizeOf,
  })  : _decode = decode ?? SVGAParser.shared.decodeFromURL,
        _sizeOf = sizeOf ?? _decodedBytes;

  /// The one the app's gift tiles and gift effects share.
  static final GiftMovieCache instance = GiftMovieCache();

  final int capacity;
  final int maxBytes;
  final Future<MovieEntity> Function(String url) _decode;
  final int Function(MovieEntity movie) _sizeOf;
  final LinkedHashMap<String, MovieEntity> _movies = LinkedHashMap();
  final Map<String, int> _sizes = {};
  final Map<String, Future<MovieEntity>> _running = {};
  int _bytes = 0;

  /// How many decoded movies are held now, and how many bytes they take (tests).
  int get length => _movies.length;
  int get bytes => _bytes;

  /// What a decoded movie costs in memory: its pictures, 4 bytes a pixel.
  static int _decodedBytes(MovieEntity movie) {
    var total = 0;
    for (final image in movie.bitmapCache.values) {
      total += image.width * image.height * 4;
    }
    return total;
  }

  /// The decoded movie for [url]: from memory, from a decode already running, or decoded now (the file comes from the SVGA file cache, or the network the first time).
  Future<MovieEntity> load(String url) {
    final hit = _movies.remove(url);
    if (hit != null) {
      _movies[url] = hit; // most recently used goes last
      return Future.value(hit);
    }
    return _running[url] ??= _decode(url).then((movie) {
      movie.autorelease = false; // shared: no player may free it (see above)
      _keep(url, movie);
      return movie;
    }).whenComplete(() {
      _running.remove(url); // a block body: returning the removed future from here would make it wait for itself
    });
  }

  void _keep(String url, MovieEntity movie) {
    final size = _sizeOf(movie);
    if (size > maxBytes) return; // too big to keep: used once, then forgotten
    _movies[url] = movie;
    _sizes[url] = size;
    _bytes += size;
    while (_movies.length > 1 && (_movies.length > capacity || _bytes > maxBytes)) {
      final oldest = _movies.keys.first;
      _movies.remove(oldest);
      _bytes -= _sizes.remove(oldest) ?? 0;
    }
  }

  /// Decodes [urls] one after another, [gap] apart, so the first page of the gift sheet is ready before it is opened without a burst of decoding on the UI thread.
  /// A file that cannot be read is skipped.
  Future<void> prewarm(Iterable<String> urls, {Duration gap = const Duration(milliseconds: 400)}) async {
    for (final url in urls) {
      try {
        await load(url);
      } catch (_) {}
      await Future<void>.delayed(gap);
    }
  }

  void clear() {
    _movies.clear();
    _sizes.clear();
    _bytes = 0;
  }
}

/// How long the phone keeps the files it has downloaded for animations. flutter_svga's own defaults are 7 days and 100 MB, after which every gift, frame and effect is
/// fetched all over again; the panel's files rarely change (a changed file has a new address), so they are kept much longer. Call once at start.
void configureMediaCaches() {
  SVGACache.shared.setMaxAge(const Duration(days: 60));
  SVGACache.shared.setMaxCacheSize(250 * 1024 * 1024);
}
