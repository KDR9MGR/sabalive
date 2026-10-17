import 'package:flutter_test/flutter_test.dart';
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
}
