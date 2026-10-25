import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_svga/flutter_svga.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/core/i18n/text.dart';
import 'package:sabalive/core/widgets/label_picture.dart';
import 'package:sabalive/core/widgets/remote_media.dart' show SvgaLoader;
import 'package:sabalive/data/badges_repository.dart';
import 'package:sabalive/features/profile/badges_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Badge and tag pictures as the panel uploaded them: still, GIF / WebP and SVGA, with the emoji only when there is none.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
  });

  const png = 'https://x.supabase.co/storage/v1/object/public/gift-assets/badges/king.png';
  const svga = 'https://x.supabase.co/storage/v1/object/public/gift-assets/badges/king.svga';
  const mp4 = 'https://x.supabase.co/storage/v1/object/public/gift-assets/badges/king.mp4';

  group('sizes', () {
    test('a picture keeps its own proportions at the given height, capped and never absurd', () {
      expect(labelPictureWidth(26, 400, 100), 104, reason: '4:1 banner');
      expect(labelPictureWidth(26, 100, 100), 26, reason: 'square');
      expect(labelPictureWidth(26, 2000, 100), 160, reason: 'a very wide one is capped');
      expect(labelPictureWidth(26, 2000, 100, maxWidth: 220), 208, reason: '8:1 at most, here under the cap');
      expect(labelPictureWidth(26, 10, 1000), closeTo(7.8, 0.01), reason: 'never thinner than 0.3 x the height');
      expect(labelPictureWidth(26, 0, 0), 26, reason: 'an unknown size is a square');
    });

    test('every file kind is drawn except a video', () {
      expect(LabelPicture.supports(png), isTrue);
      expect(LabelPicture.supports(svga), isTrue);
      expect(LabelPicture.supports('https://x.co/a.gif'), isTrue);
      expect(LabelPicture.supports('https://x.co/a.webp?v=3'), isTrue);
      expect(LabelPicture.supports(mp4), isFalse);
    });
  });

  group('the widget', () {
    const stand = Text('STAND-IN', textDirection: TextDirection.ltr);
    Future<void> show(WidgetTester t, String url, {SvgaLoader? loader}) =>
        t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: LabelPicture(url: url, height: 26, fallback: stand, svgaLoader: loader)))));

    testWidgets('a still picture is drawn at the given height', (t) async {
      await show(t, png);
      expect(find.byType(Image), findsOneWidget);
      expect(t.getSize(find.byType(Image)).height, 26);
    });

    testWidgets('an SVGA shows the stand-in while it is read, and again if it cannot be read', (t) async {
      final never = Completer<MovieEntity>();
      await show(t, svga, loader: (_) => never.future);
      expect(find.text('STAND-IN'), findsOneWidget, reason: 'its size is only known once it is read');
      await show(t, '$svga?v=2', loader: (_) async => throw Exception('offline'));
      await t.pump();
      await t.pump();
      expect(find.text('STAND-IN'), findsOneWidget);
    });

    testWidgets('an SVGA that comes back as an empty movie (an error reply) is a failure: the stand-in stays at its own size', (t) async {
      await show(t, svga, loader: (_) async => MovieEntity());
      await t.pump();
      await t.pump();
      expect(find.text('STAND-IN'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('a video file is not drawn: the stand-in stays', (t) async {
      await show(t, mp4);
      expect(find.text('STAND-IN'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });
  });

  group('the Badges screen', () {
    BadgeInfo badge(String id, String name, String emoji, {String? icon, bool owned = true}) =>
        BadgeInfo(id: id, name: name, emoji: emoji, criteria: 'how to get it', owned: owned, iconUrl: icon);

    Future<void> open(WidgetTester t, List<BadgeInfo> badges) async {
      t.view.physicalSize = const Size(390, 1200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: BadgesScreen(profileId: 'p', loader: (_) async => badges)));
      await t.pump();
      await t.pump();
    }

    testWidgets('a badge with an uploaded picture shows the picture, not the emoji', (t) async {
      await open(t, [badge('b1', 'King', '🌱', icon: png), badge('b2', 'Welcome', '🎉')]);
      // the card of King
      final kingArt = find.byKey(const ValueKey('badge-art-b1'));
      expect(kingArt, findsOneWidget);
      expect(find.descendant(of: kingArt, matching: find.byType(LabelPicture)), findsOneWidget);
      expect(find.descendant(of: kingArt, matching: find.text('🌱')), findsNothing, reason: 'the random emoji is gone');
    });

    testWidgets('a badge without a picture still shows its emoji', (t) async {
      await open(t, [badge('b1', 'King', '🌱', icon: png), badge('b2', 'Welcome', '🎉')]);
      final art = find.byKey(const ValueKey('badge-art-b2'));
      expect(find.descendant(of: art, matching: find.text('🎉')), findsOneWidget);
      expect(find.descendant(of: art, matching: find.byType(LabelPicture)), findsNothing);
    });

    testWidgets('the header shows the first earned badge\'s picture too', (t) async {
      await open(t, [badge('b1', 'King', '🌱', icon: svga), badge('b2', 'Welcome', '🎉', owned: false)]);
      final header = find.byKey(const ValueKey('my-badge-art'));
      expect(find.descendant(of: header, matching: find.byType(LabelPicture)), findsOneWidget);
      expect(find.text('1 badge earned'), findsOneWidget);
    });

    testWidgets('a video file or a missing file falls back to the emoji', (t) async {
      await open(t, [badge('b1', 'King', '🌱', icon: mp4)]);
      expect(find.descendant(of: find.byKey(const ValueKey('badge-art-b1')), matching: find.text('🌱')), findsOneWidget);
    });
  });
}
