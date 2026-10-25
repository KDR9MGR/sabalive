import 'package:flutter/material.dart' hide Text;
import 'package:flutter/widgets.dart' as w;
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/core/i18n/text.dart';
import 'package:sabalive/core/media/disk_cached_image.dart';
import 'package:sabalive/data/profile_labels_repository.dart';
import 'package:sabalive/features/profile/widgets/profile_labels.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The staff tags and the earned badges a profile shows under the name.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
  });

  group('reading a tag', () {
    test('a full row', () {
      final t = ProfileTag.fromRow({'id': 't1', 'name': '  Official ', 'color': '#FF2D55', 'emoji': '✔️'})!;
      expect(t.name, 'Official');
      expect(t.color, const Color(0xFFFF2D55));
      expect(t.emoji, '✔️');
    });

    test('a blank emoji is no emoji; a bad colour is the default purple', () {
      final t = ProfileTag.fromRow({'id': 't1', 'name': 'Fan', 'color': 'red', 'emoji': '  '})!;
      expect(t.emoji, isNull);
      expect(t.color, const Color(0xFF7C3AED));
    });

    test('a row without an id or a name is dropped', () {
      expect(ProfileTag.fromRow(null), isNull);
      expect(ProfileTag.fromRow({'name': 'No id'}), isNull);
      expect(ProfileTag.fromRow({'id': 't1', 'name': '   '}), isNull);
      expect(ProfileTag.fromRow({'id': 't1', 'name': 5}), isNull);
    });

    test('the three looks are read from the row; a picture look with no picture is a pill', () {
      const url = 'https://x.supabase.co/storage/v1/object/public/gift-assets/tags/a.png';
      final pic = ProfileTag.fromRow({'id': 't', 'name': 'Viscount', 'color': '#112233', 'look': 'picture', 'image_url': url})!;
      expect((pic.look, pic.imageUrl), (TagLook.picture, url));
      final plate = ProfileTag.fromRow({'id': 't', 'name': 'Sahi BDM', 'color': '#118833', 'look': 'plate', 'image_url': url, 'text_color': '#FFEE88'})!;
      expect((plate.look, plate.textColor), (TagLook.plate, const Color(0xFFFFEE88)));
      expect(ProfileTag.fromRow({'id': 't', 'name': 'X', 'look': 'picture', 'image_url': '  '})!.look, TagLook.pill);
      expect(ProfileTag.fromRow({'id': 't', 'name': 'X', 'look': 'banner', 'image_url': url})!.look, TagLook.pill, reason: 'an unknown look');
      expect(ProfileTag.fromRow({'id': 't', 'name': 'X'})!.look, TagLook.pill, reason: 'a server without the look column');
      expect(ProfileTag.fromRow({'id': 't', 'name': 'X', 'text_color': 'nope'})!.textColor, const Color(0xFF7C3AED), reason: 'unreadable falls back like any colour');
    });

    test('parseTagColor takes #rrggbb with or without the hash and nothing else', () {
      expect(parseTagColor('#00ff88'), const Color(0xFF00FF88));
      expect(parseTagColor('00ff88'), const Color(0xFF00FF88));
      expect(parseTagColor('#0f8'), const Color(0xFF7C3AED));
      expect(parseTagColor(null), const Color(0xFF7C3AED));
      expect(parseTagColor('#gggggg'), const Color(0xFF7C3AED));
    });
  });

  group('the row on a profile', () {
    ProfileTag tag(String id, String name, {String color = '#7c3aed', String? emoji}) =>
        ProfileTag(id: id, name: name, color: parseTagColor(color), emoji: emoji);
    ProfileBadge badge(String id, String name) => ProfileBadge(id: id, name: name, emoji: '🏅');


    /// The picture is fetched through the phone's file cache and the test network refuses it, which takes a little real time: wait until [text] shows.
    Future<void> waitFor(WidgetTester t, String text) async {
      for (var i = 0; i < 30 && find.text(text).evaluate().isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await t.pump();
      }
    }

    Future<void> show(WidgetTester t, Future<ProfileLabels> Function(String) loader, {String id = 'p1', VoidCallback? onBadgesTap}) =>
        t.pumpWidget(MaterialApp(home: Scaffold(body: ProfileLabelsRow(profileId: id, loader: loader, onBadgesTap: onBadgesTap))));

    testWidgets('badges first, then tags', (t) async {
      await show(t, (_) async => ProfileLabels(tags: [tag('t1', 'Official', emoji: '✔️')], badges: [badge('b1', 'Event Winner')]));
      await t.pump();
      expect(find.text('✔️ Official'), findsOneWidget);
      expect(find.text('Event Winner'), findsOneWidget);
      expect(find.text('🏅'), findsOneWidget, reason: 'a badge with no picture shows its emoji');
      expect(t.getTopLeft(find.byKey(const ValueKey('badge-b1'))).dx, lessThan(t.getTopLeft(find.byKey(const ValueKey('tag-t1'))).dx));
    });

    testWidgets('a badge with an uploaded picture (still, GIF / WebP, SVGA) is the picture itself; a video file or no picture is the emoji chip', (t) async {
      await show(t, (_) async => const ProfileLabels(badges: [
            ProfileBadge(id: 'png', name: 'Star', emoji: '⭐', iconUrl: 'https://example.com/star.png'),
            ProfileBadge(id: 'svga', name: 'Crown', emoji: '👑', iconUrl: 'https://example.com/crown.svga'),
            ProfileBadge(id: 'mp4', name: 'Fire', emoji: '🔥', iconUrl: 'https://example.com/fire.mp4'),
          ]));
      await t.pump();
      expect(find.byKey(const ValueKey('badge-icon-png')), findsOneWidget);
      expect(find.text('Star'), findsNothing, reason: 'the picture carries the name');
      expect(find.byKey(const ValueKey('badge-icon-svga')), findsOneWidget, reason: 'an SVGA badge is drawn as uploaded (its chip stands in while it loads)');
      expect(find.byKey(const ValueKey('badge-icon-mp4')), findsNothing, reason: 'a video file is not drawn on a profile');
      expect(find.text('Crown'), findsOneWidget, reason: 'the stand-in chip while the SVGA is read');
      expect(find.text('👑'), findsOneWidget);
      expect(find.text('Fire'), findsOneWidget);
      await waitFor(t, 'Star'); // the test network refuses the picture: the chip takes over, the badge never vanishes
      expect(find.text('Star'), findsOneWidget);
      expect(find.text('⭐'), findsOneWidget);
    });

    group('the three looks on screen', () {
      const url = 'https://x.supabase.co/storage/v1/object/public/gift-assets/tags/a.png';
      bool isTagImage(Widget w) {
        if (w is! Image) return false;
        final p = w.image;
        final inner = p is ResizeImage ? p.imageProvider : p; // pictures are decoded at the size they are drawn
        return inner is DiskCachedNetworkImage && inner.url == url;
      }

      Future<void> one(WidgetTester t, ProfileTag tag) =>
          t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: TagPill(tag: tag)))));

      testWidgets('a picture tag shows its picture; if the picture cannot load it becomes the pill, so the tag never vanishes', (t) async {
        await one(t, const ProfileTag(id: 'p', name: 'Viscount', color: Color(0xFF112233), look: TagLook.picture, imageUrl: url));
        expect(find.byWidgetPredicate(isTagImage), findsOneWidget);
        expect(find.text('Viscount'), findsNothing, reason: 'the name is inside the picture, nothing is written over it');
        await waitFor(t, 'Viscount'); // the test network refuses the file
        expect(find.text('Viscount'), findsOneWidget, reason: 'the pill takes over');
      });

      testWidgets('a plate tag writes the name over the background picture, white unless the panel set a colour', (t) async {
        await one(t, const ProfileTag(id: 'p', name: 'Sahi BDM', color: Color(0xFF118833), look: TagLook.plate, imageUrl: url));
        expect(find.byWidgetPredicate(isTagImage), findsOneWidget);
        expect((t.widget<w.Text>(find.text('Sahi BDM')).style)!.color, Colors.white);
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await t.pump();
        expect(find.text('Sahi BDM'), findsOneWidget, reason: 'the name stays when the picture fails');
        await one(t, const ProfileTag(id: 'p', name: 'Sahi BDM', color: Color(0xFF118833), look: TagLook.plate, imageUrl: url, textColor: Color(0xFFFFEE88)));
        expect((t.widget<w.Text>(find.text('Sahi BDM')).style)!.color, const Color(0xFFFFEE88));
      });

      testWidgets('a pill uses the panel\'s text colour when there is one', (t) async {
        await one(t, const ProfileTag(id: 'p', name: 'Fan', color: Color(0xFF7C3AED), textColor: Color(0xFF00FF88)));
        expect((t.widget<w.Text>(find.text('Fan')).style)!.color, const Color(0xFF00FF88));
      });

      testWidgets('a picture look is as tall as the tag row expects', (t) async {
        await one(t, const ProfileTag(id: 'p', name: 'Sahi BDM', color: Color(0xFF118833), look: TagLook.plate, imageUrl: url));
        expect(t.getSize(find.byKey(const ValueKey('tag-p'))).height, kTagPictureHeight);
      });
    });

    testWidgets('a person with nothing shows nothing at all', (t) async {
      await show(t, (_) async => const ProfileLabels());
      await t.pump();
      expect(find.byKey(const ValueKey('profile-labels')), findsNothing);
    });

    testWidgets('while it loads, and when the read fails, nothing is drawn', (t) async {
      await show(t, (_) async => throw Exception('offline'));
      expect(find.byKey(const ValueKey('profile-labels')), findsNothing);
      await t.pump();
      expect(find.byKey(const ValueKey('profile-labels')), findsNothing);
    });

    testWidgets('more than six of a kind collapse into +N', (t) async {
      await show(t, (_) async => ProfileLabels(
            tags: [for (var i = 0; i < 8; i++) tag('t$i', 'Tag $i')],
            badges: [for (var i = 0; i < 7; i++) badge('b$i', 'Badge $i')],
          ));
      await t.pump();
      expect(find.byKey(const ValueKey('tag-t5')), findsOneWidget);
      expect(find.byKey(const ValueKey('tag-t6')), findsNothing);
      expect(find.byKey(const ValueKey('badge-b5')), findsOneWidget);
      expect(find.byKey(const ValueKey('badge-b6')), findsNothing);
      expect(find.text('+2'), findsOneWidget, reason: 'two tags hidden');
      expect(find.text('+1'), findsOneWidget, reason: 'one badge hidden');
    });

    testWidgets('tapping a badge or its +N opens the badges page', (t) async {
      var taps = 0;
      await show(t, (_) async => ProfileLabels(badges: [for (var i = 0; i < 7; i++) badge('b$i', 'Badge $i')]), onBadgesTap: () => taps++);
      await t.pump();
      await t.tap(find.byKey(const ValueKey('badge-b0')));
      await t.tap(find.text('+1'));
      expect(taps, 2);
    });

    testWidgets('text is white on a dark tag and dark on a light one', (t) async {
      await show(t, (_) async => ProfileLabels(tags: [tag('dark', 'Dark', color: '#111133'), tag('light', 'Light', color: '#ffee88')]));
      await t.pump();
      Color colorOf(String text) => (t.widget<w.Text>(find.text(text)).style)!.color!;
      expect(colorOf('Dark'), Colors.white);
      expect(colorOf('Light'), const Color(0xFF1B1030));
    });

    testWidgets('another person on the same screen is read again', (t) async {
      final asked = <String>[];
      Future<ProfileLabels> loader(String id) async {
        asked.add(id);
        return ProfileLabels(tags: [tag('t-$id', 'Tag of $id')]);
      }

      await show(t, loader, id: 'a');
      await t.pump();
      expect(find.text('Tag of a'), findsOneWidget);
      await show(t, loader, id: 'b');
      await t.pump();
      expect(asked, ['a', 'b']);
      expect(find.text('Tag of a'), findsNothing);
      expect(find.text('Tag of b'), findsOneWidget);
    });
  });
}
