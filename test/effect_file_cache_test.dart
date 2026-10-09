import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sabalive/core/media/effect_file_cache.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('effect_cache_test'));
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  EffectFileCache make(http.Client client, {int maxBytes = 1000, int maxFileBytes = 500}) => EffectFileCache(
        directory: () async => dir,
        client: client,
        maxBytes: maxBytes,
        maxFileBytes: maxFileBytes,
        timeout: const Duration(seconds: 2),
      );

  test('file names are stable, distinct per url, and keep a safe extension', () {
    final a = EffectFileCache.fileNameFor('https://x.co/a/gift.mp4?token=1');
    expect(a, EffectFileCache.fileNameFor('https://x.co/a/gift.mp4?token=1'));
    expect(a, isNot(EffectFileCache.fileNameFor('https://x.co/a/gift.mp4?token=2')));
    expect(a, endsWith('.mp4'));
    expect(EffectFileCache.fileNameFor('https://x.co/noext'), endsWith('.bin'));
    expect(EffectFileCache.fileNameFor('https://x.co/a.../../evil.mp4%00'), isNot(contains('/')));
  });

  test('downloads once, then serves from storage', () async {
    var calls = 0;
    final cache = make(MockClient((_) async {
      calls++;
      return http.Response.bytes(List.filled(100, 7), 200);
    }));
    expect(await cache.cached('https://x.co/g.mp4'), isNull);
    final f = await cache.fetch('https://x.co/g.mp4');
    expect(f, isNotNull);
    expect(await f!.length(), 100);
    expect(await cache.cached('https://x.co/g.mp4'), isNotNull);
    await cache.fetch('https://x.co/g.mp4');
    expect(calls, 1);
  });

  test('overlapping fetches of one url share one download', () async {
    var calls = 0;
    final cache = make(MockClient((_) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return http.Response.bytes(List.filled(10, 1), 200);
    }));
    final files = await Future.wait([cache.fetch('https://x.co/a.mp3'), cache.fetch('https://x.co/a.mp3')]);
    expect(files.every((f) => f != null), isTrue);
    expect(calls, 1);
  });

  test('a failed, missing or oversized download answers null and stores nothing', () async {
    final big = make(MockClient((_) async => http.Response.bytes(List.filled(600, 1), 200)));
    expect(await big.fetch('https://x.co/big.mp4'), isNull);
    final missing = make(MockClient((_) async => http.Response('nope', 404)));
    expect(await missing.fetch('https://x.co/gone.mp4'), isNull);
    final offline = make(MockClient((_) async => throw const SocketException('offline')));
    expect(await offline.fetch('https://x.co/off.mp4'), isNull);
    expect(await dir.list().toList(), isEmpty);
  });

  test('the folder is trimmed to the limit, oldest file first', () async {
    final cache = make(MockClient((_) async => http.Response.bytes(List.filled(400, 1), 200)), maxBytes: 900);
    final first = await cache.fetch('https://x.co/1.mp4');
    await first!.setLastModified(DateTime.now().subtract(const Duration(hours: 2)));
    await cache.fetch('https://x.co/2.mp4');
    await cache.fetch('https://x.co/3.mp4');
    await Future<void>.delayed(const Duration(milliseconds: 200)); // the trim runs in the background
    final left = await dir.list().where((e) => e is File).toList();
    expect(left.length, 2);
    expect(await cache.cached('https://x.co/1.mp4'), isNull, reason: 'the oldest went');
  });
}
