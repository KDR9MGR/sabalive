import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/widgets/label_picture.dart';
import 'package:sabalive/core/widgets/remote_media.dart';

/// A plain SVG drawing uploaded in the panel (not an SVGA animation) is drawn everywhere an uploaded file is.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const svgUrl = 'https://x.supabase.co/storage/v1/object/public/gift-assets/gifts/rose.svg';
  Uint8List svg(String viewBox) => Uint8List.fromList(utf8.encode(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="$viewBox"><rect width="100" height="100" fill="#ff2d55"/><circle cx="20" cy="20" r="8" fill="#fff"/></svg>'));

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 12; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump();
    }
  }

  group('what kind a file is', () {
    test('an .svg is its own kind, apart from SVGA', () {
      expect(mediaKindFor(svgUrl), MediaKind.svg);
      expect(mediaKindFor('$svgUrl?v=3'), MediaKind.svg);
      expect(mediaKindFor('https://x/a.SVG'), MediaKind.svg);
      expect(mediaKindFor('https://x/a.svga'), MediaKind.svga);
      expect(mediaKindFor('https://x/a.png'), MediaKind.image);
      expect(mediaKindFor('https://x/a.gif'), MediaKind.animatedImage);
    });

    test('a label picture can be an SVG', () {
      expect(LabelPicture.supports(svgUrl), isTrue);
    });
  });

  group('RemoteMedia', () {
    testWidgets('draws an SVG from the file the loader returns', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 80, height: 80, child: RemoteMedia(svgUrl, imageLoader: (_) async => svg('0 0 100 100')))),
      ));
      await settle(t);
      expect(find.byType(SvgPicture), findsOneWidget);
    });

    testWidgets('shows the fallback while it loads', (t) async {
      final pending = Completer<Uint8List>();
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: RemoteMedia(svgUrl, imageLoader: (_) => pending.future, fallback: const Text('loading'))),
      ));
      await t.pump();
      expect(find.text('loading'), findsOneWidget);
      expect(find.byType(SvgPicture), findsNothing);
      await t.pumpWidget(const SizedBox());
      pending.complete(svg('0 0 10 10'));
    });

    testWidgets('a file that cannot be read shows the fallback and reports the error', (t) async {
      var errors = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RemoteMedia(svgUrl, imageLoader: (_) async => throw Exception('offline'), onError: () => errors++, fallback: const Text('stand-in')),
        ),
      ));
      await settle(t);
      expect(find.text('stand-in'), findsOneWidget);
      expect(errors, 1);
    });

    testWidgets('an empty file is a failed picture, not a blank one', (t) async {
      var errors = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: RemoteMedia(svgUrl, imageLoader: (_) async => Uint8List(0), onError: () => errors++, fallback: const Text('stand-in'))),
      ));
      await settle(t);
      expect(find.text('stand-in'), findsOneWidget);
      expect(errors, 1);
    });

    testWidgets('a file that is not an SVG (an error page) shows the fallback instead of a red box', (t) async {
      var errors = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RemoteMedia(svgUrl, imageLoader: (_) async => Uint8List.fromList(utf8.encode('<html><body>Not found</body></html>')), onError: () => errors++, fallback: const Text('stand-in')),
        ),
      ));
      await settle(t);
      expect(find.text('stand-in'), findsOneWidget);
      expect(errors, greaterThanOrEqualTo(1));
      expect(t.takeException(), isNull);
    });
  });

  group('LabelPicture', () {
    testWidgets('an SVG badge is drawn at the height asked', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Wrap(children: [
            LabelPicture(url: svgUrl, height: 34, fallback: const Text('chip'), imageLoader: (_) async => svg('0 0 200 60')),
          ]),
        ),
      ));
      await settle(t);
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(find.text('chip'), findsNothing);
      expect(t.getSize(find.byType(LabelPicture)).height, 34);
    });

    testWidgets('a broken SVG badge falls back to its chip, so a badge never vanishes', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: Wrap(children: [LabelPicture(url: svgUrl, height: 34, fallback: const Text('chip'), imageLoader: (_) async => throw Exception('gone'))])),
      ));
      await settle(t);
      expect(find.text('chip'), findsOneWidget);
    });
  });
}
