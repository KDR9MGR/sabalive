import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/widgets/level_star.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/rankings/rankings_screen.dart';

// The old combined level (12) must not be what a Rankings row shows: Hosts show Charm, Gifters show Wealth.
final person = AppUser(id: 'u1', name: 'Riya', username: '@riya', level: 12, wealthLevel: 7, charmLevel: 3);

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('Hosts board (0) shows the Charm level', (t) async {
    await t.pumpWidget(wrap(rankingLevelStar(board: 0, user: person)));
    final star = t.widget<LevelStar>(find.byType(LevelStar));
    expect((star.kind, star.level), (LevelStarKind.charm, 3));
  });

  testWidgets('Gifters board (1) shows the Wealth level', (t) async {
    await t.pumpWidget(wrap(rankingLevelStar(board: 1, user: person)));
    final star = t.widget<LevelStar>(find.byType(LevelStar));
    expect((star.kind, star.level), (LevelStarKind.wealth, 7));
  });

  testWidgets('the same person shows the same level in every period: the period is not an input', (t) async {
    for (final board in [0, 1]) {
      final a = rankingLevelStar(board: board, user: person);
      final b = rankingLevelStar(board: board, user: person);
      expect((a as LevelStar).level, (b as LevelStar).level);
    }
  });
}
