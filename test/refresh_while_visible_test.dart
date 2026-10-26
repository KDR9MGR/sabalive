import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/widgets/refresh_while_visible.dart';
import 'package:sabalive/data/models.dart';

/// The levels on My Profile come from the profile read at sign-in. They are read again while that tab is open (and only then), and a level the server changed
/// reaches the screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppUser.setLevels', () {
    test('takes the new levels and says so; the same levels change nothing', () {
      final user = AppUser(id: 'u1', name: 'A', username: '@a', wealthLevel: 41, charmLevel: 4);
      expect(user.setLevels(wealth: 41, charm: 4), isFalse);
      expect(user.setLevels(wealth: 42, charm: 4), isTrue);
      expect((user.wealthLevel, user.charmLevel), (42, 4));
      expect(user.setLevels(wealth: 42, charm: 9), isTrue);
      expect((user.wealthLevel, user.charmLevel), (42, 9));
    });
  });

  group('RefreshWhileVisible', () {
    late int calls;
    setUp(() => calls = 0);
    Future<void> count() async => calls++;

    Widget host({bool active = true, bool tickers = true, Duration every = const Duration(seconds: 30)}) => MaterialApp(
          home: TickerMode(enabled: tickers, child: RefreshWhileVisible(onRefresh: count, every: every, active: active, child: const Text('x'))),
        );

    testWidgets('reads when it first shows, then every interval, and stops when it is closed', (t) async {
      await t.pumpWidget(host());
      expect(calls, 1);
      await t.pump(const Duration(seconds: 29));
      expect(calls, 1);
      await t.pump(const Duration(seconds: 1));
      expect(calls, 2);
      await t.pump(const Duration(seconds: 30));
      expect(calls, 3);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(minutes: 5));
      expect(calls, 3);
    });

    testWidgets('a tab that is not the selected one never reads; selecting it reads at once; leaving stops it', (t) async {
      await t.pumpWidget(host(active: false));
      await t.pump(const Duration(minutes: 3));
      expect(calls, 0, reason: 'kept alive in the shell, but nobody is looking');
      await t.pumpWidget(host(active: true));
      expect(calls, 1);
      await t.pump(const Duration(seconds: 30));
      expect(calls, 2);
      await t.pumpWidget(host(active: false));
      await t.pump(const Duration(minutes: 3));
      expect(calls, 2);
    });

    testWidgets('a page opened over it pauses it, and closing that page reads again', (t) async {
      await t.pumpWidget(host());
      expect(calls, 1);
      await t.pumpWidget(host(tickers: false)); // covered by an opaque page
      await t.pump(const Duration(minutes: 3));
      expect(calls, 1);
      await t.pumpWidget(host(tickers: true));
      expect(calls, 2, reason: 'back on top: look again at once');
    });

    testWidgets('in the background nothing is read; coming back reads at once', (t) async {
      await t.pumpWidget(host());
      expect(calls, 1);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump(const Duration(minutes: 3));
      expect(calls, 1);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      expect(calls, 2);
      await t.pump(const Duration(seconds: 30));
      expect(calls, 3);
      // a brief "inactive" (a system dialog) is not the background
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await t.pump(const Duration(seconds: 30));
      expect(calls, 4);
    });

    testWidgets('a read that throws does not break the screen', (t) async {
      await t.pumpWidget(MaterialApp(home: RefreshWhileVisible(onRefresh: () async => throw Exception('offline'), child: const Text('still here'))));
      await t.pump();
      expect(find.text('still here'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
