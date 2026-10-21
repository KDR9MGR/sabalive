import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/widgets/level_star.dart';
import 'package:sabalive/data/level_banner_images.dart';
import 'package:sabalive/data/level_images.dart';

/// The panel's level pictures replacing the stars: which levels get one, what stays a star, and what the chip does while the picture loads or fails.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const png = 'https://x.supabase.co/storage/v1/object/public/gift-assets/levels/2.png';
  const webp = 'https://x.supabase.co/storage/v1/object/public/gift-assets/levels/3.webp';
  const svga = 'https://x.supabase.co/storage/v1/object/public/gift-assets/levels/4.svga';
  const mp4 = 'https://x.supabase.co/storage/v1/object/public/gift-assets/levels/5.mp4';

  setUp(() => LevelImageStore.instance.reset());
  tearDown(() => LevelImageStore.instance.reset());

  group('LevelImageStore', () {
    test('a picture belongs to exactly its own level and track', () async {
      final store = LevelImageStore(loader: () async => [
            const LevelBannerStep('wealth', 2, png),
            const LevelBannerStep('charm', 3, webp),
          ]);
      await store.ensureLoaded();
      expect(store.urlFor('wealth', 2), png);
      expect(store.urlFor('charm', 3), webp);
      expect(store.urlFor('charm', 2), isNull, reason: 'a different track');
      expect(store.urlFor('wealth', 5), isNull, reason: 'a level above does NOT borrow the picture of a lower one');
      expect(store.urlFor('wealth', 1), isNull);
    });

    test('animated files (SVGA, MP4) keep the star', () async {
      final store = LevelImageStore(loader: () async => [
            const LevelBannerStep('wealth', 2, png),
            const LevelBannerStep('wealth', 4, svga),
            const LevelBannerStep('charm', 5, mp4),
          ]);
      await store.ensureLoaded();
      expect(store.urlFor('wealth', 2), png);
      expect(store.urlFor('wealth', 4), isNull);
      expect(store.urlFor('charm', 5), isNull);
    });

    test('listeners are told when the pictures arrive, not when nothing changed', () async {
      var told = 0;
      final store = LevelImageStore(loader: () async => [const LevelBannerStep('wealth', 2, png)])..addListener(() => told++);
      await store.ensureLoaded();
      expect(told, 1);
      store.usePictures({'wealth:2': png});
      expect(told, 1, reason: 'the same pictures');
    });

    test('it asks once, then not again until the read is old', () async {
      var asked = 0;
      final store = LevelImageStore(loader: () async {
        asked++;
        return [const LevelBannerStep('wealth', 2, png)];
      });
      await store.ensureLoaded();
      await store.ensureLoaded();
      await Future.wait([store.ensureLoaded(), store.ensureLoaded()]);
      expect(asked, 1);
    });

    test('a failed or empty read keeps the stars and does not throw; a later read can still succeed', () async {
      var mode = 0;
      final store = LevelImageStore(loader: () async {
        mode++;
        if (mode == 1) return null; // could not be read
        if (mode == 2) throw Exception('offline');
        return [const LevelBannerStep('wealth', 2, png)];
      });
      await store.ensureLoaded();
      expect(store.urlFor('wealth', 2), isNull);
      await store.ensureLoaded();
      expect(store.urlFor('wealth', 2), isNull);
      await store.ensureLoaded();
      expect(store.urlFor('wealth', 2), png, reason: 'a failure is not remembered');
    });

    test('a level whose picture is removed in the panel goes back to the star', () async {
      var rows = [const LevelBannerStep('wealth', 2, png)];
      final store = LevelImageStore(loader: () async => rows);
      await store.ensureLoaded();
      expect(store.urlFor('wealth', 2), png);
      store.reset();
      rows = [];
      await store.ensureLoaded();
      expect(store.urlFor('wealth', 2), isNull);
    });
  });

  group('the chip', () {
    Future<void> show(WidgetTester t, Widget child) =>
        t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: child))));

    // a 1x1 PNG, enough for Image.file to decode
    final bytes = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

    testWidgets('a level with no picture is the star with its number', (t) async {
      await show(t, const LevelStar.wealth(level: 12));
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.byType(LevelPicture), findsNothing);
    });

    testWidgets('a level with a picture uses LevelPicture, and the star shows until the picture is on the phone', (t) async {
      LevelImageStore.instance.usePictures({'wealth:2': png});
      await show(t, const LevelStar.wealth(level: 2));
      expect(find.byType(LevelPicture), findsOneWidget);
      expect(find.byIcon(Icons.star_rounded), findsOneWidget, reason: 'nothing on the phone yet: the star stands in');
    });

    testWidgets('a level next to it without a picture keeps its star', (t) async {
      LevelImageStore.instance.usePictures({'wealth:2': png});
      await show(t, const LevelStars(wealth: 2, charm: 7));
      expect(find.byType(LevelStar), findsNWidgets(2));
      expect(find.byType(LevelPicture), findsOneWidget, reason: 'wealth level 2 has a picture, charm level 7 has none');
      expect(find.text('7'), findsOneWidget, reason: 'the charm star keeps its number');
      expect(find.text('2'), findsOneWidget, reason: 'the wealth star stands in until its picture is on the phone');
    });

    testWidgets('when the picture is on the phone it replaces the star (the number is in the picture)', (t) async {
      final dir = Directory.systemTemp.createTempSync('level_pic'); // real file work is synchronous inside a widget test
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/2.png')..writeAsBytesSync(bytes);
      await show(t, LevelPicture(url: png, size: 22, fallback: const Icon(Icons.star_rounded), loader: (_) async => file));
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
      await t.pump(); // the loader has answered: the Image is built, but not decoded yet
      final image = t.widget<Image>(find.byKey(const ValueKey('level-picture')));
      expect(image.height, 22, reason: 'drawn at the chip size, at its own width');
      expect(image.fit, BoxFit.contain);
      expect(image.gaplessPlayback, isTrue);
      expect(find.byIcon(Icons.star_rounded), findsOneWidget, reason: 'still the star until the picture is decoded: no blank gap');
      // the frame builder: the star until a frame exists, then the picture (decoding itself needs the real clock, which a widget test can't give)
      final context = t.element(find.byKey(const ValueKey('level-picture')));
      const picture = SizedBox(key: ValueKey('decoded'));
      expect((image.frameBuilder!(context, picture, null, false) as Icon).icon, Icons.star_rounded);
      expect(image.frameBuilder!(context, picture, 0, false), same(picture));
      expect(image.frameBuilder!(context, picture, null, true), same(picture), reason: 'a picture that was ready at once');
      expect((image.errorBuilder!(context, Object(), null) as Icon).icon, Icons.star_rounded, reason: 'a picture that cannot be drawn');
    });

    testWidgets('a picture that cannot be fetched leaves the star', (t) async {
      await show(t, LevelPicture(url: png, size: 22, fallback: const Icon(Icons.star_rounded), loader: (_) async => null));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
      expect(find.byKey(const ValueKey('level-picture')), findsNothing);
    });

    testWidgets('a file that is not a picture leaves the star too', (t) async {
      final dir = Directory.systemTemp.createTempSync('level_pic'); // real file work is synchronous inside a widget test
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/bad.png')..writeAsStringSync('not a picture');
      await show(t, LevelPicture(url: png, size: 22, fallback: const Icon(Icons.star_rounded), loader: (_) async => file));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await t.pump();
      await t.pump();
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    });

    testWidgets('a loader that throws leaves the star', (t) async {
      await show(t, LevelPicture(url: png, size: 22, fallback: const Icon(Icons.star_rounded), loader: (_) async => throw Exception('disk full')));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    });
  });
}
