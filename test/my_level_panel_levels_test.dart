import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/widgets/level_star.dart';
import 'package:sabalive/data/level_banner_images.dart';
import 'package:sabalive/data/level_images.dart';
import 'package:sabalive/data/levels_repository.dart';
import 'package:sabalive/features/profile/my_level_screen.dart';

/// The panel's Master -> Levels page edits `track_levels` (its own XP per level for Wealth and for Charm). The My Level screen has to show THOSE numbers, not the old
/// shared catalog, or an edit made in the panel never reaches the app.
void main() {
  group('levelsFromRows', () {
    test('reads level / xp_required in level order and skips unreadable rows', () {
      final levels = levelsFromRows([
        {'level': 3, 'xp_required': 4500},
        {'level': 1, 'xp_required': 0},
        {'level': 2, 'xp_required': 500},
        {'level': 'x', 'xp_required': 1},
        {'level': 9},
        'junk',
      ]);
      expect([for (final l in levels) l.level], [1, 2, 3]);
      expect([for (final l in levels) l.xpRequired], [0, 500, 4500]);
    });

    test('nothing readable gives an empty list', () {
      expect(levelsFromRows(const []), isEmpty);
      expect(levelsFromRows([null, 5]), isEmpty);
    });
  });

  group('WealthCharmLevels.from', () {
    test('each track gets its OWN levels', () {
      final both = WealthCharmLevels.from(
        {'wealth_xp': 700, 'wealth_level': 2, 'charm_xp': 100, 'charm_level': 1},
        wealth: [LevelThreshold(1, 0), LevelThreshold(2, 500), LevelThreshold(3, 2500)],
        charm: [LevelThreshold(1, 0), LevelThreshold(2, 300)],
      );
      expect(both.wealth.thresholds.map((t) => t.xpRequired), [0, 500, 2500]);
      expect(both.charm.thresholds.map((t) => t.xpRequired), [0, 300]);
      expect(both.wealth.next?.xpRequired, 2500);
      expect(both.charm.next?.xpRequired, 300);
      expect(both.wealth.progress, closeTo(0.1, 1e-9), reason: '(700 - 500) / (2500 - 500)');
      expect(both.charm.progress, closeTo(1 / 3, 1e-9), reason: '(100 - 0) / 300');
    });
  });

  group('LevelsRepository reads the panel table', () {
    test('Wealth asks for the wealth rows and Charm for the charm rows', () async {
      final asked = <String>[];
      final repo = LevelsRepository(trackRows: (track) async {
        asked.add(track);
        return track == 'wealth'
            ? [
                {'level': 1, 'xp_required': 0},
                {'level': 2, 'xp_required': 1000}
              ]
            : [
                {'level': 1, 'xp_required': 0},
                {'level': 2, 'xp_required': 200}
              ];
      });
      // wealthAndCharm() also reads the signed-in profile (needs a session), so only the track reads are exercised here
      final wealth = await repo.trackLevelsForTest('wealth');
      final charm = await repo.trackLevelsForTest('charm');
      expect(asked, ['wealth', 'charm']);
      expect(wealth.map((t) => t.xpRequired), [0, 1000]);
      expect(charm.map((t) => t.xpRequired), [0, 200]);
    });
  });

  group('levelUnlocked', () {
    // the panel lets every level take any XP: here level 2 needs MORE than level 4
    final odd = [LevelThreshold(1, 0), LevelThreshold(2, 5000), LevelThreshold(3, 5000), LevelThreshold(4, 100)];

    test('in order: everything up to the current level is unlocked', () {
      final mine = MyLevel(3, 2500, [LevelThreshold(1, 0), LevelThreshold(2, 500), LevelThreshold(3, 2000), LevelThreshold(4, 4500)]);
      expect([for (final t in mine.thresholds) levelUnlocked(t, mine)], [true, true, true, false]);
    });

    test('out of order: a level below the current one stays locked until its XP is reached', () {
      final mine = MyLevel(4, 3000, odd);
      expect([for (final t in odd) levelUnlocked(t, mine)], [true, false, false, true]);
    });

    test('the current level is always unlocked, and a reached higher-numbered level is too', () {
      expect(levelUnlocked(LevelThreshold(5, 99999), MyLevel(5, 10, odd)), isTrue, reason: 'the server says this is their level');
      expect(levelUnlocked(LevelThreshold(2, 5000), MyLevel(4, 6000, odd)), isTrue);
    });
  });

  group('MyLevelScreen', () {
    Future<void> show(WidgetTester t, WealthCharmLevels data) async {
      await t.pumpWidget(MaterialApp(home: MyLevelScreen(loader: () async => data)));
      await t.pump();
      await t.pump();
    }

    testWidgets('lists the levels and the progress the panel set, per tab', (t) async {
      final data = WealthCharmLevels.from(
        {'wealth_xp': 700, 'wealth_level': 2, 'charm_xp': 100, 'charm_level': 1},
        wealth: [LevelThreshold(1, 0), LevelThreshold(2, 500), LevelThreshold(3, 2500)],
        charm: [LevelThreshold(1, 0), LevelThreshold(2, 300)],
      );
      await show(t, data);
      // the screen opens on Charm: two levels, the next one needs 300
      expect(find.text('Progress to Level 2'), findsOneWidget);
      expect(find.textContaining('300'), findsWidgets);
      expect(find.textContaining('2,500'), findsNothing);

      await t.tap(find.text('Wealth'));
      await t.pump();
      expect(find.text('Progress to Level 3'), findsOneWidget);
      expect(find.textContaining('2,500'), findsWidgets, reason: 'the wealth track has its own, higher level 3');
    });
  });

  group('LevelsRepository values compare by what is in them', () {
    test('the same levels and XP are equal, one changed XP is not (a refresh that changed nothing redraws nothing)', () {
      MyLevel mine(int xp, int nextXp) => MyLevel(1, xp, [LevelThreshold(1, 0), LevelThreshold(2, nextXp)]);
      expect(mine(10, 300), mine(10, 300));
      expect(mine(10, 300), isNot(mine(10, 450)), reason: 'the panel changed what level 2 needs');
      expect(mine(10, 300), isNot(mine(11, 300)), reason: 'the person earned XP');
      expect(mine(10, 300).hashCode, mine(10, 300).hashCode);
    });
  });

  group('level pictures on the screen, and staying in step with the panel', () {
    const art1 = 'https://x.supabase.co/storage/v1/object/public/gift-assets/levels/1.png';
    const art2 = 'https://x.supabase.co/storage/v1/object/public/gift-assets/levels/2.png';

    WealthCharmLevels levels({int charmXp = 100, int level2 = 300, int levels = 3}) => WealthCharmLevels.from(
          {'wealth_xp': 700, 'wealth_level': 2, 'charm_xp': charmXp, 'charm_level': 1},
          wealth: [LevelThreshold(1, 0), LevelThreshold(2, 500), LevelThreshold(3, 2500)],
          charm: [LevelThreshold(1, 0), LevelThreshold(2, level2), for (var l = 3; l <= levels; l++) LevelThreshold(l, level2 * l)],
        );

    // reads no files: the picture stays the medal, which is all a widget test can decode anyway
    Future<File?> noFile(String _) async => null;
    LevelImageStore store(List<LevelBannerStep> steps, {void Function()? onAsk}) => LevelImageStore(loader: () async {
          onAsk?.call();
          return steps;
        });

    Future<void> open(WidgetTester t, {required Future<WealthCharmLevels?> Function() loader, LevelImageStore? images, Duration every = kMyLevelRefresh}) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: MyLevelScreen(loader: loader, images: images ?? store(const []), pictureLoader: noFile, refreshEvery: every)));
      await t.pump();
      await t.pump();
    }

    Finder art(String track, int level) => find.byWidgetPredicate((w) => w is LevelPicture && w.key.toString().contains('level-art-$track-$level-'));

    testWidgets('a level the panel gave a picture shows it in its card; a level without one keeps the medal', (t) async {
      await open(t, loader: () async => levels(), images: store(const [LevelBannerStep('charm', 1, art1), LevelBannerStep('charm', 2, art2)]));
      expect(art('charm', 1), findsOneWidget);
      expect(art('charm', 2), findsOneWidget);
      expect(art('charm', 3), findsNothing);
      expect(find.byIcon(Icons.military_tech_rounded), findsWidgets, reason: 'level 3 has no picture: the medal');
    });

    testWidgets('a level that is not reached is dimmed with a lock; the level the person is at is not', (t) async {
      await open(t, loader: () async => levels(), images: store(const [LevelBannerStep('charm', 1, art1), LevelBannerStep('charm', 2, art2)]));
      expect(find.byKey(const ValueKey('level-lock-charm-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('level-lock-charm-1')), findsNothing, reason: 'it is their level');
      expect(t.widget<Opacity>(find.ancestor(of: art('charm', 2), matching: find.byType(Opacity)).first).opacity, lessThan(1));
      expect(t.widget<Opacity>(find.ancestor(of: art('charm', 1), matching: find.byType(Opacity)).first).opacity, 1);
    });

    testWidgets('the header shows the picture of the level the person is at, for the tab they are on', (t) async {
      await open(t, loader: () async => levels(), images: store(const [LevelBannerStep('charm', 1, art1), LevelBannerStep('wealth', 2, art2)]));
      expect(find.byKey(const ValueKey('my-level-art-$art1')), findsOneWidget);
      await t.tap(find.text('Wealth'));
      await t.pump();
      expect(find.byKey(const ValueKey('my-level-art-$art2')), findsOneWidget, reason: 'wealth level 2');
      expect(find.byKey(const ValueKey('my-level-art-$art1')), findsNothing);
    });

    testWidgets('only the levels on screen are built, so a hundred pictures are not all fetched at once', (t) async {
      final steps = [for (var l = 1; l <= 100; l++) LevelBannerStep('charm', l, 'https://x.supabase.co/levels/$l.png')];
      await open(t, loader: () async => levels(levels: 100), images: store(steps));
      final built = find.byType(LevelPicture).evaluate().length;
      expect(built, lessThan(20), reason: 'a lazy grid');
      expect(built, greaterThan(0));
    });

    testWidgets('XP the panel changes shows on an open screen within the refresh time, without leaving it', (t) async {
      var level2 = 300;
      var asked = 0;
      await open(t, loader: () async {
        asked++;
        return levels(level2: level2);
      });
      expect(find.text('Progress to Level 2'), findsOneWidget);
      expect(find.textContaining('300'), findsWidgets);
      expect(find.textContaining('450'), findsNothing);
      final first = asked;
      level2 = 450; // an edit in the panel's Levels page
      await t.pump(const Duration(seconds: 10));
      expect(find.textContaining('450'), findsNothing, reason: 'not asked yet: never faster than 20 seconds');
      await t.pump(const Duration(seconds: 11));
      await t.pump();
      expect(asked, first + 1);
      expect(find.textContaining('450'), findsWidgets);
      expect(find.textContaining('300 XP'), findsNothing);
    });

    testWidgets("XP the person earns shows too (the progress moves)", (t) async {
      var xp = 100;
      await open(t, loader: () async => levels(charmXp: xp));
      expect(find.text('100 XP'), findsOneWidget);
      xp = 250;
      await t.pump(kMyLevelRefresh);
      await t.pump();
      expect(find.text('250 XP'), findsOneWidget);
      expect(find.text('100 XP'), findsNothing);
    });

    testWidgets('every successful read is also handed to My Profile, so its stars never disagree with this screen', (t) async {
      final told = <(int, int)>[];
      var charmLevel = 1;
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: MyLevelScreen(
          loader: () async => WealthCharmLevels.from(
            {'wealth_xp': 700, 'wealth_level': 2, 'charm_xp': 100, 'charm_level': charmLevel},
            wealth: [LevelThreshold(1, 0), LevelThreshold(2, 500)],
            charm: [LevelThreshold(1, 0), LevelThreshold(2, 300), LevelThreshold(3, 600)],
          ),
          images: store(const []),
          pictureLoader: noFile,
          onLevels: (l) => told.add((l.wealth.level, l.charm.level)),
        ),
      ));
      await t.pump();
      await t.pump();
      expect(told, [(2, 1)]);
      charmLevel = 3; // the panel re-levelled this person
      await t.pump(kMyLevelRefresh);
      await t.pump();
      expect(told.last, (2, 3));
    });

    testWidgets('a failed or empty refresh keeps what is on screen', (t) async {
      var mode = 0;
      await open(t, loader: () async {
        mode++;
        if (mode == 2) throw Exception('offline');
        if (mode == 3) return null;
        return levels();
      });
      expect(find.text('Progress to Level 2'), findsOneWidget);
      await t.pump(kMyLevelRefresh);
      await t.pump();
      await t.pump(kMyLevelRefresh);
      await t.pump();
      expect(find.text('Progress to Level 2'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('if the first read fails it says so with Retry, and the next read fills the screen', (t) async {
      var calls = 0;
      await open(t, loader: () async {
        calls++;
        if (calls == 1) throw Exception('offline');
        return levels();
      });
      expect(find.text('Check your internet connection and try again.'), findsOneWidget);
      await t.tap(find.text('Retry'));
      await t.pump();
      await t.pump();
      expect(find.text('Progress to Level 2'), findsOneWidget);
      expect(find.text('Check your internet connection and try again.'), findsNothing);
    });

    testWidgets('pulling down reads again at once, pictures included', (t) async {
      var levelReads = 0;
      var pictureReads = 0;
      await open(
        t,
        loader: () async {
          levelReads++;
          return levels();
        },
        images: store(const [LevelBannerStep('charm', 1, art1)], onAsk: () => pictureReads++),
      );
      final levelsBefore = levelReads;
      final picturesBefore = pictureReads;
      await t.fling(find.byType(CustomScrollView), const Offset(0, 400), 1000);
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
      expect(levelReads, levelsBefore + 1);
      expect(pictureReads, picturesBefore + 1, reason: 'a pull also asks for the pictures again, even if they were read a moment ago');
    });

    testWidgets('it does not keep asking in the background, asks again when the app comes back, and stops when the screen is closed', (t) async {
      var asked = 0;
      await open(t, loader: () async {
        asked++;
        return levels();
      });
      final opened = asked;
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump(const Duration(minutes: 2));
      expect(asked, opened, reason: 'the app is in the background: nothing is read');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      expect(asked, opened + 1, reason: 'back in front: read at once');
      await t.pump(kMyLevelRefresh);
      expect(asked, opened + 2);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(minutes: 2));
      expect(asked, opened + 2, reason: 'closed: the timer is gone');
    });

    testWidgets('a read still under way is not doubled', (t) async {
      final slow = Completer<WealthCharmLevels?>();
      var asked = 0;
      await open(t, loader: () {
        asked++;
        return slow.future;
      });
      await t.pump(kMyLevelRefresh * 3);
      expect(asked, 1, reason: 'the first read has not answered: the timer does not stack more');
      slow.complete(levels());
      await t.pump();
      expect(find.text('Progress to Level 2'), findsOneWidget);
    });
  });
}
