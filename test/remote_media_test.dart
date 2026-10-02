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
      expect(mediaKindFor('https://x.co/a/rose.webp'), MediaKind.image);
      expect(mediaKindFor('https://x.co/a/rose.gif'), MediaKind.image);
      expect(mediaKindFor('https://x.co/a/rose.png'), MediaKind.image);
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
}
