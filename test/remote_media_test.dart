import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svga/flutter_svga.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/widgets/remote_media.dart';

/// A 10-frame, 20 fps (500 ms) animation with nothing in it — enough to drive
/// the real SVGA controller through a full play.
MovieEntity _movie() => MovieEntity()
  ..params = (MovieParams()
    ..viewBoxWidth = 100
    ..viewBoxHeight = 100
    ..fps = 20
    ..frames = 10);

const _marker = SizedBox(key: Key('fallback'), width: 4, height: 4);

void main() {
  group('mediaKindFor', () {
    test('picks the renderer from the extension, any case', () {
      expect(mediaKindFor('https://x.co/a/gift.svga'), MediaKind.svga);
      expect(mediaKindFor('https://x.co/a/gift.SVGA'), MediaKind.svga);
      expect(mediaKindFor('https://x.co/a/entry.mp4'), MediaKind.video);
      expect(mediaKindFor('https://x.co/a/entry.MP4'), MediaKind.video);
      expect(mediaKindFor('https://x.co/a/entry.webm'), MediaKind.video);
      expect(mediaKindFor('https://x.co/a/rose.webp'), MediaKind.animatedImage);
      expect(mediaKindFor('https://x.co/a/rose.gif'), MediaKind.animatedImage);
      expect(mediaKindFor('https://x.co/a/rose.GIF'), MediaKind.animatedImage);
      expect(mediaKindFor('https://x.co/a/rose.png'), MediaKind.image);
      expect(mediaKindFor('https://x.co/a/rose.jpg'), MediaKind.image);
    });

    test('ignores the query string and fragment of a signed url', () {
      expect(
        mediaKindFor('https://x.co/a/gift.svga?token=abc.mp4&t=1'),
        MediaKind.svga,
      );
      expect(mediaKindFor('https://x.co/a/entry.mp4#t=2'), MediaKind.video);
    });

    test('unknown or missing extensions are treated as images', () {
      expect(mediaKindFor('https://x.co/a/noext'), MediaKind.image);
      expect(mediaKindFor('https://x.co/a.dir/noext'), MediaKind.image);
      expect(mediaKindFor(''), MediaKind.image);
    });
  });

  group('SVGA', () {
    testWidgets('shows the fallback while loading, then the animation', (
      t,
    ) async {
      await t.pumpWidget(
        MaterialApp(
          home: RemoteMedia(
            'https://x.co/g.svga',
            fallback: _marker,
            svgaLoader: (_) async => _movie(),
          ),
        ),
      );
      expect(find.byKey(const Key('fallback')), findsOneWidget);
      expect(find.byType(SVGAImage), findsNothing);

      await t.pump();
      await t.pump();
      expect(find.byType(SVGAImage), findsOneWidget);
      expect(find.byKey(const Key('fallback')), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('a one-shot effect plays through once, then reports done', (
      t,
    ) async {
      var finished = 0;
      await t.pumpWidget(
        MaterialApp(
          home: RemoteMedia(
            'https://x.co/g.svga',
            loop: false,
            onFinished: () => finished++,
            svgaLoader: (_) async => _movie(),
          ),
        ),
      );
      await t.pump();
      await t.pump();
      expect(finished, 0);
      await t.pump(const Duration(milliseconds: 250));
      expect(finished, 0, reason: 'half way through, still playing');
      await t.pump(const Duration(milliseconds: 400));
      await t.pump();
      expect(finished, 1);
      await t.pump(const Duration(seconds: 2));
      expect(finished, 1, reason: 'must not fire again');
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('a looping animation keeps going and never reports done', (
      t,
    ) async {
      var finished = 0;
      await t.pumpWidget(
        MaterialApp(
          home: RemoteMedia(
            'https://x.co/g.svga',
            onFinished: () => finished++,
            svgaLoader: (_) async => _movie(),
          ),
        ),
      );
      await t.pump();
      await t.pump();
      await t.pump(const Duration(seconds: 3));
      expect(find.byType(SVGAImage), findsOneWidget);
      expect(finished, 0);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('a broken file shows the fallback and still reports done', (
      t,
    ) async {
      var finished = 0;
      await t.pumpWidget(
        MaterialApp(
          home: RemoteMedia(
            'https://x.co/g.svga',
            loop: false,
            fallback: _marker,
            onFinished: () => finished++,
            svgaLoader: (_) async => throw Exception('404'),
          ),
        ),
      );
      await t.pump();
      await t.pump();
      expect(find.byKey(const Key('fallback')), findsOneWidget);
      expect(find.byType(SVGAImage), findsNothing);
      expect(finished, 1, reason: 'a failed effect must never block the queue');
    });

    testWidgets('leaving the screen mid-load does not throw', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: RemoteMedia(
            'https://x.co/g.svga',
            svgaLoader: (_) async {
              await Future<void>.delayed(const Duration(milliseconds: 50));
              return _movie();
            },
          ),
        ),
      );
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(milliseconds: 100));
      expect(t.takeException(), isNull);
    });

    testWidgets('changing the url loads the new file', (t) async {
      final loaded = <String>[];
      Widget build(String url) => MaterialApp(
        home: RemoteMedia(
          url,
          svgaLoader: (u) async {
            loaded.add(u);
            return _movie();
          },
        ),
      );
      await t.pumpWidget(build('https://x.co/a.svga'));
      await t.pump();
      await t.pumpWidget(build('https://x.co/b.svga'));
      await t.pump();
      await t.pump();
      expect(loaded, ['https://x.co/a.svga', 'https://x.co/b.svga']);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('video', () {
    testWidgets('an unplayable file falls back and still reports done', (
      t,
    ) async {
      // No video platform exists under flutter_test, so initialize() fails —
      // the same path a corrupt or unreachable mp4 takes on a device.
      var finished = 0;
      await t.pumpWidget(
        MaterialApp(
          home: RemoteMedia(
            'https://x.co/e.mp4',
            loop: false,
            fallback: _marker,
            onFinished: () => finished++,
          ),
        ),
      );
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump();
      expect(find.byKey(const Key('fallback')), findsOneWidget);
      expect(finished, 1);
    });
  });

  group('image', () {
    testWidgets('a file that fails to load shows the fallback and reports done', (
      t,
    ) async {
      var finished = 0;
      await t.pumpWidget(
        MaterialApp(
          home: RemoteMedia(
            'https://x.co/none.png',
            fallback: _marker,
            onFinished: () => finished++,
          ),
        ),
      );
      // flutter_test serves HTTP 400 for every request, so this is the error path.
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump();
      await t.pump();
      expect(find.byKey(const Key('fallback')), findsOneWidget);
      expect(finished, 1);
    });
  });

  group('GIF / WebP pacing', () {
    test('frames that ask for almost no time are slowed to 100 ms', () {
      expect(normalizedFrameDelay(Duration.zero), const Duration(milliseconds: 100));
      expect(normalizedFrameDelay(const Duration(milliseconds: 10)), const Duration(milliseconds: 100));
      expect(normalizedFrameDelay(const Duration(milliseconds: 19)), const Duration(milliseconds: 100));
    });

    test('real delays are left alone', () {
      expect(normalizedFrameDelay(const Duration(milliseconds: 20)), const Duration(milliseconds: 20));
      expect(normalizedFrameDelay(const Duration(milliseconds: 80)), const Duration(milliseconds: 80));
      expect(normalizedFrameDelay(const Duration(seconds: 1)), const Duration(seconds: 1));
    });

    int idOf(WidgetTester t) =>
        identityHashCode(t.widget<RawImage>(find.byType(RawImage)).image);

    // Decoding an image is real async work (outside the fake clock) while the
    // frame timer runs on the fake clock — so each step lets time pass, then
    // gives the decoder a moment, then rebuilds.
    Future<void> real(WidgetTester t, int ms) =>
        t.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
    Future<void> advance(WidgetTester t, int fakeMs) async {
      await t.pump(Duration(milliseconds: fakeMs));
      await real(t, 40);
      await t.pump();
    }

    testWidgets('a 0 ms-per-frame GIF advances at ~100 ms, not as fast as it can', (t) async {
      await t.pumpWidget(MaterialApp(
        home: RemoteMedia('https://x.co/a.gif', imageLoader: (_) async => _twoFrameGif(), fallback: _marker),
      ));
      await real(t, 60);
      await t.pump();
      expect(find.byType(RawImage), findsOneWidget);
      final first = idOf(t);
      await advance(t, 50);
      expect(idOf(t), first, reason: 'still on frame 1 at 50 ms (a raw 0 ms delay would already have moved on)');
      await advance(t, 80);
      expect(idOf(t), isNot(first), reason: 'on frame 2 after ~100 ms');
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('a one-shot GIF reports done once, after its last frame', (t) async {
      var finished = 0;
      await t.pumpWidget(MaterialApp(
        home: RemoteMedia('https://x.co/a.gif', loop: false, onFinished: () => finished++, imageLoader: (_) async => _twoFrameGif()),
      ));
      await real(t, 60);
      await t.pump();
      expect(finished, 0, reason: 'frame 1 is up, frame 2 still to come');
      await advance(t, 120);
      await advance(t, 10); // let the second frame's decode land
      expect(finished, 1);
      await advance(t, 500);
      expect(finished, 1, reason: 'never again');
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('a thumbnail (animate: false) shows the first frame and stays put', (t) async {
      await t.pumpWidget(MaterialApp(
        home: RemoteMedia('https://x.co/a.gif', animate: false, imageLoader: (_) async => _twoFrameGif()),
      ));
      await real(t, 60);
      await t.pump();
      final first = idOf(t);
      await advance(t, 400);
      expect(idOf(t), first);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('a file that cannot be read shows the fallback and reports done', (t) async {
      var errors = 0;
      var finished = 0;
      await t.pumpWidget(MaterialApp(
        home: RemoteMedia(
          'https://x.co/a.gif',
          loop: false,
          fallback: _marker,
          onError: () => errors++,
          onFinished: () => finished++,
          imageLoader: (_) async => throw Exception('404'),
        ),
      ));
      await real(t, 40);
      await t.pump();
      expect(find.byKey(const Key('fallback')), findsOneWidget);
      expect(errors, 1);
      expect(finished, 1);
    });
  });
}

/// A real 2-frame GIF (1x1: red, then blue) whose frames both ask for a 0 ms
/// delay — the kind that plays too fast when taken literally.
Uint8List _twoFrameGif() => Uint8List.fromList([
  0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // GIF89a
  0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, // 1x1, 2-colour global table
  0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, // red, blue
  0x21, 0xFF, 0x0B, 0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45, 0x32, 0x2E, 0x30,
  0x03, 0x01, 0x00, 0x00, 0x00, // loop forever
  0x21, 0xF9, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, // frame 1: delay 0
  0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
  0x02, 0x02, 0x44, 0x01, 0x00, // pixel = colour 0
  0x21, 0xF9, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, // frame 2: delay 0
  0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
  0x02, 0x02, 0x4C, 0x01, 0x00, // pixel = colour 1
  0x3B,
]);
