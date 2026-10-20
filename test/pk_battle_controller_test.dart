import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:sabalive/data/models.dart';
import 'package:sabalive/data/pk_battles_repository.dart';
import 'package:sabalive/state/pk_battle_controller.dart';

import 'helpers/pk_fakes.dart';

void main() {
  late DateTime now;
  DateTime clock() => now;

  /// Runs [body] in fake time; [elapse] moves the fake timers AND the controller's clock together.
  void scenario(String name, Future<void> Function(WidgetTester t, Future<void> Function(Duration) elapse, PkFakeApi api) body) {
    testWidgets(name, (t) async {
      now = DateTime.utc(2026, 10, 17, 12);
      Future<void> elapse(Duration d) async {
        now = now.add(d);
        await t.pump(d);
      }

      await body(t, elapse, PkFakeApi(clock));
    });
  }

  PkBattleController make(PkFakeApi api, {List<String?>? channels, bool iAmHost = true}) => PkBattleController(
    api: api,
    streamId: pkMyStream,
    myHostId: iAmHost ? pkMe : 'a-viewer',
    onChannel: channels?.add,
    jitter: Duration.zero, // the random spread of the safety reads is off, so the tests are exact
    clock: clock,
  );

  scenario('no battle: idle; a battle that is already live is picked up with the right time left', (t, elapse, api) async {
    final c = make(api);
    c.start();
    await t.pump();
    expect(c.phase, PkPhase.idle);

    final c2 = make(api..current = api.liveRow(seconds: 600));
    c2.start();
    await t.pump();
    expect(c2.phase, PkPhase.live);
    expect(c2.secondsLeft.value, inInclusiveRange(599, 600));
    expect(c2.opponent?.name, 'Opponent');
    c.dispose();
    c2.dispose();
  });

  scenario('invite, accept, countdown, both phones begin, live, time up, finished: a win, and the channel moves there and back', (t, elapse, api) async {
    final channels = <String?>[];
    final c = make(api, channels: channels);
    c.start();
    await t.pump();

    c.invite(const PkCandidate(streamId: pkOtherStream, hostId: pkOther, title: 'x'), 600);
    await t.pump();
    expect(api.calls, contains('invite:$pkOtherStream:600'));
    expect(c.phase, PkPhase.inviting);

    api.emit(pkRow(status: 'accepted', seconds: 600));
    await t.pump();
    expect(c.phase, PkPhase.countdown);
    expect(api.calls, isNot(contains('begin')), reason: 'not before the countdown is over');

    await elapse(const Duration(seconds: 3));
    await t.pump();
    expect(api.calls.where((x) => x == 'begin').length, 1);
    expect(c.phase, PkPhase.live);
    expect(channels, ['pk-b1']);
    expect(c.secondsLeft.value, inInclusiveRange(599, 600));

    // the other host's gift moves the score
    api.emit(pkRow(status: 'live', scoreA: 40, scoreB: 25, seq: 1, startedAt: now, endsAt: now.add(const Duration(seconds: 597))));
    await t.pump();
    expect(c.scoreMine, 40);
    expect(c.scoreTheirs, 25);

    await elapse(const Duration(seconds: 600));
    await t.pump();
    expect(api.calls, contains('finalize'), reason: 'the host asks the server to close it when time is up');
    expect(c.phase, PkPhase.finished);
    expect(c.result?.outcome, PkOutcome.win);
    expect(c.result?.mine, 30);
    expect(c.result?.forfeit, isFalse);
    expect(channels, ['pk-b1', null]);
    c.dispose();
  });

  scenario('an invite to me: accept is sent to the server; decline cancels', (t, elapse, api) async {
    final c = make(api);
    c.start();
    await t.pump();
    api.emit(pkRow(status: 'invited', iAmA: false));
    await t.pump();
    expect(c.phase, PkPhase.incoming);

    c.respond(true);
    await t.pump();
    expect(api.calls, contains('respond:true'));
    expect(c.phase, PkPhase.countdown);
    c.dispose();

    final d = make(PkFakeApi(clock));
    d.start();
    await t.pump();
    (d.api as PkFakeApi).emit(pkRow(status: 'invited', iAmA: false));
    await t.pump();
    d.respond(false);
    await t.pump();
    expect(d.phase, PkPhase.cancelled);
    d.dispose();
  });

  scenario('a declined invite says so, and acknowledging clears it; a late duplicate row does not bring it back', (t, elapse, api) async {
    final c = make(api);
    c.start();
    await t.pump();
    c.invite(const PkCandidate(streamId: pkOtherStream, hostId: pkOther, title: 'x'), 300);
    await t.pump();
    api.emit(pkRow(status: 'cancelled'));
    await t.pump();
    expect(c.phase, PkPhase.cancelled);
    expect(c.message, contains('declined'));

    c.acknowledge();
    expect(c.phase, PkPhase.idle);
    api.emit(pkRow(status: 'cancelled'));
    await t.pump();
    expect(c.phase, PkPhase.idle);
    c.dispose();
  });

  scenario('rows that repeat, or arrive late, change nothing', (t, elapse, api) async {
    final c = make(api);
    c.start();
    await t.pump();
    final t0 = now;
    api.emit(pkRow(status: 'live', scoreA: 10, scoreB: 5, seq: 2, startedAt: t0, endsAt: t0.add(const Duration(seconds: 300))));
    await t.pump();
    var changes = 0;
    c.addListener(() => changes++);

    api.emit(pkRow(status: 'live', scoreA: 10, scoreB: 5, seq: 2, startedAt: t0, endsAt: t0.add(const Duration(seconds: 300)))); // the same row
    api.emit(pkRow(status: 'accepted')); // older
    api.emit(pkRow(status: 'invited')); // older
    await t.pump();
    expect(changes, 0);
    expect(c.phase, PkPhase.live);
    expect(c.scoreMine, 10);

    api.emit(pkRow(id: 'other-battle', status: 'invited', iAmA: false)); // a different battle while this one runs
    await t.pump();
    expect(c.battle?.id, 'b1');
    c.dispose();
  });

  scenario('a host who left: the other one wins by forfeit, from either side', (t, elapse, api) async {
    final c = make(api);
    c.start();
    await t.pump();
    api.emit(pkRow(status: 'live', iAmA: false, startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    api.emit(pkRow(status: 'finished', iAmA: false, scoreA: 99, scoreB: 1, winner: 'b', endReason: 'forfeit'));
    await t.pump();
    expect(c.result?.outcome, PkOutcome.win, reason: 'I am side B and B won although A had the higher score');
    expect(c.result?.forfeit, isTrue);
    expect(c.result?.mine, 1);
    expect(c.result?.theirs, 99);
    c.dispose();
  });

  scenario('a draw, and a loss', (t, elapse, api) async {
    final c = make(api);
    c.start();
    await t.pump();
    api.emit(pkRow(status: 'finished', scoreA: 7, scoreB: 7, winner: 'draw'));
    await t.pump();
    expect(c.result?.outcome, PkOutcome.draw);
    c.dispose();

    final d = make(PkFakeApi(clock));
    d.start();
    await t.pump();
    (d.api as PkFakeApi).emit(pkRow(status: 'finished', scoreA: 1, scoreB: 7, winner: 'b'));
    await t.pump();
    expect(d.result?.outcome, PkOutcome.lose);
    d.dispose();
  });

  scenario('random search asks again every 5 s, is paired, and then counts down like an invite', (t, elapse, api) async {
    final c = make(api);
    c.start();
    await t.pump();
    api.randomAnswers.addAll([null, null, pkRow(status: 'accepted', seconds: 300)]);

    c.searchRandom();
    await t.pump();
    expect(c.phase, PkPhase.searching);
    expect(api.calls.where((x) => x == 'random-join').length, 1);

    await elapse(const Duration(seconds: 5));
    await t.pump();
    expect(api.calls.where((x) => x == 'random-join').length, 2);
    expect(c.phase, PkPhase.searching);

    await elapse(const Duration(seconds: 5));
    await t.pump();
    expect(c.phase, PkPhase.countdown, reason: 'the third answer paired us');

    await elapse(const Duration(seconds: 3));
    await t.pump();
    expect(c.phase, PkPhase.live);
    c.dispose();
  });

  scenario('random search: leaving the pool, the timeout, and being paired by the other host\'s call', (t, elapse, api) async {
    final c = make(api);
    c.start();
    await t.pump();
    c.searchRandom();
    await t.pump();
    c.stopSearch();
    await t.pump();
    expect(c.phase, PkPhase.idle);
    expect(api.calls, contains('random-leave'));

    c.searchRandom();
    await t.pump();
    await elapse(const Duration(seconds: 65));
    await t.pump();
    expect(c.phase, PkPhase.idle);
    expect(c.message, contains('No opponent'));

    // the other host's call made the battle: it reaches me through Realtime while I was still searching
    c.searchRandom();
    await t.pump();
    api.emit(pkRow(id: 'b2', status: 'accepted', iAmA: true));
    await t.pump();
    expect(c.phase, PkPhase.countdown);
    expect(c.battle?.id, 'b2');
    c.dispose();
  });

  scenario('the countdown uses the SERVER clock: a phone 90 s behind still shows the right time', (t, elapse, api) async {
    api.serverAhead = const Duration(seconds: 90); // the server is 90 s ahead of this phone
    final c = make(api);
    c.start();
    await t.pump();
    final serverNow = now.add(const Duration(seconds: 90));
    api.emit(pkRow(status: 'live', startedAt: serverNow, endsAt: serverNow.add(const Duration(seconds: 300))));
    await t.pump();
    expect(c.secondsLeft.value, inInclusiveRange(299, 300), reason: 'against the phone clock it would read 390');
    await elapse(const Duration(seconds: 100));
    expect(c.secondsLeft.value, inInclusiveRange(199, 200));
    c.dispose();
  });

  scenario('an invite the server refuses shows its sentence and leaves the host free to try again', (t, elapse, api) async {
    api.inviteError = Exception('message: That streamer is not available for a PK battle right now');
    final c = make(api);
    c.start();
    await t.pump();
    c.invite(const PkCandidate(streamId: pkOtherStream, hostId: pkOther, title: 'x'), 300);
    await t.pump();
    expect(c.phase, PkPhase.idle);
    expect(c.message, 'That streamer is not available for a PK battle right now');
    expect(c.busy, isFalse);
    c.dispose();
  });

  scenario('a viewer is never asked to finalize; a gift goes to the chosen side; disposing stops everything', (t, elapse, api) async {
    final c = make(api, iAmHost: false);
    c.start();
    await t.pump();
    api.emit(pkRow(status: 'live', startedAt: now, endsAt: now.add(const Duration(seconds: 10))));
    await t.pump();
    c.gift('b', const Gift('g', 'Rose', 'r', 1));
    await t.pump();
    expect(api.calls, contains('gift:b'));
    await elapse(const Duration(seconds: 12));
    await t.pump();
    expect(api.calls, isNot(contains('finalize')));
    c.dispose();
    expect(api.watch.closed, isTrue);
  });

  scenario('End PK: a host who gives up loses (even when ahead) and the other host wins', (t, elapse, api) async {
    final c = make(api);
    c.start();
    await t.pump();
    api.emit(pkRow(status: 'live', scoreA: 90, scoreB: 10, startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    expect(c.phase, PkPhase.live);
    await c.giveUp();
    await t.pump();
    expect(api.calls, contains('give-up'));
    expect(api.calls, isNot(contains('finalize')), reason: 'the score does not decide a give-up');
    expect(c.phase, PkPhase.finished);
    expect(c.result?.outcome, PkOutcome.lose, reason: 'I was ahead 90 to 10, and I still lose by giving up');
    expect(c.result?.forfeit, isTrue, reason: 'the result screen explains it');
    expect(c.busy, isFalse);
    c.dispose();
  });

  scenario('End PK does nothing for a viewer, before the battle is live, or when there is no battle', (t, elapse, api) async {
    final viewer = make(api, iAmHost: false);
    viewer.start();
    await t.pump();
    api.emit(pkRow(status: 'live', startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    await viewer.giveUp();
    expect(api.calls, isNot(contains('give-up')), reason: 'a viewer is not a host of the battle');
    viewer.dispose();

    final host = make(api);
    host.start();
    await t.pump();
    await host.giveUp();
    expect(api.calls, isNot(contains('give-up')), reason: 'no battle, nothing to end');
    host.dispose();
  });

  scenario('End PK on a server without the give-up function: the battle goes on and the reason is shown', (t, elapse, api) async {
    final c = make(api);
    c.start();
    await t.pump();
    api.emit(pkRow(status: 'live', startedAt: now, endsAt: now.add(const Duration(seconds: 20))));
    await t.pump();
    api.giveUpError = const PostgrestException(message: 'Could not find the function public.pk_give_up_v2(p_battle_id) in the schema cache', code: 'PGRST202');
    await c.giveUp();
    await t.pump();
    expect(c.phase, PkPhase.live, reason: 'still fighting');
    expect(c.message, contains('latest update'));
    expect(c.busy, isFalse);
    // the final bell still closes it, and a failed End PK did not use up that one chance
    api.giveUpError = null;
    await elapse(const Duration(seconds: 22));
    await t.pump();
    expect(api.calls.where((x) => x == 'finalize').length, 1);
    c.dispose();
  });

  scenario('End PK: any other server error is shown too, and the battle goes on', (t, elapse, api) async {
    final c = make(api);
    c.start();
    await t.pump();
    api.emit(pkRow(status: 'live', startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    api.giveUpError = Exception('message: Only a host of this battle can end it');
    await c.giveUp();
    await t.pump();
    expect(c.phase, PkPhase.live);
    expect(c.message, 'Only a host of this battle can end it');
    c.dispose();
  });

  scenario('a VIEWER of side A sees the OTHER host as the opponent, not the room\'s own host (both frames used to show the same person)', (t, elapse, api) async {
    // the viewer screens pass the viewer's own user id as myHostId: it is neither host's id
    final viewerOfA = make(api, iAmHost: false);
    viewerOfA.start();
    await t.pump();
    api.emit(pkRow(status: 'live', iAmA: true, startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    await t.pump();
    expect(viewerOfA.mySide, 'a');
    expect(viewerOfA.opponent?.id, pkOther, reason: 'this live is A (host $pkMe), so the opponent is B, host $pkOther');
    viewerOfA.dispose();

    final viewerOfB = make(api, iAmHost: false);
    viewerOfB.start();
    await t.pump();
    api.emit(pkRow(status: 'live', iAmA: false, startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    await t.pump();
    expect(viewerOfB.mySide, 'b');
    expect(viewerOfB.opponent?.id, pkOther, reason: 'this live is B (host $pkMe), so the opponent is A, host $pkOther');
    viewerOfB.dispose();
  });

  scenario('hosts still get the right opponent from either side', (t, elapse, api) async {
    final hostA = make(api);
    hostA.start();
    await t.pump();
    api.emit(pkRow(status: 'live', iAmA: true, startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    await t.pump();
    expect(hostA.opponent?.id, pkOther);
    hostA.dispose();
    final hostB = make(api);
    hostB.start();
    await t.pump();
    api.emit(pkRow(status: 'live', iAmA: false, startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
    await t.pump();
    await t.pump();
    expect(hostB.opponent?.id, pkOther);
    hostB.dispose();
  });

  scenario('an invite is only "incoming" for the invited host; the inviter and every viewer just see "waiting"', (t, elapse, api) async {
    final invited = make(api); // host B of this row
    invited.start();
    await t.pump();
    api.emit(pkRow(status: 'invited', iAmA: false));
    await t.pump();
    expect(invited.phase, PkPhase.incoming);
    invited.dispose();

    final inviter = make(api);
    inviter.start();
    await t.pump();
    api.emit(pkRow(status: 'invited', iAmA: true));
    await t.pump();
    expect(inviter.phase, PkPhase.inviting);
    inviter.dispose();

    final viewer = make(api, iAmHost: false);
    viewer.start();
    await t.pump();
    api.emit(pkRow(status: 'invited', iAmA: false));
    await t.pump();
    expect(viewer.phase, PkPhase.inviting, reason: 'a viewer is never asked to accept or decline: no dialog');
    viewer.dispose();
  });

  scenario('safety: a viewer who MISSED the closing row asks for it after the final bell instead of staying at 00:00', (t, elapse, api) async {
    final viewer = make(api, iAmHost: false);
    viewer.start();
    await t.pump();
    final live = pkRow(status: 'live', scoreA: 40, scoreB: 10, startedAt: now, endsAt: now.add(const Duration(seconds: 20)));
    api.emit(live);
    await t.pump();
    expect(viewer.phase, PkPhase.live);
    // the server closes it, but this phone's Realtime connection dropped and the row never arrives
    api.byId['b1'] = pkRow(status: 'finished', scoreA: 55, scoreB: 30, winner: 'a');
    await elapse(const Duration(seconds: 22));
    expect(viewer.phase, PkPhase.live, reason: 'only 2 s past the bell: not worried yet (the closing row usually arrives at once)');
    expect(api.calls.where((c) => c.startsWith('read:')), isEmpty);
    await elapse(const Duration(seconds: 3));
    await t.pump();
    expect(api.calls, contains('read:b1'));
    expect(viewer.phase, PkPhase.finished);
    expect(viewer.result?.outcome, PkOutcome.win);
    expect((viewer.result?.mine, viewer.result?.theirs), (55, 30), reason: 'the final score the phone had not seen');
    viewer.dispose();
  });

  scenario('safety: no reads at all while the rows keep arriving, and one a minute when they do not', (t, elapse, api) async {
    final viewer = make(api, iAmHost: false);
    viewer.start();
    await t.pump();
    final end = now.add(const Duration(minutes: 10));
    api.emit(pkRow(status: 'live', startedAt: now, endsAt: end));
    await t.pump();
    // healthy connection: a gift every 20 s
    for (var i = 1; i <= 6; i++) {
      await elapse(const Duration(seconds: 20));
      api.emit(pkRow(status: 'live', scoreA: i * 10, seq: i, startedAt: now.subtract(Duration(seconds: 20 * i)), endsAt: end));
      await t.pump();
    }
    expect(api.calls.where((c) => c.startsWith('read:')), isEmpty, reason: 'Realtime is working: nothing extra is asked');

    // the connection drops: the server's scores move on, this phone hears nothing
    api.byId['b1'] = pkRow(status: 'live', scoreA: 500, scoreB: 300, seq: 9, startedAt: now, endsAt: end);
    await elapse(const Duration(seconds: 59));
    expect(api.calls.where((c) => c.startsWith('read:')), isEmpty);
    await elapse(const Duration(seconds: 2));
    await t.pump();
    expect(api.calls.where((c) => c.startsWith('read:')).length, 1);
    expect((viewer.scoreMine, viewer.scoreTheirs), (500, 300), reason: 'caught up with what it missed');
    viewer.dispose();
  });

  scenario('refresh(): applies the server row (also for a phone that has no battle yet) and can measure the clock again', (t, elapse, api) async {
    final c = make(api, iAmHost: false);
    c.start();
    await t.pump();
    expect(c.phase, PkPhase.idle);
    api.current = pkRow(status: 'live', scoreA: 7, startedAt: now, endsAt: now.add(const Duration(seconds: 100)));
    await c.refresh();
    expect(c.phase, PkPhase.live, reason: 'no battle known: it asks for this live\'s battle');
    expect(c.scoreMine, 7);

    // the phone's clock was corrected while the app was in the background: the server is now 30 s ahead of what was measured
    final before = c.secondsLeft.value;
    api.serverAhead = const Duration(seconds: 30);
    await c.refresh(resync: true);
    await elapse(const Duration(seconds: 1));
    expect(c.secondsLeft.value, lessThan(before - 25), reason: 'the countdown follows the server\'s clock again');
    c.dispose();
  });

  scenario('refresh() never throws: offline just means the next read or Realtime row fills it in', (t, elapse, api) async {
    final c = make(api, iAmHost: false);
    c.start();
    await t.pump();
    api.emit(pkRow(status: 'live', startedAt: now, endsAt: now.add(const Duration(seconds: 100))));
    await t.pump();
    api.readError = Exception('offline');
    await c.refresh();
    expect(c.phase, PkPhase.live);
    c.dispose();
  });
}
