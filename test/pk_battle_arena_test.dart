import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/pk_battle_arena.dart';
import 'package:sabalive/features/live/widgets/seat_requests.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:sabalive/features/live/widgets/seat_room.dart';
import 'package:sabalive/state/pk_battle_controller.dart';

import 'helpers/pk_fakes.dart';

/// Which seats the PK arena draws (four guest seats a side, like the old PK screen), when the room's own grid steps aside, and that
/// a room only redraws when a battle starts or ends, not on every gift.
void main() {
  AppUser user(String id) => AppUser(id: id, name: 'U$id', username: '@$id');
  List<int> seatsOf(PkArenaSeats s) => [for (final x in s.shown) x.seat];

  group('pkArenaSeats', () {
    test('the host\'s own seat is the big picture, so it is never one of the seven', () {
      final s = pkArenaSeats(seatCount: 8, occupants: {1: user('host'), 2: user('a'), 3: user('b')}, hostId: 'host');
      expect(seatsOf(s), [2, 3, 4, 5, 6, 7, 8], reason: 'two guests, then the lowest free seats: a side shows up to seven');
      expect(s.hidden, 0);
    });

    test('the host can sit anywhere: that seat is left out', () {
      final s = pkArenaSeats(seatCount: 8, occupants: {3: user('host'), 1: user('a')}, hostId: 'host');
      expect(seatsOf(s), [1, 2, 4, 5, 6, 7, 8]);
    });

    test('people come first: a guest on a high seat is not hidden behind free seats', () {
      final s = pkArenaSeats(seatCount: 12, occupants: {1: user('host'), 11: user('far')}, hostId: 'host');
      expect(seatsOf(s), [2, 3, 4, 5, 6, 7, 11]);
      expect(s.shown.last.occupant?.id, 'far');
    });

    test('more guests than fit: the first seven by seat number, the rest are counted', () {
      final s = pkArenaSeats(
        seatCount: 16,
        occupants: {1: user('host'), for (var i = 2; i <= 12; i++) i: user('g\$i')},
        hostId: 'host',
      );
      expect(seatsOf(s), [2, 3, 4, 5, 6, 7, 8]);
      expect(s.hidden, 4, reason: 'eleven guests, seven shown');
    });

    test('a viewer\'s own seat is always shown, even when seven other guests sit before it', () {
      final occupants = {1: user('host'), for (var i = 2; i <= 12; i++) i: user('g\$i')};
      final s = pkArenaSeats(seatCount: 16, occupants: occupants, hostId: 'host', keep: 12);
      expect(seatsOf(s), [2, 3, 4, 5, 6, 7, 12]);
      expect(s.hidden, 4);
      // with no kept seat the same room hides seat 12
      expect(seatsOf(pkArenaSeats(seatCount: 16, occupants: occupants, hostId: 'host')), [2, 3, 4, 5, 6, 7, 8]);
      // a kept seat nobody is on changes nothing
      expect(seatsOf(pkArenaSeats(seatCount: 16, occupants: occupants, hostId: 'host', keep: 14)), [2, 3, 4, 5, 6, 7, 8]);
    });

    test('a locked seat is drawn as locked and can take one of the free places', () {
      final s = pkArenaSeats(seatCount: 8, occupants: {1: user('host')}, locked: {3}, hostId: 'host');
      expect(seatsOf(s), [2, 3, 4, 5, 6, 7, 8]);
      expect([for (final x in s.shown) x.locked], [false, true, false, false, false, false, false]);
    });

    test('a room of four seats has the host and three guest seats', () {
      final s = pkArenaSeats(seatCount: 4, occupants: {1: user('host')}, hostId: 'host');
      expect(seatsOf(s), [2, 3, 4]);
    });

    test('an older room with a guest above its seat count still shows that guest', () {
      final s = pkArenaSeats(seatCount: 4, occupants: {1: user('host'), 6: user('old')}, hostId: 'host');
      expect(seatsOf(s), [2, 3, 4, 6]);
    });

    test('without a known host every seat counts', () {
      final s = pkArenaSeats(seatCount: 8, occupants: {1: user('a')});
      expect(seatsOf(s), [1, 2, 3, 4, 5, 6, 7]);
    });

    test('no seats and no people: nothing to draw', () {
      final s = pkArenaSeats(seatCount: 0, occupants: const {});
      expect(s.shown, isEmpty);
      expect(s.hidden, 0);
    });
  });

  group('pkNextSeatCount (Add seat / Remove seat during a battle: one at a time, 4 to 8)', () {
    test('adds one up to eight, then stops', () {
      expect([for (var n = 4; n <= 8; n++) pkNextSeatCount(n, more: true)], [5, 6, 7, 8, 8]);
    });
    test('removes one down to four, then stops', () {
      expect([for (var n = 8; n >= 4; n--) pkNextSeatCount(n, more: false)], [7, 6, 5, 4, 4]);
    });
    test('a bigger room (made before the battle) comes down to eight on the first Remove and cannot grow', () {
      expect(pkNextSeatCount(12, more: false), 8);
      expect(pkNextSeatCount(16, more: false), 8);
      expect(pkNextSeatCount(12, more: true), 12);
    });
  });

  group('PkFighting', () {
    testWidgets('redraws when the 3-2-1 / the battle starts and when it ends, not on every score', (t) async {
      final now = DateTime.utc(2026, 10, 18, 12);
      final api = PkFakeApi(() => now);
      final c = PkBattleController(api: api, streamId: pkMyStream, myHostId: pkMe, clock: () => now);
      final seen = <bool>[];
      await t.pumpWidget(MaterialApp(
        home: PkFighting(
          controller: c,
          builder: (context, fighting) {
            seen.add(fighting);
            return const SizedBox();
          },
        ),
      ));
      c.start();
      await t.pump();
      expect(seen, [false]);

      api.emit(pkRow(status: 'invited'));
      await t.pump();
      expect(seen, [false], reason: 'waiting for an answer is not the arena yet');

      api.emit(pkRow(status: 'live', startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
      await t.pump();
      expect(seen, [false, true]);

      for (var seq = 1; seq <= 5; seq++) {
        api.emit(pkRow(status: 'live', scoreA: seq * 10, seq: seq, startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
        await t.pump();
      }
      expect(seen, [false, true], reason: 'five gifts, no redraw of the room');

      api.emit(pkRow(status: 'finished', scoreA: 50, winner: 'a'));
      await t.pump();
      expect(seen, [false, true, false]);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('without a controller (PK is not in this room) it is simply not fighting', (t) async {
      bool? got;
      await t.pumpWidget(MaterialApp(home: PkFighting(controller: null, builder: (_, fighting) => Text('${got = fighting}'))));
      expect(got, false);
    });
  });

  group('the arena\'s host buttons and the room skin', () {
    Future<(PkBattleController, PkFakeApi)> live(WidgetTester t, {bool iAmHost = true}) async {
      final now = DateTime.utc(2026, 10, 19, 12);
      final api = PkFakeApi(() => now);
      final c = PkBattleController(api: api, streamId: pkMyStream, myHostId: iAmHost ? pkMe : 'a-viewer', clock: () => now);
      c.start();
      await t.pump();
      api.emit(pkRow(status: 'live', scoreA: 5, scoreB: 3, startedAt: now, endsAt: now.add(const Duration(minutes: 5))));
      await t.pump();
      return (c, api);
    }

    Widget arena(PkBattleController c, {PkHostControls? controls, bool skinned = false}) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PkBattleArena(
            controller: c,
            me: AppUser(id: pkMe, name: 'Me Host', username: '@me'),
            skinned: skinned,
            fetchSeats: (_) async => null,
            mine: PkSeatsData(
              hostId: pkMe,
              seatCount: 6,
              occupants: {1: AppUser(id: pkMe, name: 'Me Host', username: '@me')},
              onSeatTap: (_) {},
              controls: controls,
            ),
          ),
        ),
      ),
    );

    void phone(WidgetTester t) {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
    }

    testWidgets('a viewer\'s arena has no buttons at all', (t) async {
      phone(t);
      final (c, _) = await live(t, iAmHost: false);
      await t.pumpWidget(arena(c));
      await t.pump();
      expect(find.byKey(const ValueKey('pk-host-controls')), findsNothing);
      expect(find.byKey(const ValueKey('pk-end')), findsNothing);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('the host: Add seat, Remove seat and Requests call back; a missing callback greys the button out', (t) async {
      phone(t);
      final (c, _) = await live(t);
      final taps = <String>[];
      await t.pumpWidget(arena(c, controls: PkHostControls(onAddSeat: () => taps.add('add'), onRemoveSeat: null, onRequests: () => taps.add('requests'), requestCount: 3)));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('pk-add-seat')));
      await t.tap(find.byKey(const ValueKey('pk-remove-seat')));
      await t.tap(find.byKey(const ValueKey('pk-requests')));
      expect(taps, ['add', 'requests'], reason: 'Remove seat had no callback');
      expect(find.descendant(of: find.byKey(const ValueKey('pk-requests')), matching: find.text('3')), findsOneWidget,
          reason: 'the number of people waiting is on the Requests button');
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('End PK asks first; Cancel keeps the battle, End PK gives up and the other host wins', (t) async {
      phone(t);
      final (c, api) = await live(t);
      await t.pumpWidget(arena(c, controls: const PkHostControls()));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('pk-end')));
      await t.pumpAndSettle();
      expect(find.text('End the PK now?'), findsOneWidget);
      expect(find.text('You give up and the other host wins. This cannot be undone.'), findsOneWidget, reason: 'it says what it does');
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(api.calls, isNot(contains('give-up')));
      expect(c.phase, PkPhase.live);

      await t.tap(find.byKey(const ValueKey('pk-end')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('pk-end-confirm')));
      await t.pumpAndSettle();
      expect(api.calls, contains('give-up'));
      expect(c.phase, PkPhase.finished);
      expect(c.result?.outcome, PkOutcome.lose);
      expect(find.byKey(const ValueKey('pk-arena')), findsNothing, reason: 'the arena goes with the battle');
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('End PK on a server that cannot do it: a message, and the battle goes on', (t) async {
      phone(t);
      final (c, api) = await live(t);
      api.giveUpError = const PostgrestException(message: 'Could not find the function public.pk_give_up_v2', code: 'PGRST202');
      await t.pumpWidget(arena(c, controls: const PkHostControls()));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('pk-end')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('pk-end-confirm')));
      await t.pumpAndSettle();
      expect(c.phase, PkPhase.live);
      expect(find.textContaining('latest update'), findsOneWidget, reason: 'shown in a snackbar');
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('End PK is not offered during the 3-2-1, only once the battle is live', (t) async {
      phone(t);
      final now = DateTime.utc(2026, 10, 19, 12);
      final api = PkFakeApi(() => now);
      final c = PkBattleController(api: api, streamId: pkMyStream, myHostId: pkMe, clock: () => now);
      c.start();
      await t.pump();
      api.emit(pkRow(status: 'accepted'));
      await t.pump();
      expect(c.phase, PkPhase.countdown);
      await t.pumpWidget(arena(c, controls: const PkHostControls()));
      await t.pump();
      expect(find.byKey(const ValueKey('pk-arena')), findsOneWidget);
      expect(find.byKey(const ValueKey('pk-end')), findsNothing);
      expect(find.byKey(const ValueKey('pk-add-seat')), findsOneWidget, reason: 'seats can be changed during the countdown');
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('with a room skin the halves let it through, without one they are solid', (t) async {
      phone(t);
      final (c, _) = await live(t);
      double alphaOfHalf() {
        final box = t.widget<DecoratedBox>(find.descendant(of: find.byKey(const ValueKey('pk-arena-mine')), matching: find.byType(DecoratedBox)).first);
        final colors = (box.decoration as BoxDecoration).gradient!.colors;
        return colors.first.a;
      }

      await t.pumpWidget(arena(c));
      await t.pump();
      expect(alphaOfHalf(), 1.0);
      await t.pumpWidget(arena(c, skinned: true));
      await t.pump();
      expect(alphaOfHalf(), lessThan(0.9));
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });
  });

  group('shouldAskForSeat', () {
    test('asks in a PK battle, or where the host switched asking on; never for the host or a room admin', () {
      expect(shouldAskForSeat(pkFighting: true, roomAsks: null, iAmModerator: false), isTrue, reason: 'a battle always asks');
      expect(shouldAskForSeat(pkFighting: false, roomAsks: true, iAmModerator: false), isTrue, reason: 'the host asked to be asked');
      expect(shouldAskForSeat(pkFighting: false, roomAsks: false, iAmModerator: false), isFalse, reason: 'switched off: self-serve');
      expect(shouldAskForSeat(pkFighting: false, roomAsks: null, iAmModerator: false), isFalse, reason: 'an older server has no setting: self-serve');
      expect(shouldAskForSeat(pkFighting: true, roomAsks: true, iAmModerator: true), isFalse, reason: 'moderators sit down');
    });
  });

  group('SeatRoom', () {
    Widget room({required bool showSeats}) => MaterialApp(
      home: Scaffold(
        body: SeatRoom(
          hostId: 'host',
          seatCount: 8,
          lockedSeats: const {},
          onSeatTap: (_) {},
          onAddSeat: () {},
          onRemoveSeat: () {},
          showSeats: showSeats,
          header: const SizedBox(height: 10, key: ValueKey('hdr')),
        ),
      ),
    );

    testWidgets('shows its seats and the Add / Remove buttons by default', (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(room(showSeats: true));
      expect(find.byType(SeatGrid), findsOneWidget);
      expect(find.text('Add 4'), findsOneWidget);
      expect(find.byKey(const ValueKey('hdr')), findsOneWidget);
    });

    testWidgets('while the arena is on, the grid and the buttons step aside and the header stays', (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(room(showSeats: false));
      expect(find.byType(SeatGrid), findsNothing);
      expect(find.text('Add 4'), findsNothing);
      expect(find.byKey(const ValueKey('hdr')), findsOneWidget);
    });

    testWidgets('the host\'s Requests button is there only when the room has a list, with the number waiting', (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      var opened = 0;
      Widget withRequests(VoidCallback? onRequests, int count) => MaterialApp(
        home: Scaffold(
          body: SeatRoom(
            hostId: 'host',
            seatCount: 8,
            lockedSeats: const {},
            onSeatTap: (_) {},
            onAddSeat: () {},
            onRemoveSeat: () {},
            onRequests: onRequests,
            requestCount: count,
          ),
        ),
      );
      await t.pumpWidget(withRequests(null, 0));
      expect(find.text('Requests'), findsNothing, reason: 'an older server: no list');
      await t.pumpWidget(withRequests(() => opened++, 3));
      expect(find.text('Requests'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      await t.tap(find.text('Requests'));
      expect(opened, 1);
    });
  });
}
