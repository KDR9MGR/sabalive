import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/data/pk_battles_repository.dart';
import 'package:sabalive/core/widgets/app_avatar.dart';
import 'package:sabalive/features/live/widgets/pk_battle_widgets.dart';
import 'package:sabalive/features/live/widgets/seat_snapshot.dart';
import 'package:sabalive/state/pk_battle_controller.dart';

import 'helpers/pk_fakes.dart';

void main() {
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

  testWidgets('the header draws nothing without a battle, then follows the invite and the battle', (t) async {
    await mount(t);
    expect(find.byKey(const ValueKey('pk-status')), findsNothing);
    expect(find.byKey(const ValueKey('pk-battle')), findsNothing);

    api.emit(pkRow(status: 'invited'));
    await t.pump();
    expect(find.textContaining('Waiting for'), findsOneWidget);
    expect(find.byKey(const ValueKey('pk-cancel')), findsOneWidget);

    api.emit(pkRow(status: 'live', scoreA: 120, scoreB: 80, startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    expect(find.byKey(const ValueKey('pk-battle')), findsOneWidget);
    expect(find.text('Me Host'), findsOneWidget);
    expect(find.text('Opponent'), findsOneWidget);
    expect(find.text('120'), findsWidgets);
    expect(find.text('05:00'), findsWidgets);
    await unmount(t);
  });

  testWidgets('the video stage shows both videos side by side with the battle header above', (t) async {
    t.view.physicalSize = const Size(390, 844); // a phone: two 3:4 panes side by side need a phone's width, not the default 800 x 600
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await mount(t);
    api.emit(pkRow(status: 'live', scoreA: 5, scoreB: 9, startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: PkVideoStage(
            controller: c,
            me: me,
            left: const ColoredBox(key: ValueKey('my-video'), color: Colors.red),
            right: const PkVideoWaiting(),
          ),
        ),
      ),
    ));
    expect(find.byKey(const ValueKey('pk-battle')), findsOneWidget, reason: 'the header is part of the stage');
    final left = t.getRect(find.byKey(const ValueKey('pk-pane-left')));
    final right = t.getRect(find.byKey(const ValueKey('pk-pane-right')));
    expect(left.left, lessThan(right.left));
    expect((left.width - right.width).abs(), lessThan(0.5), reason: 'two equal halves');
    expect(left.height / left.width, closeTo(4 / 3, 0.01), reason: 'each pane is 3:4');
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

  testWidgets('a gift during a battle asks which side, and goes to the opponent when chosen', (t) async {
    late BuildContext ctx;
    await mount(t, extra: Builder(builder: (context) {
      ctx = context;
      return const SizedBox();
    }));
    api.emit(pkRow(status: 'live', startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    String? side;
    final done = sendPkGift(ctx, c, const Gift('g', 'Rose', 'r', 1), 2, mineLabel: 'Me Host').then((s) => side = s);
    await t.pumpAndSettle();
    expect(find.text('Send to'), findsOneWidget);
    await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Opponent')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('pk-gift-send')));
    await t.pumpAndSettle();
    await done;
    expect(side, 'b', reason: 'I am side A, so the opponent is B');
    expect(api.calls.where((x) => x == 'gift:b').length, 2, reason: 'once per unit');
    await unmount(t);
  });

  testWidgets('no gift dialog outside a live battle', (t) async {
    late BuildContext ctx;
    await mount(t, extra: Builder(builder: (context) {
      ctx = context;
      return const SizedBox();
    }));
    final side = await sendPkGift(ctx, c, const Gift('g', 'Rose', 'r', 1), 1, mineLabel: 'x');
    expect(side, isNull);
    expect(find.text('Send to'), findsNothing);
    await unmount(t);
  });

  testWidgets('the opponent\'s room: who sits there, only while the battle runs, read from the OTHER live', (t) async {
    await mount(t);
    final asked = <String>[];
    SeatSnapshot seats(Map<int, AppUser> m) => SeatSnapshot(occupants: m, muted: {}, agoraUids: {});
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PkOpponentRoom(
          controller: c,
          every: const Duration(seconds: 1),
          fetchSeats: (id) async {
            asked.add(id);
            return seats({1: AppUser(id: 'o1', name: 'Opp Host', username: '@o1'), 3: AppUser(id: 'o2', name: 'Guest', username: '@o2')});
          },
        ),
      ),
    ));
    expect(find.byKey(const ValueKey('pk-opponent-room')), findsNothing, reason: 'no battle yet');

    api.emit(pkRow(status: 'live', startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(asked, [pkOtherStream], reason: 'the other live\'s seats, not mine');
    expect(find.byKey(const ValueKey('pk-opponent-room')), findsOneWidget);
    expect(find.text("Opponent's room"), findsOneWidget);
    expect(find.byType(AppAvatar), findsNWidgets(2));
    expect(find.descendant(of: find.byKey(const ValueKey('pk-opponent-room')), matching: find.byType(GestureDetector)), findsNothing,
        reason: 'read-only: nothing here takes a tap');

    await t.pump(const Duration(seconds: 1));
    expect(asked.length, 2, reason: 'it re-reads every second here (every few seconds in the app)');

    api.emit(pkRow(status: 'finished', scoreA: 3, scoreB: 1, winner: 'a'));
    await t.pump();
    expect(find.byKey(const ValueKey('pk-opponent-room')), findsNothing, reason: 'gone when the battle is over');
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
