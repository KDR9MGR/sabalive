import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/pk_battle_widgets.dart';
import 'package:sabalive/features/live/widgets/seat_room.dart';
import 'package:sabalive/state/pk_battle_controller.dart';

import 'helpers/pk_fakes.dart';

/// The PK header sits above the seats of an audio room. On small phones and with many seats it must not push the room into an
/// overflow (the seats and the Add / Remove buttons stay on screen).
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

  for (final size in [const Size(320, 640), const Size(360, 740), const Size(412, 915)]) {
    for (final seats in [8, 16]) {
      testWidgets('audio PK header with $seats seats on a ${size.width.toInt()} x ${size.height.toInt()} phone: no overflow', (t) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final now = DateTime.utc(2026, 10, 17, 12);
        final c = await liveBattle(t, now);
        await t.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SeatRoom(
              hostId: pkMe,
              seatCount: seats,
              lockedSeats: const {},
              onSeatTap: (_) {},
              onAddSeat: () {},
              onRemoveSeat: () {},
              header: PkBattleHeader(controller: c, me: me),
            ),
          ),
        ));
        await t.pump();
        final overflow = t.takeException();
        // 16 seats are four rows high; with the header on a very small phone the room may need more height than the screen has:
        // report it instead of hiding it
        expect(overflow, isNull, reason: '$seats seats on ${size.width.toInt()} x ${size.height.toInt()}: $overflow');
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
