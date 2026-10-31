import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/theme/app_colors.dart';
import 'package:sabalive/features/rankings/rankings_screen.dart';

// The Rankings screen says what each board covers and when it starts again (India time). The data call fails here (no Supabase in a unit test), which
// shows the error state; the caption does not depend on the data. Pumping an empty tree afterwards also proves the once-a-minute clock check is
// cancelled when the screen goes away (a Timer left running would fail the test).
void main() {
  testWidgets(
    'the caption follows the chosen period, and the screen cleans up its timer',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: RankingsScreen()));
      await tester.pump();

      // Weekly is the board the screen opens on
      expect(
        find.text('Resets every Monday at midnight India time'),
        findsOneWidget,
      );
      expect(find.textContaining('Since '), findsOneWidget);

      await tester.tap(find.text('Monthly'));
      await tester.pump();
      expect(
        find.text('Resets on the 1st of each month at midnight India time'),
        findsOneWidget,
      );
      expect(
        find.text('Resets every Monday at midnight India time'),
        findsNothing,
      );

      await tester.tap(find.text('Daily'));
      await tester.pump();
      expect(
        find.text('Resets every day at midnight India time'),
        findsOneWidget,
      );
      expect(find.textContaining('Today, '), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the score icon: diamonds on the Hosts and Agency boards, coins on the Gifters board',
    (tester) async {
      Icon icon(int board) =>
          (rankingScoreIcon(board: board, size: 12) as Icon);
      expect(icon(0).icon, Icons.diamond_rounded);
      expect(icon(0).color, AppColors.diamond);
      expect(icon(2).icon, Icons.diamond_rounded); // Agency
      expect(icon(1).icon, Icons.monetization_on_rounded);
      expect(icon(1).color, AppColors.coin);
      expect(icon(1).size, 12);
    },
  );
}
