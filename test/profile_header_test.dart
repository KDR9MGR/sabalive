import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/data/profile_labels_repository.dart';
import 'package:sabalive/data/store_repository.dart';
import 'package:sabalive/features/profile/widgets/profile_header.dart';
import 'package:sabalive/features/profile/widgets/profile_labels.dart';
import 'package:sabalive/features/profile/widgets/profile_vip_banner.dart';
import 'package:sabalive/features/wallet/store_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// My Profile, 2026-11-05: the VIP strip is back, and the empty block under the picture (the owner's screenshot) is gone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
  });

  group('the VIP strip', () {
    testWidgets('says VIP · Luxury Privileges, fills the width and reports a tap', (t) async {
      var taps = 0;
      await t.pumpWidget(MaterialApp(home: Scaffold(body: ProfileVipBanner(onTap: () => taps++))));
      expect(find.text('VIP  ·  Luxury Privileges'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
      final box = t.getSize(find.byType(ProfileVipBanner));
      expect(box.width, 800, reason: 'the strip takes the whole row (its own 20 px margins are inside the widget)');
      await t.tap(find.text('VIP  ·  Luxury Privileges'));
      expect(taps, 1);
      // the whole strip is the button, not just the writing
      await t.tapAt(t.getTopLeft(find.byType(ProfileVipBanner)) + const Offset(30, 8));
      expect(taps, 2);
    });
  });

  group('the Store opens on the tab it is asked for', () {
    test('the VIP category is its own tab (Lucky ID), not the first one', () {
      expect(storeTabIndex(StoreCategory.frame), 0);
      expect(storeTabIndex(StoreCategory.vip), 1);
      expect(storeTabs[storeTabIndex(StoreCategory.vip)].$2, 'Lucky ID');
    });

    test('a category the Store no longer sells (the Garage) falls back to the first tab', () {
      expect(storeTabIndex(StoreCategory.vehicle), 0);
    });
  });

  group('the header layout', () {
    const photoKey = ValueKey('photo');
    const labelsKey = ValueKey('labels');
    const levelsKey = ValueKey('levels');
    const nameKey = ValueKey('name');

    Widget header({List<Widget> pills = const [SizedBox(width: 50, height: 24)], double photo = 136, Widget? labels}) => MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: ProfileHeader(
                photo: SizedBox(key: photoKey, width: photo, height: photo),
                name: const SizedBox(key: nameKey, height: 22, width: 100),
                id: const SizedBox(height: 16, width: 90),
                pills: pills,
                labels: labels ?? const SizedBox(key: labelsKey, height: 100, width: 300),
                levels: const SizedBox(key: levelsKey, height: 26, width: 190),
              ),
            ),
          ),
        );

    testWidgets('badges and tags start under the picture, at the left edge, so no block is left empty beneath it', (t) async {
      await t.pumpWidget(header());
      final photo = t.getRect(find.byKey(photoKey));
      final labels = t.getRect(find.byKey(labelsKey));
      expect(labels.left, photo.left, reason: 'under the picture, not in a column to its right');
      expect(labels.top - photo.bottom, lessThanOrEqualTo(8), reason: 'right under it, no gap');
      expect(labels.top, greaterThanOrEqualTo(photo.bottom), reason: 'and never over it');
    });

    testWidgets('the levels follow the labels, also from the left edge', (t) async {
      await t.pumpWidget(header());
      final labels = t.getRect(find.byKey(labelsKey));
      final levels = t.getRect(find.byKey(levelsKey));
      expect(levels.left, labels.left);
      expect(levels.top, greaterThanOrEqualTo(labels.bottom));
    });

    testWidgets('the name column sits beside the picture and is centred against it', (t) async {
      await t.pumpWidget(header());
      final photo = t.getRect(find.byKey(photoKey));
      final name = t.getRect(find.byKey(nameKey));
      expect(name.left, greaterThanOrEqualTo(photo.right));
      expect(name.top, greaterThan(photo.top), reason: 'centred, so not stuck to the top of a tall picture');
      expect(name.bottom, lessThan(photo.bottom));
    });

    testWidgets('a smaller picture (no frame) works the same', (t) async {
      await t.pumpWidget(header(photo: 92));
      final photo = t.getRect(find.byKey(photoKey));
      final labels = t.getRect(find.byKey(labelsKey));
      expect(labels.left, photo.left);
      expect(labels.top - photo.bottom, lessThanOrEqualTo(8));
    });

    testWidgets('no pills, no empty gap row beside the picture, and nothing breaks', (t) async {
      await t.pumpWidget(header(pills: const []));
      expect(t.takeException(), isNull);
      expect(find.byKey(labelsKey), findsOneWidget);
    });

    testWidgets('with the real badge / tag row: six labels flow across the full width and the pills stay beside the picture (360 px phone)', (t) async {
      t.view.physicalSize = const Size(360, 780);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      ProfileTag tag(int i) => ProfileTag(id: 't$i', name: 'T$i', color: parseTagColor('#7c3aed'));
      await t.pumpWidget(header(
        labels: ProfileLabelsRow(
          key: labelsKey,
          profileId: 'p',
          loader: (_) async => ProfileLabels(tags: [for (var i = 1; i <= 6; i++) tag(i)]),
        ),
      ));
      await t.pump();
      await t.pump();
      expect(t.takeException(), isNull, reason: 'no overflow on a 360 px phone');
      final photo = t.getRect(find.byKey(photoKey));
      final labels = t.getRect(find.byKey(labelsKey));
      expect(labels.left, photo.left);
      expect(labels.width, greaterThan(200), reason: 'the row can be wider than the 176 px column that is left beside the picture');
      // the whole header is not taller than picture + labels + levels: the old layout added the full height of the labels beside the picture
      final all = t.getRect(find.byType(ProfileHeader));
      expect(all.height, lessThanOrEqualTo(photo.height + 4 + labels.height + 8 + 26 + 0.5));
    });
  });
}
