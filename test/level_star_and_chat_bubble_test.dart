import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/widgets/level_star.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/live_chat_bubble.dart';

AppUser user({int wealth = 1, int charm = 1}) => AppUser(
      id: 'u1',
      name: 'Riya',
      username: '@riya',
      wealthLevel: wealth,
      charmLevel: charm,
    );

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  group('AppUser levels', () {
    test('reads the wealth and charm tracks from a profile row', () {
      final u = AppUser.fromRow({
        'id': 'a',
        'name': 'A',
        'username': 'a',
        'level': 13,
        'wealth_level': 13,
        'charm_level': 11,
      });
      expect((u.level, u.wealthLevel, u.charmLevel), (13, 13, 11));
    });

    test('defaults to level 1 when the columns are missing', () {
      final u = AppUser.fromRow({'id': 'a', 'name': 'A', 'username': 'a'});
      expect((u.wealthLevel, u.charmLevel), (1, 1));
    });
  });

  group('LevelStar', () {
    testWidgets('wealth star shows its level and is announced as Wealth',
        (t) async {
      final semantics = t.ensureSemantics();
      await t.pumpWidget(wrap(const LevelStar.wealth(level: 12)));
      expect(find.text('12'), findsOneWidget);
      expect(find.bySemanticsLabel('Wealth level 12'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('charm star shows its level and is announced as Charm',
        (t) async {
      final semantics = t.ensureSemantics();
      await t.pumpWidget(wrap(
          const LevelStar.charm(level: 7, shimmer: StarShimmer.none)));
      expect(find.text('7'), findsOneWidget);
      expect(find.bySemanticsLabel('Charm level 7'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a 3-digit level still fits inside the star', (t) async {
      await t.pumpWidget(wrap(const LevelStar.wealth(level: 100, size: 16)));
      expect(find.text('100'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('the shimmer animates without errors and disposes cleanly',
        (t) async {
      await t.pumpWidget(wrap(const LevelStar.charm(level: 9)));
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 2));
      await t.pumpWidget(const SizedBox()); // unmount while the loop is running
      expect(t.takeException(), isNull);
    });
  });

  group('LiveChatLineBubble', () {
    testWidgets('an ordinary message: name and text, no stars', (t) async {
      await t.pumpWidget(wrap(LiveChatLineBubble(
        line: LiveChatLine(user(), 'hello everyone'),
      )));
      expect(find.textContaining('Riya', findRichText: true), findsOneWidget);
      expect(find.textContaining('hello everyone', findRichText: true),
          findsOneWidget);
      expect(find.byType(LevelStar), findsNothing);
    });

    testWidgets(
        'a join notice shows the name, both level stars and "joined"',
        (t) async {
      await t.pumpWidget(wrap(LiveChatLineBubble(
        key: const ValueKey('a'),
        line: LiveChatLine(user(wealth: 12, charm: 7), 'joined the live stream',
            system: true),
      )));
      await t.pump(const Duration(seconds: 2)); // let the one-off shine finish

      expect(find.text('Riya'), findsOneWidget);
      expect(find.byType(LevelStar), findsNWidgets(2));
      expect(find.text('12'), findsOneWidget); // wealth (gold)
      expect(find.text('7'), findsOneWidget); // charm (purple)
      expect(find.textContaining('joined', findRichText: true), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('a "left" notice is NOT given the join styling', (t) async {
      await t.pumpWidget(wrap(LiveChatLineBubble(
        line: LiveChatLine(user(wealth: 12, charm: 7), 'left the live stream',
            system: true),
      )));
      expect(find.byType(LevelStar), findsNothing);
    });

    test('isJoin is true only for system "joined" lines', () {
      expect(LiveChatLine(user(), 'joined the live stream', system: true).isJoin,
          isTrue);
      expect(LiveChatLine(user(), 'left the live stream', system: true).isJoin,
          isFalse);
      expect(LiveChatLine(user(), 'joined my birthday!').isJoin, isFalse,
          reason: 'a normal message that starts with "joined" is not a notice');
    });

    testWidgets('a pinned message keeps its pin', (t) async {
      await t.pumpWidget(wrap(LiveChatLineBubble(
        line: LiveChatLine(user(), 'rules: be kind', pinned: true),
      )));
      expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
    });
  });
}
