import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/pk_battle_arena.dart';
import 'package:sabalive/features/live/widgets/pk_battle_widgets.dart';
import 'package:sabalive/features/live/widgets/pk_visit_opponent.dart';
import 'package:sabalive/state/active_live_session_controller.dart';
import 'package:sabalive/state/pk_battle_controller.dart';

import 'helpers/pk_fakes.dart';

/// A viewer of a PK battle can go to the OTHER host's room: tap the other side, confirm, and this room is left for that one.
void main() {
  usePlainPkLook();
  final me = AppUser(id: pkMe, name: 'Me Host', username: '@me');
  LiveStream stream(String id) => LiveStream(id: id, host: AppUser(id: pkOther, name: 'Opponent', username: '@o'), title: 't', category: 'c', viewers: 0);

  Future<(PkBattleController, PkFakeApi)> liveBattle(WidgetTester t) async {
    final now = DateTime.utc(2026, 10, 19, 12);
    final api = PkFakeApi(() => now);
    // a viewer: its id is neither host's
    final c = PkBattleController(api: api, streamId: pkMyStream, myHostId: 'a-viewer', clock: () => now);
    c.start();
    await t.pump();
    api.emit(pkRow(status: 'live', startedAt: now, endsAt: now.add(const Duration(minutes: 5))));
    await t.pump();
    await t.pump();
    expect(c.phase, PkPhase.live);
    expect(c.opponent?.name, 'Opponent', reason: 'the profile of the OTHER host has arrived');
    return (c, api);
  }

  void phone(WidgetTester t) {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
  }

  group('visitOpponentRoom', () {
    Future<BuildContext> host(WidgetTester t) async {
      late BuildContext ctx;
      await t.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) {
        ctx = context;
        return const SizedBox();
      }))));
      return ctx;
    }

    testWidgets('a card names the other host; Cancel stays, nothing is looked up or opened', (t) async {
      phone(t);
      final (c, _) = await liveBattle(t);
      final ctx = await host(t);
      var fetched = 0, switched = 0;
      final done = visitOpponentRoom(ctx, c, fetchStream: (_) async { fetched++; return stream('x'); }, switchTo: (_, _) async => switched++);
      await t.pumpAndSettle();
      expect(find.text('Opponent'), findsOneWidget);
      expect(find.text("Go to Opponent's room"), findsOneWidget);
      expect(find.text('Join their room to chat, send gifts and take a seat there.'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('pk-visit-cancel')));
      await t.pumpAndSettle();
      await done;
      expect((fetched, switched), (0, 0));
      c.dispose();
    });

    testWidgets('Go: the OTHER live is looked up by its id and opened', (t) async {
      phone(t);
      final (c, _) = await liveBattle(t);
      final ctx = await host(t);
      String? asked;
      LiveStream? opened;
      final done = visitOpponentRoom(ctx, c, fetchStream: (id) async { asked = id; return stream(id); }, switchTo: (_, target) async => opened = target);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('pk-visit-go')));
      await t.pumpAndSettle();
      await done;
      expect(asked, pkOtherStream, reason: 'the live of the other host, not this one');
      expect(opened?.id, pkOtherStream);
      c.dispose();
    });

    testWidgets('the other live is gone: a message, and this room is not left', (t) async {
      phone(t);
      final (c, _) = await liveBattle(t);
      final ctx = await host(t);
      var switched = 0;
      final done = visitOpponentRoom(ctx, c, fetchStream: (_) async => null, switchTo: (_, _) async => switched++);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('pk-visit-go')));
      await t.pumpAndSettle();
      await done;
      expect(find.text('That live is not available any more.'), findsOneWidget);
      expect(switched, 0);
      c.dispose();
    });

    testWidgets('a lookup that fails is treated the same way', (t) async {
      phone(t);
      final (c, _) = await liveBattle(t);
      final ctx = await host(t);
      var switched = 0;
      final done = visitOpponentRoom(ctx, c, fetchStream: (_) async => throw Exception('offline'), switchTo: (_, _) async => switched++);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('pk-visit-go')));
      await t.pumpAndSettle();
      await done;
      expect(find.text('That live is not available any more.'), findsOneWidget);
      expect(switched, 0);
      c.dispose();
    });

    testWidgets('no battle, or not yet fighting: no card', (t) async {
      phone(t);
      final now = DateTime.utc(2026, 10, 19, 12);
      final c = PkBattleController(api: PkFakeApi(() => now), streamId: pkMyStream, myHostId: 'a-viewer', clock: () => now);
      c.start();
      await t.pump();
      final ctx = await host(t);
      await visitOpponentRoom(ctx, c, fetchStream: (_) async => stream('x'), switchTo: (_, _) async {});
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('pk-visit-go')), findsNothing);
      c.dispose();
    });
  });

  group('the tap targets', () {
    testWidgets('video: the right frame is a button with a switch mark, the left one is not; a host (no callback) has neither', (t) async {
      phone(t);
      final (c, _) = await liveBattle(t);
      var taps = 0;
      Widget stage(VoidCallback? onTapTheirs) => MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Padding(
              padding: pkVideoStagePadding(context),
              child: PkVideoStage(
                controller: c,
                me: me,
                left: const ColoredBox(color: Colors.red),
                right: const ColoredBox(color: Colors.blue),
                onTapTheirs: onTapTheirs,
              ),
            ),
          ),
        ),
      );
      await t.pumpWidget(stage(() => taps++));
      expect(find.byKey(const ValueKey('pk-visit-tap')), findsOneWidget, reason: 'one tap layer: on the right frame only');
      expect(find.byType(PkSwitchMark), findsOneWidget);
      await t.tapAt(t.getCenter(find.byKey(const ValueKey('pk-pane-left'))));
      expect(taps, 0, reason: 'the left frame is this room\'s own host');
      await t.tapAt(t.getCenter(find.byKey(const ValueKey('pk-pane-right'))));
      expect(taps, 1);

      await t.pumpWidget(stage(null));
      expect(find.byKey(const ValueKey('pk-visit-tap')), findsNothing);
      expect(find.byType(PkSwitchMark), findsNothing);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('audio: the blue half is a button with a switch mark, the red half is not; its seats stay read only', (t) async {
      phone(t);
      final (c, _) = await liveBattle(t);
      var taps = 0;
      final mineTapped = <int>[];
      Widget arena(VoidCallback? onTapTheirs) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PkBattleArena(
              controller: c,
              me: me,
              onTapTheirs: onTapTheirs,
              every: const Duration(seconds: 30),
              fetchSeats: (_) async => null,
              mine: PkSeatsData(hostId: pkMe, seatCount: 8, occupants: {1: me}, onSeatTap: mineTapped.add),
            ),
          ),
        ),
      );
      await t.pumpWidget(arena(() => taps++));
      await t.pump();
      expect(find.byType(PkSwitchMark), findsOneWidget);
      await t.tapAt(t.getCenter(find.byKey(const ValueKey('pk-arena-theirs'))));
      expect(taps, 1, reason: 'anywhere on the other host\'s half');
      await t.tap(find.byKey(const ValueKey('pk-arena-seat-a-2')));
      expect(taps, 1, reason: 'my own half does nothing of the kind');
      expect(mineTapped, [2], reason: 'and its seats still work as seats');

      await t.pumpWidget(arena(null));
      await t.pump();
      expect(find.byType(PkSwitchMark), findsNothing);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });
  });

  group('ActiveLiveSessionController.replaceWith', () {
    testWidgets('the old live is removed first and the new one only on the next frame (one frame would keep the old screen)', (t) async {
      final session = ActiveLiveSessionController();
      session.start(roomId: 'a', builder: (_) => const SizedBox(), hostName: 'A');
      final seen = <String?>[];
      session.addListener(() => seen.add(session.roomId));

      final done = session.replaceWith(roomId: 'b', builder: (_) => const SizedBox(), hostName: 'B', hostAvatarUrl: 'u');
      expect(session.isActive, isFalse, reason: 'ended at once: the overlay can take the old screen down');
      expect(seen, [null]);
      await t.pump(); // the frame in which the overlay sees "no live"
      await done;
      expect(seen, [null, 'b']);
      expect(session.roomId, 'b');
      expect(session.hostName, 'B');
      expect(session.isMinimized, isFalse);
    });

    testWidgets('with no live on screen it simply starts', (t) async {
      final session = ActiveLiveSessionController();
      await session.replaceWith(roomId: 'b', builder: (_) => const SizedBox(), hostName: 'B');
      expect(session.roomId, 'b');
    });
  });
}
