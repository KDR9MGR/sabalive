import 'dart:async';

import 'package:flutter_svga/flutter_svga.dart' show MovieEntity, SVGACache;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabalive/core/media/gift_movie_cache.dart';
import 'package:sabalive/data/gift_catalog_cache.dart';
import 'package:sabalive/data/models.dart';

/// Gifts and assets that show at once: decoded animations kept in memory, files kept on the phone for weeks, the gift list kept between runs.
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
