import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/pk_battle_arena.dart';
import 'package:sabalive/features/live/widgets/pk_battle_widgets.dart';
import 'package:sabalive/features/live/widgets/seat_room.dart';
import 'package:sabalive/features/live/widgets/seat_snapshot.dart';
import 'package:sabalive/state/pk_battle_controller.dart';

import 'helpers/pk_fakes.dart';

/// The PK arena replaces the seat grid of an audio room during a battle. On small phones, with both rooms full, it must not overflow
/// and must leave the lower part of the screen to the chat and the input bar.
void main() {
  final me = AppUser(id: pkMe, name: 'Me Host', username: '@me');

  Future<PkBattleController> liveBattle(WidgetTester t, DateTime now) async {
    final api = PkFakeApi(() => now);
    final c = PkBattleController(api: api, streamId: pkMyStream, myHostId: pkMe, clock: () => now);
    c.start();
    await t.pump();
    api.emit(pkRow(status: 'live', scoreA: 1200, scoreB: 800, startedAt: now, endsAt: now.add(const Duration(minutes: 40))));
    await t.pump();
    expect(c.phase, PkPhase.live);
    return c;
  }

  AppUser guest(String id) => AppUser(id: id, name: 'Guest $id', username: '@$id');

  for (final size in [const Size(320, 640), const Size(360, 740), const Size(412, 915)]) {
    for (final seats in [8, 16]) {
      testWidgets('audio PK arena with $seats seats, both rooms full, on a ${size.width.toInt()} x ${size.height.toInt()} phone: no overflow', (t) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final now = DateTime.utc(2026, 10, 17, 12);
        final c = await liveBattle(t, now);
        final mine = PkSeatsData(
          hostId: pkMe,
          seatCount: seats,
          // the host on seat 1 and guests on every other seat up to the count: more than the arena can show
          occupants: {1: me, for (var i = 2; i <= seats; i++) i: guest('m$i')},
          onSeatTap: (_) {},
        );
        await t.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SeatRoom(
              hostId: pkMe,
              seatCount: seats,
              lockedSeats: const {},
              onSeatTap: (_) {},
              onAddSeat: () {},
              onRemoveSeat: () {},
              showSeats: false,
              header: PkBattleTop(
                controller: c,
                me: me,
                mine: mine,
                fetchSeats: (_) async => SeatSnapshot(
                  occupants: {1: AppUser(id: pkOther, name: 'Opponent', username: '@o'), for (var i = 2; i <= seats; i++) i: guest('o$i')},
                  muted: {},
                  agoraUids: {},
                  seatCount: seats,
                ),
              ),
            ),
          ),
        ));
        await t.pump();
        await t.pump(const Duration(milliseconds: 50));
        expect(find.byKey(const ValueKey('pk-arena')), findsOneWidget);
        expect(find.byKey(const ValueKey('pk-arena-mine')), findsOneWidget);
        // up to seven guest seats a side (the host is the big picture), and the rest is counted
        expect(find.byWidgetPredicate((w) => w.key.toString().contains('pk-arena-seat-a-')), findsNWidgets(7));
        expect(find.byWidgetPredicate((w) => w.key.toString().contains('pk-arena-seat-b-')), findsNWidgets(7));
        expect(find.byKey(const ValueKey('pk-arena-more')), seats == 8 ? findsNothing : findsNWidgets(2),
            reason: '${seats - 1 - 7} more guests on each side');
        expect(find.text('Add 4'), findsNothing, reason: 'the room\'s seat buttons wait until the battle is over');
        final overflow = t.takeException();
        expect(overflow, isNull, reason: '$seats seats on ${size.width.toInt()} x ${size.height.toInt()}: $overflow');
        final bottom = t.getRect(find.byKey(const ValueKey('pk-arena'))).bottom;
        // seven seats a side are three short rows: on the smallest phone the arena takes more of the screen, and the room scrolls
        final limit = size.height <= 640 ? 0.82 : 0.72;
        expect(bottom, lessThan(size.height * limit), reason: 'the chat and the input bar keep the lower part of the screen');
        await t.pumpWidget(const SizedBox());
        c.dispose();
      });
    }
  }

  for (final size in [const Size(320, 640), const Size(360, 740), const Size(412, 915)]) {
    testWidgets('video PK stage on a ${size.width.toInt()} x ${size.height.toInt()} phone: no overflow, and it leaves room for the chat', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final now = DateTime.utc(2026, 10, 17, 12);
      final c = await liveBattle(t, now);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 96), // below the host's top bar, as on the live screens
              child: PkVideoStage(controller: c, me: me, left: const ColoredBox(color: Colors.red), right: const PkVideoWaiting()),
            ),
          ),
        ),
      ));
      await t.pump();
      expect(t.takeException(), isNull);
      final bottom = t.getRect(find.byKey(const ValueKey('pk-pane-left'))).bottom;
      expect(bottom, lessThan(size.height * 0.75), reason: 'the lower quarter stays free for the chat and the input bar');
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
}
