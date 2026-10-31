import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svga/flutter_svga.dart' show MovieEntity, SVGACache;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabalive/core/media/gift_movie_cache.dart';
import 'package:sabalive/core/widgets/remote_media.dart';
import 'package:sabalive/data/gift_catalog_cache.dart';
import 'package:sabalive/data/models.dart';

/// Gifts and assets that show at once: decoded animations kept in memory, files kept on the phone for weeks, the gift list kept between runs.
/// A movie that shows whether anything freed it: freeing clears its audio data (a marker byte is put there).
MovieEntity _marked() => MovieEntity()..audiosData['marker'] = Uint8List(1);
bool _wasFreed(MovieEntity m) => m.audiosData.isEmpty;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GiftMovieCache (decoded animations in memory)', () {
    test('the second time a file is asked for it is not decoded again', () async {
      var decodes = 0;
      final cache = GiftMovieCache(decode: (url) async {
        decodes++;
        return MovieEntity();
      });
      final a = await cache.load('https://x/a.svga');
      final b = await cache.load('https://x/a.svga');
      expect(decodes, 1);
      expect(identical(a, b), isTrue);
    });

    test('sixty tiles built together for the same file share one decode', () async {
      var decodes = 0;
      final gate = Completer<void>();
      final cache = GiftMovieCache(decode: (url) async {
        decodes++;
        await gate.future;
        return MovieEntity();
      });
      final all = [for (var i = 0; i < 60; i++) cache.load('https://x/a.svga')];
      gate.complete();
      await Future.wait(all);
      expect(decodes, 1);
    });

    test('only the most recently used movies are kept', () async {
      final cache = GiftMovieCache(capacity: 3, decode: (url) async => MovieEntity());
      for (final n in ['a', 'b', 'c']) {
        await cache.load(n);
      }
      await cache.load('a'); // a is used again: b is now the oldest
      await cache.load('d');
      expect(cache.length, 3);
      var decodes = 0;
      final counting = GiftMovieCache(capacity: 3, decode: (url) async {
        decodes++;
        return MovieEntity();
      });
      for (final n in ['a', 'b', 'c', 'a', 'd', 'a', 'c']) {
        await counting.load(n);
      }
      // a, b, c decoded; a hit; d evicts b (a was used last); a hit; c hit
      expect(decodes, 4);
    });

    test('a decode that fails is not kept: the next ask tries again', () async {
      var calls = 0;
      final cache = GiftMovieCache(decode: (url) async {
        calls++;
        if (calls == 1) throw StateError('offline');
        return MovieEntity();
      });
      await expectLater(cache.load('https://x/a.svga'), throwsStateError);
      await cache.load('https://x/a.svga');
      expect(calls, 2);
      expect(cache.length, 1);
    });
  });

  group('GiftMovieCache keeps shared movies safe and small', () {
    test('a cached movie is marked so no player frees it (flutter_svga frees a movie when its player goes away unless autorelease is off)', () async {
      final cache = GiftMovieCache(decode: (url) async => MovieEntity());
      final movie = await cache.load('https://x/a.svga');
      expect(movie.autorelease, isFalse);
    });

    test('the memory is bounded in bytes: the oldest movies go first, and one that is too big alone is used but not kept', () async {
      final sizes = {'a': 40, 'b': 40, 'c': 40, 'huge': 500};
      final cache = GiftMovieCache(maxBytes: 100, decode: (url) async => MovieEntity(), sizeOf: (m) => 0);
      // sizeOf is by movie, so give each url its own movie with a known size
      final bySize = <MovieEntity, int>{};
      final tracking = GiftMovieCache(
        maxBytes: 100,
        decode: (url) async {
          final m = MovieEntity();
          bySize[m] = sizes[url]!;
          return m;
        },
        sizeOf: (m) => bySize[m]!,
      );
      await tracking.load('a');
      await tracking.load('b');
      expect(tracking.bytes, 80);
      await tracking.load('c'); // 120 > 100: a, the oldest, goes
      expect(tracking.length, 2);
      expect(tracking.bytes, 80);
      final huge = await tracking.load('huge');
      expect(huge.autorelease, isFalse, reason: 'still shared by whoever asked at the same time');
      expect(tracking.length, 2, reason: 'too big to keep');
      expect(tracking.bytes, 80);
      expect(cache.length, 0);
    });

    test('prewarm decodes the files one after another and skips one that fails', () async {
      final order = <String>[];
      final cache = GiftMovieCache(decode: (url) async {
        order.add(url);
        if (url == 'bad') throw StateError('offline');
        return MovieEntity();
      });
      await cache.prewarm(['one', 'bad', 'two'], gap: Duration.zero);
      expect(order, ['one', 'bad', 'two']);
      expect(cache.length, 2);
    });

    testWidgets('a tile that goes away before its file arrives does not free a movie the cache holds', (t) async {
      final gate = Completer<MovieEntity>();
      final shared = _marked()..autorelease = false;
      await t.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: RemoteMedia('https://x/gift.svga', svgaLoader: (_) => gate.future),
      ));
      await t.pumpWidget(const SizedBox()); // the tile is gone
      gate.complete(shared);
      await t.pump();
      expect(_wasFreed(shared), isFalse, reason: 'it belongs to the cache');

      final lone = _marked(); // autorelease stays true: nobody else holds it
      final gate2 = Completer<MovieEntity>();
      await t.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: RemoteMedia('https://x/other.svga', svgaLoader: (_) => gate2.future),
      ));
      await t.pumpWidget(const SizedBox());
      gate2.complete(lone);
      await t.pump();
      expect(_wasFreed(lone), isTrue, reason: 'a movie nobody else holds is still freed, as before');
    });
  });

  test('the animation files are kept on the phone for 60 days and up to 250 MB (the package default is 7 days and 100 MB)', () {
    configureMediaCaches();
    expect(SVGACache.shared.maxAge, const Duration(days: 60));
    expect(SVGACache.shared.maxCacheSize, 250 * 1024 * 1024);
  });

  group('GiftCatalogCache (the gift list between runs)', () {
    final rows = [
      {'id': 'g1', 'name': 'Rose', 'emoji': 'R', 'price_coins': 10, 'has_effect': false, 'icon_url': 'https://x/rose.svga', 'category': 'basic'},
      {'id': 'g2', 'name': 'Car', 'emoji': 'C', 'price_coins': 500, 'has_effect': true, 'icon_url': null, 'category': 'vehicle', 'play_speed': 1.5},
    ];

    test('what was written comes back and builds the same gifts', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await GiftCatalogCache.read(), isNull, reason: 'nothing saved yet');
      await GiftCatalogCache.write(rows);
      final back = (await GiftCatalogCache.read())!;
      final gifts = back.map(Gift.fromRow).toList();
      expect(gifts.map((g) => g.name), ['Rose', 'Car']);
      expect(gifts.first.iconUrl, 'https://x/rose.svga');
      expect(gifts.last.category, 'vehicle');
      expect(gifts.last.price, 500);
    });

    test('a damaged copy is ignored, never thrown', () async {
      SharedPreferences.setMockInitialValues({'gifts.catalog.v1': '{not json'});
      expect(await GiftCatalogCache.read(), isNull);
      SharedPreferences.setMockInitialValues({'gifts.catalog.v1': '"just a string"'});
      expect(await GiftCatalogCache.read(), isNull);
    });
  });
}
