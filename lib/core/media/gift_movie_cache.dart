import 'dart:async';
import 'dart:collection';

import 'package:flutter_svga/flutter_svga.dart' show MovieEntity, SVGACache, SVGAParser;

/// Decoded SVGA animations kept in memory, so a gift tile (or any small SVGA picture) that comes back on screen draws at once.
///
/// flutter_svga keeps only the raw FILE on disk: every time a tile was built the file was inflated and parsed again on the UI thread, so opening the gift sheet a second
/// time was as slow as the first, and sixty tiles meant sixty decodes. Here a decoded movie is kept (the [capacity] most recently used) and a decode that is already running
/// is shared by everyone asking for the same file.
class GiftMovieCache {
  GiftMovieCache({this.capacity = 48, Future<MovieEntity> Function(String url)? decode}) : _decode = decode ?? SVGAParser.shared.decodeFromURL;

  /// The one the app's gift tiles share.
  static final GiftMovieCache instance = GiftMovieCache();

  final int capacity;
  final Future<MovieEntity> Function(String url) _decode;
  final LinkedHashMap<String, MovieEntity> _movies = LinkedHashMap();
  final Map<String, Future<MovieEntity>> _running = {};

  /// How many decoded movies are held now (tests).
  int get length => _movies.length;

  /// The decoded movie for [url]: from memory, from a decode already running, or decoded now (the file comes from the SVGA file cache, or the network the first time).
  Future<MovieEntity> load(String url) {
    final hit = _movies.remove(url);
    if (hit != null) {
      _movies[url] = hit; // most recently used goes last
      return Future.value(hit);
    }
    return _running[url] ??= _decode(url).then((movie) {
      _movies[url] = movie;
      while (_movies.length > capacity) {
        _movies.remove(_movies.keys.first);
      }
      return movie;
    }).whenComplete(() {
      _running.remove(url); // a block body: returning the removed future from here would make it wait for itself
    });
  }

  void clear() => _movies.clear();
}

/// How long the phone keeps the files it has downloaded for animations. flutter_svga's own defaults are 7 days and 100 MB, after which every gift, frame and effect is
/// fetched all over again; the panel's files rarely change (a changed file has a new address), so they are kept much longer. Call once at start.
void configureMediaCaches() {
  SVGACache.shared.setMaxAge(const Duration(days: 60));
  SVGACache.shared.setMaxCacheSize(250 * 1024 * 1024);
}
