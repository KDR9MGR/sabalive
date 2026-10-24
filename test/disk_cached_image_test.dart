import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sabalive/core/media/disk_cached_image.dart';
import 'package:sabalive/core/media/effect_file_cache.dart';

/// Pictures are downloaded once and then read from the phone's storage.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // a 1x1 PNG, enough to decode
  final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');
  const url = 'https://x.supabase.co/storage/v1/object/public/avatars/u1/avatar.jpg?v=1';

  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('disk_image_test');
    PaintingBinding.instance.imageCache.clear(); // Flutter's in-memory cache is keyed by url and would hide what these tests check
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  EffectFileCache cacheFor(http.Client client, {Duration minTrimGap = Duration.zero}) =>
      EffectFileCache(directory: () async => dir, client: client, maxBytes: 1 << 20, maxFileBytes: 1 << 19, timeout: const Duration(seconds: 2), minTrimGap: minTrimGap);

  /// Resolves [provider] and returns the picture's width, or throws what the image stream reported.
  Future<int> load(ImageProvider provider) async {
    final done = Completer<int>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!done.isCompleted) done.complete(info.image.width);
        stream.removeListener(listener);
      },
      onError: (e, _) {
        if (!done.isCompleted) done.completeError(e);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return done.future.timeout(const Duration(seconds: 10));
  }

  test('the first ask downloads the picture, every later ask (even a new provider, even after the app restarts) reads it from storage', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response.bytes(png, 200);
    });
    expect(await load(DiskCachedNetworkImage(url, cache: cacheFor(client))), 1);
    expect(calls, 1);
    // a second provider on the same cache (the in-memory image cache aside)
    expect(await load(DiskCachedNetworkImage('$url&again', cache: cacheFor(client))), 1, reason: 'a different url is a different picture');
    expect(calls, 2);
    PaintingBinding.instance.imageCache.clear();
    expect(await load(DiskCachedNetworkImage(url, cache: cacheFor(client))), 1, reason: 'a brand new cache object over the same folder = the app restarted');
    expect(calls, 2, reason: 'still the same two downloads: the first url came from storage');
  });

  test('resized pictures use the same stored file', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response.bytes(png, 200);
    });
    final cache = cacheFor(client);
    await load(ResizeImage(DiskCachedNetworkImage(url, cache: cache), width: 48));
    await load(ResizeImage(DiskCachedNetworkImage(url, cache: cache), width: 96));
    expect(calls, 1);
  });

  test('a picture that cannot be fetched fails like any image and leaves nothing stored', () async {
    final cache = cacheFor(MockClient((_) async => http.Response('gone', 404)));
    await expectLater(load(DiskCachedNetworkImage(url, cache: cache)), throwsA(isA<DiskCachedImageException>()));
    expect(dir.listSync().where((e) => !e.path.endsWith('.part')), isEmpty);
  });

  test('offline fails the same way', () async {
    final cache = cacheFor(MockClient((_) async => throw const SocketException('offline')));
    await expectLater(load(DiskCachedNetworkImage(url, cache: cache)), throwsA(isA<DiskCachedImageException>()));
  });

  test('a stored file that is not a picture is thrown away, so the next ask downloads a good one', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return calls == 1 ? http.Response.bytes(Uint8List.fromList(utf8.encode('this is not a picture')), 200) : http.Response.bytes(png, 200);
    });
    final cache = cacheFor(client);
    await expectLater(load(DiskCachedNetworkImage(url, cache: cache)), throwsA(anything));
    await Future<void>.delayed(const Duration(milliseconds: 100)); // the bad copy is deleted in the background
    PaintingBinding.instance.imageCache.clear();
    expect(await load(DiskCachedNetworkImage(url, cache: cache)), 1);
    expect(calls, 2);
  });

  test('providers for the same url are equal (so Flutter keeps one decoded copy), different urls are not', () {
    expect(const DiskCachedNetworkImage('a'), const DiskCachedNetworkImage('a'));
    expect(const DiskCachedNetworkImage('a').hashCode, const DiskCachedNetworkImage('a').hashCode);
    expect(const DiskCachedNetworkImage('a'), isNot(const DiskCachedNetworkImage('b')));
  });

  test('the picture cache can wait between trims, and the effect cache still trims at once by default', () async {
    // 3 files of 400 bytes in a 1000 byte cache: with no gap the third download trims the oldest; with a gap the folder may exceed the limit until the next trim
    Future<int> filesAfter(Duration gap) async {
      final d = Directory.systemTemp.createTempSync('trim_gap');
      try {
        final cache = EffectFileCache(
          directory: () async => d,
          client: MockClient((_) async => http.Response.bytes(List.filled(400, 1), 200)),
          maxBytes: 1000,
          maxFileBytes: 500,
          minTrimGap: gap,
        );
        for (final n in ['a', 'b', 'c']) {
          await cache.fetch('https://x.co/$n.png');
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return d.listSync().whereType<File>().where((f) => !f.path.endsWith('.part')).length;
      } finally {
        d.deleteSync(recursive: true);
      }
    }

    expect(await filesAfter(Duration.zero), 2, reason: 'default: trimmed after every new file');
    expect(await filesAfter(const Duration(minutes: 5)), 3, reason: 'with a gap: only the first download trimmed, so all three are still there');
  });
}
