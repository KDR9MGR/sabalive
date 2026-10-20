import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/data/pk_battles_repository.dart';
import 'package:sabalive/features/live/widgets/pk_battle_arena.dart';
import 'package:sabalive/features/live/widgets/pk_battle_widgets.dart';
import 'package:sabalive/features/live/widgets/seat_snapshot.dart';
import 'package:sabalive/state/pk_battle_controller.dart';

import 'helpers/pk_fakes.dart';

void main() {
  usePlainPkLook();
  late DateTime now;
  late PkFakeApi api;
  late PkBattleController c;
  final me = AppUser(id: pkMe, name: 'Me Host', username: '@me');

  /// Takes the screen down first, then the controller: its timers must be gone before the test ends.
  Future<void> unmount(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    c.dispose();
  }

  Future<void> mount(WidgetTester t, {Widget? extra}) async {
    now = DateTime.utc(2026, 10, 17, 12);
    api = PkFakeApi(() => now);
    c = PkBattleController(api: api, streamId: pkMyStream, myHostId: pkMe, clock: () => now);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(child: PkBattleEvents(controller: c)),
            Align(alignment: Alignment.topCenter, child: PkBattleHeader(controller: c, me: me)),
            if (extra != null) Align(alignment: Alignment.bottomCenter, child: extra),
          ],
        ),
      ),
    ));
    c.start();
    await t.pump();
  }

  testWidgets('the setup strip draws nothing without a battle, follows the invite, and steps aside when the battle starts', (t) async {
    await mount(t);
    expect(find.byKey(const ValueKey('pk-status')), findsNothing);

    api.emit(pkRow(status: 'invited'));
    await t.pump();
    expect(find.textContaining('Waiting for'), findsOneWidget);
    expect(find.byKey(const ValueKey('pk-cancel')), findsOneWidget);

    api.emit(pkRow(status: 'live', scoreA: 120, scoreB: 80, startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    expect(find.byKey(const ValueKey('pk-status')), findsNothing, reason: 'once the battle runs, the arena or the stage shows it');
    await unmount(t);
  });

  testWidgets('the video stage shows both videos side by side under the scores and the clock, WIN on the leader', (t) async {
    t.view.physicalSize = const Size(390, 844); // a phone: two 3:4 panes side by side need a phone's width, not the default 800 x 600
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await mount(t);
    api.emit(pkRow(status: 'live', scoreA: 5, scoreB: 9, startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Padding(
            padding: pkVideoStagePadding(context),
            child: PkVideoStage(
              controller: c,
              me: me,
              left: const ColoredBox(key: ValueKey('my-video'), color: Colors.red),
              right: const PkVideoWaiting(),
            ),
          ),
        ),
      ),
    ));
    expect(find.byKey(const ValueKey('pk-clock')), findsOneWidget, reason: 'the score row with the clock is part of the stage');
    expect(find.text('PK 05:00'), findsOneWidget);
    expect(find.text('9'), findsOneWidget, reason: 'their score');
    expect(find.text('5'), findsOneWidget, reason: 'my score');
    expect(find.byKey(const ValueKey('pk-lose')), findsOneWidget, reason: 'I am behind 5 to 9');
    expect(find.byKey(const ValueKey('pk-win')), findsOneWidget);
    expect(t.getCenter(find.byKey(const ValueKey('pk-win'))).dx, greaterThan(t.getCenter(find.byKey(const ValueKey('pk-lose'))).dx),
        reason: 'WIN on the right half, where the leading opponent is');
    final left = t.getRect(find.byKey(const ValueKey('pk-pane-left')));
    final right = t.getRect(find.byKey(const ValueKey('pk-pane-right')));
    expect(left.left, lessThan(right.left));
    expect((left.width - right.width).abs(), lessThan(0.5), reason: 'two equal halves');
    final scoreBlock = t.getRect(find.byKey(const ValueKey('pk-score-block')));
    expect(scoreBlock.bottom, closeTo(844 * kPkVideoStageBottom, 1), reason: 'the stage ends at the marked line: 64 % of the screen');
    expect(scoreBlock.top, greaterThanOrEqualTo(left.bottom - 0.5), reason: 'the scores and the clock sit under the videos, not above them');
    expect(t.getRect(find.byKey(const ValueKey('pk-clock'))).top, greaterThan(left.bottom - 0.5));
    expect(left.height, greaterThan(left.width * 1.4), reason: 'tall frames, taller than the old 3:4');
    expect(find.byKey(const ValueKey('my-video')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'the opponent is still joining');
    expect(find.text('Me Host'), findsWidgets);
    await unmount(t);
  });

  testWidgets('searching shows a way to stop', (t) async {
    await mount(t);
    c.searchRandom();
    await t.pump();
    expect(find.textContaining('Looking for an opponent'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('pk-cancel')));
    await t.pump();
    expect(find.byKey(const ValueKey('pk-status')), findsNothing);
    expect(api.calls, contains('random-leave'));
    await unmount(t);
  });

  testWidgets('the invite sheet: pick 10 minutes, invite a followed host; the server gets that length', (t) async {
    late BuildContext ctx;
    await mount(t, extra: Builder(builder: (context) {
      ctx = context;
      return const SizedBox();
    }));
    api.following = const [PkCandidate(streamId: pkOtherStream, hostId: pkOther, title: 'Room', viewerCount: 12, hostName: 'Asha')];
    showPkInviteSheet(ctx, c);
    await t.pumpAndSettle();
    expect(find.text('Asha'), findsOneWidget);
    expect(find.text('12 watching'), findsOneWidget);
    for (final s in [300, 600, 1800, 2400]) {
      expect(find.byKey(ValueKey('pk-length-$s')), findsOneWidget);
    }

    await t.tap(find.byKey(const ValueKey('pk-length-600')));
    await t.pump();
    await t.tap(find.text('Invite'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(api.calls, contains('invite:$pkOtherStream:600'));
    expect(find.text('PK battle'), findsNothing, reason: 'the sheet closes once the invite is out');
    expect(find.textContaining('Waiting for'), findsOneWidget);
    await unmount(t);
  });

  testWidgets('the invite sheet: nobody followed is live; the Random tab starts a search', (t) async {
    late BuildContext ctx;
    await mount(t, extra: Builder(builder: (context) {
      ctx = context;
      return const SizedBox();
    }));
    showPkInviteSheet(ctx, c);
    await t.pumpAndSettle();
    expect(find.textContaining('Nobody you follow is live'), findsOneWidget);

    await t.tap(find.text('Random'));
    await t.pump();
    expect(find.textContaining('5 minutes'), findsOneWidget);
    expect(find.byKey(const ValueKey('pk-length-600')), findsNothing, reason: 'a random PK has no length to pick');
    await t.tap(find.byKey(const ValueKey('pk-random')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(api.calls, contains('random-join'));
    expect(find.textContaining('Looking for an opponent'), findsOneWidget);
    await unmount(t);
  });

  testWidgets('an invite to me opens Accept / Decline; Accept goes to the server', (t) async {
    await mount(t);
    api.emit(pkRow(status: 'invited', iAmA: false, seconds: 1800));
    await t.pumpAndSettle();
    expect(find.text('PK invite'), findsOneWidget);
    expect(find.textContaining('30 minute'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('pk-accept')));
    await t.pumpAndSettle();
    expect(api.calls, contains('respond:true'));
    expect(find.text('PK invite'), findsNothing);
    await unmount(t);
  });

  testWidgets('an invite that is withdrawn while its dialog is open closes the dialog', (t) async {
    await mount(t);
    api.emit(pkRow(status: 'invited', iAmA: false));
    await t.pumpAndSettle();
    expect(find.text('PK invite'), findsOneWidget);
    api.emit(pkRow(status: 'cancelled', iAmA: false));
    await t.pumpAndSettle();
    expect(find.text('PK invite'), findsNothing);
    await unmount(t);
  });

  testWidgets('the result: a win says so, and OK clears it for the next battle', (t) async {
    await mount(t);
    api.emit(pkRow(status: 'live', startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    api.emit(pkRow(status: 'finished', scoreA: 90, scoreB: 40, winner: 'a'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('pk-result-title')), findsOneWidget);
    expect(find.text('You won!'), findsOneWidget);
    expect(find.textContaining('90'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('pk-result-ok')));
    await t.pumpAndSettle();
    expect(c.phase, PkPhase.idle);
    await unmount(t);
  });

  testWidgets('the result after a forfeit explains it', (t) async {
    await mount(t);
    api.emit(pkRow(status: 'live', startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    api.emit(pkRow(status: 'finished', scoreA: 1, scoreB: 99, winner: 'a', endReason: 'forfeit'));
    await t.pumpAndSettle();
    expect(find.text('The other host left, so you win.'), findsOneWidget);
    await unmount(t);
  });

  testWidgets('a VIEWER is told the result as a spectator: who won, never "You won!"', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    now = DateTime.utc(2026, 10, 19, 12);
    api = PkFakeApi(() => now);
    final viewer = PkBattleController(api: api, streamId: pkMyStream, myHostId: 'a-viewer', clock: () => now);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: Stack(children: [Positioned.fill(child: PkBattleEvents(controller: viewer, watchedHostName: 'Riya Live'))])),
    ));
    viewer.start();
    await t.pump();
    api.emit(pkRow(status: 'live', startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    await t.pump();
    // the watched room's host (side A) wins 90 - 40
    api.emit(pkRow(status: 'finished', scoreA: 90, scoreB: 40, winner: 'a'));
    await t.pump();
    await t.pump();
    expect(find.text('Riya Live won!'), findsOneWidget);
    expect(find.text('You won!'), findsNothing);
    expect(find.text('Final score: 90 – 40'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('pk-result-ok')));
    await t.pumpAndSettle();

    // the same watcher, a battle the OTHER side wins (a forfeit): the other host is named, the reason is told neutrally
    api.emit(pkRow(id: 'b2', status: 'live', startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    await t.pump();
    api.emit(pkRow(id: 'b2', status: 'finished', scoreA: 90, scoreB: 10, winner: 'b', endReason: 'forfeit'));
    await t.pump();
    await t.pump();
    expect(find.text('Opponent won!'), findsOneWidget, reason: 'the profile of the other host is "Opponent" in the fake');
    expect(find.text('The other host gave up.'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('pk-result-ok')));
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    viewer.dispose();
  });

  testWidgets('a declined invite is explained in a snackbar and the host is free again', (t) async {
    await mount(t);
    c.invite(const PkCandidate(streamId: pkOtherStream, hostId: pkOther, title: 'x'), 300);
    await t.pump();
    api.emit(pkRow(status: 'cancelled'));
    await t.pump();
    expect(find.textContaining('declined'), findsOneWidget);
    expect(c.phase, PkPhase.idle);
    await t.pumpAndSettle(const Duration(seconds: 5));
    await unmount(t);
  });

  testWidgets('a gift in a battle goes to the side of the host it is for, with no question asked: once per unit', (t) async {
    late BuildContext ctx;
    await mount(t, extra: Builder(builder: (context) {
      ctx = context;
      return const SizedBox();
    }));
    api.emit(pkRow(status: 'live', startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    const rose = Gift('g', 'Rose', 'r', 1);
    final toThem = await sendPkGift(ctx, c, rose, 2, to: PkGiftSide.theirs);
    expect(toThem, 'b', reason: 'I am side A, so the other host is B');
    expect(api.calls.where((x) => x == 'gift:b').length, 2, reason: 'once per unit');
    final toMe = await sendPkGift(ctx, c, rose, 1, to: PkGiftSide.mine);
    expect(toMe, 'a');
    expect(api.calls.where((x) => x == 'gift:a').length, 1);
    expect(find.byType(AlertDialog), findsNothing, reason: 'the old "Send to" popup is gone');
    await unmount(t);
  });

  testWidgets('no PK gift outside a live battle', (t) async {
    late BuildContext ctx;
    await mount(t, extra: Builder(builder: (context) {
      ctx = context;
      return const SizedBox();
    }));
    final side = await sendPkGift(ctx, c, const Gift('g', 'Rose', 'r', 1), 1, to: PkGiftSide.mine);
    expect(side, isNull);
    expect(api.calls.where((x) => x.startsWith('gift:')), isEmpty);
    await unmount(t);
  });

  testWidgets('who a gift counts for: the room\'s host or the other host in a live battle; guests and "all" are ordinary gifts', (t) async {
    await mount(t);
    // no battle: nothing is a PK gift
    expect(pkGiftSideFor(c, recipientId: pkMe, myHostId: pkMe), isNull);
    api.emit(pkRow(status: 'live', startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    await t.pump(); // the opponent's profile arrives
    expect(pkGiftSideFor(c, recipientId: pkMe, myHostId: pkMe), PkGiftSide.mine);
    expect(pkGiftSideFor(c, recipientId: null, myHostId: pkMe), PkGiftSide.mine, reason: 'the sheet\'s default is the host');
    expect(pkGiftSideFor(c, recipientId: pkOther, myHostId: pkMe), PkGiftSide.theirs);
    expect(pkGiftSideFor(c, recipientId: 'a-guest', myHostId: pkMe), isNull, reason: 'a guest on a seat: an ordinary gift');
    expect(pkGiftSideFor(c, recipientId: pkOther, myHostId: pkMe, sendToAll: true), isNull, reason: 'send to all: ordinary');

    // the sheet lists the other host as one more person to gift, only while the battle is live
    final base = [me, AppUser(id: 'g1', name: 'Guest', username: '@g')];
    final shown = pkGiftSheetRecipients(base, c);
    expect([for (final u in shown) u.id], [pkMe, 'g1', pkOther]);
    expect(pkGiftSheetRecipients(shown, c).length, 3, reason: 'never twice');
    expect(pkGiftSheetRecipients(base, null).length, 2, reason: 'no PK in this room');
    api.emit(pkRow(status: 'finished', scoreA: 1, scoreB: 0, winner: 'a'));
    await t.pump();
    expect(pkGiftSheetRecipients(base, c).length, 2, reason: 'battle over');
    await unmount(t);
  });

  testWidgets('the arena: my seats on the red half, the OTHER live\'s seats on the blue half, read only, only while the battle runs', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await mount(t);
    final asked = <String>[];
    final tapped = <int>[];
    AppUser guest(String id) => AppUser(id: id, name: 'Guest $id', username: '@$id');
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PkBattleArena(
            controller: c,
            me: me,
            every: const Duration(seconds: 1),
            mine: PkSeatsData(
              hostId: pkMe,
              seatCount: 8,
              occupants: {1: me, 2: guest('g2')},
              onSeatTap: tapped.add,
            ),
            fetchSeats: (id) async {
              asked.add(id);
              return SeatSnapshot(
                occupants: {1: AppUser(id: pkOther, name: 'Opponent', username: '@o'), 3: guest('o3')},
                muted: {},
                agoraUids: {},
                seatCount: 8,
                locked: {4},
              );
            },
          ),
        ),
      ),
    ));
    expect(find.byKey(const ValueKey('pk-arena')), findsNothing, reason: 'no battle yet');

    api.emit(pkRow(status: 'live', scoreA: 70, scoreB: 30, startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(asked, [pkOtherStream], reason: 'the other live\'s seats, not mine');
    expect(find.byKey(const ValueKey('pk-arena')), findsOneWidget);
    expect(find.text('Me Host'), findsOneWidget);
    expect(find.text('Opponent'), findsOneWidget);
    expect(find.text('05:00'), findsOneWidget, reason: 'the old score bar: clock between the two scores');
    expect(find.text('VS'), findsOneWidget);
    expect(find.text('Guest g2'), findsOneWidget, reason: 'my guest is on my red half');
    expect(find.text('Guest o3'), findsOneWidget, reason: 'their guest is on the blue half');
    expect(find.text('Locked'), findsOneWidget, reason: 'their locked seat shows');

    // a tap on MY guest seat reaches the room (the host menu / a viewer request); the host's big picture is seat 1
    await t.tap(find.byKey(const ValueKey('pk-arena-seat-a-2')));
    await t.tap(find.byKey(const ValueKey('pk-arena-seat-a-3')));
    expect(tapped, [2, 3]);
    // nothing on the opponent's half does anything
    await t.tap(find.byKey(const ValueKey('pk-arena-seat-b-3')));
    await t.tap(find.byKey(const ValueKey('pk-arena-seat-b-4')));
    expect(tapped, [2, 3], reason: 'read only');

    await t.pump(const Duration(seconds: 1));
    expect(asked.length, 2, reason: 'it re-reads every second here (every few seconds in the app)');

    api.emit(pkRow(status: 'finished', scoreA: 3, scoreB: 1, winner: 'a'));
    await t.pump();
    expect(find.byKey(const ValueKey('pk-arena')), findsNothing, reason: 'gone when the battle is over');
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('a win throws confetti once; a loss does not', (t) async {
    await mount(t);
    api.emit(pkRow(status: 'live', startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    api.emit(pkRow(status: 'finished', scoreA: 9, scoreB: 1, winner: 'a'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('pk-confetti')), findsOneWidget);
    await t.pump(const Duration(seconds: 3)); // the burst is over, nothing keeps animating
    await t.tap(find.byKey(const ValueKey('pk-result-ok')));
    await t.pumpAndSettle();
    await unmount(t);

    await mount(t);
    api.emit(pkRow(status: 'live', startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    api.emit(pkRow(status: 'finished', scoreA: 1, scoreB: 9, winner: 'b'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('pk-confetti')), findsNothing);
    expect(find.text('You lost'), findsOneWidget);
    await unmount(t);
  });

  testWidgets('a live that was minimized when the invite came shows it as soon as the screen is back', (t) async {
    now = DateTime.utc(2026, 10, 17, 12);
    api = PkFakeApi(() => now);
    c = PkBattleController(api: api, streamId: pkMyStream, myHostId: pkMe, clock: () => now);
    c.start();
    await t.pump();
    // the screen is minimized: no PkBattleEvents is mounted while the invite arrives
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    api.emit(pkRow(status: 'invited', iAmA: false, seconds: 600));
    await t.pump();
    expect(c.phase, PkPhase.incoming);
    // restored: the events layer mounts again and picks up what is going on
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Stack(children: [Positioned.fill(child: PkBattleEvents(controller: c))]))));
    await t.pumpAndSettle();
    expect(find.text('PK invite'), findsOneWidget);
    expect(find.textContaining('10 minute'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('pk-decline')));
    await t.pumpAndSettle();
    await unmount(t);
  });
}
