import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
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
}
