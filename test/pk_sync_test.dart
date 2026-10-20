import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/data/pk_battles_repository.dart';
import 'package:sabalive/state/pk_battle_controller.dart';

import 'helpers/pk_fakes.dart';

/// FOUR PHONES IN ONE BATTLE: host A, host B, a viewer of A's room and a viewer of B's room, each with its own phone clock, all talking
/// to one shared "server" (the single `pk_battles` row that Realtime sends to everybody). The question: do they see the same battle at
/// the same time, like the people in any other live? Every check below compares all four.

/// The one server: it holds THE row and sends every change to every phone that is connected.
class SimServer {
  SimServer(this.now);
  final DateTime Function() now;
  PkBattleInfo? row;
  final phones = <SimApi>[];

  void publish(PkBattleInfo r) {
    row = r;
    for (final p in phones) {
      if (!p.offline) p.emit(r);
    }
  }

  PkBattleInfo begin() {
    final r = row!;
    return pkRow(
      status: 'live', scoreA: r.scoreA, scoreB: r.scoreB, seconds: r.durationSeconds, seq: r.lastGiftSeq,
      startedAt: now(), endsAt: now().add(Duration(seconds: r.durationSeconds)),
    );
  }

  PkBattleInfo gift(String side, int coins) {
    final r = row!;
    return pkRow(
      status: 'live', scoreA: r.scoreA + (side == 'a' ? coins : 0), scoreB: r.scoreB + (side == 'b' ? coins : 0),
      seconds: r.durationSeconds, seq: r.lastGiftSeq + 1, startedAt: r.startedAt, endsAt: r.endsAt,
    );
  }

  PkBattleInfo finish({String? giveUpBy}) {
    final r = row!;
    final winner = giveUpBy != null
        ? (giveUpBy == 'a' ? 'b' : 'a')
        : (r.scoreA > r.scoreB ? 'a' : (r.scoreB > r.scoreA ? 'b' : 'draw'));
    return pkRow(
      status: 'finished', scoreA: r.scoreA, scoreB: r.scoreB, winner: winner, seq: r.lastGiftSeq,
      endReason: giveUpBy != null ? 'forfeit' : 'time', startedAt: r.startedAt, endsAt: r.endsAt,
    );
  }
}

/// One phone's connection to the server.
class SimApi extends PkFakeApi {
  SimApi(super.clock, this.server, {required this.isHost});
  final SimServer server;
  final bool isHost;

  /// A dropped connection: nothing arrives and nothing can be read.
  bool offline = false;

  @override
  Future<PkBattleInfo?> currentBattleFor(String streamId) async {
    if (offline) throw Exception('offline');
    final r = server.row;
    return r == null || r.status == 'finished' || r.status == 'cancelled' ? null : r;
  }

  @override
  Future<PkBattleInfo?> battleById(String battleId) async {
    calls.add('read:$battleId');
    if (offline) throw Exception('offline');
    return server.row;
  }

  @override
  Future<PkBattleInfo> beginV2(String battleId) async {
    if (!isHost) throw Exception('message: Only a host of this battle can start it'); // a viewer's call is refused, as on the server
    final r = server.row!;
    if (r.status == 'live') return r; // the second host's call: a no-op
    final live = server.begin();
    server.publish(live);
    return live;
  }

  @override
  Future<PkBattleInfo> finalizeNow(String battleId) async {
    final r = server.row!;
    if (r.status == 'finished') return r;
    final done = server.finish();
    server.publish(done);
    return done;
  }

  @override
  Future<AppUser?> profile(String userId) async => AppUser(id: userId, name: userId == pkMe ? 'Host A' : 'Host B', username: '@x');
}

class Phone {
  Phone(this.name, this.c, this.api, this.channels);
  final String name;
  final PkBattleController c;
  final SimApi api;
  final List<String?> channels;
}

void main() {
  late DateTime now;
  late SimServer server;
  late List<Phone> phones;
  late Phone hostA, hostB, viewerA, viewerB;

  Phone phone(String name, String streamId, String myHostId, Duration clockOff, {required bool host}) {
    final api = SimApi(() => now, server, isHost: host);
    server.phones.add(api);
    final channels = <String?>[];
    final c = PkBattleController(
      api: api, streamId: streamId, myHostId: myHostId, onChannel: channels.add,
      jitter: Duration.zero, clock: () => now.add(clockOff), // this phone's own clock: wrong by clockOff
    );
    return Phone(name, c, api, channels);
  }

  /// Time passes for everybody (a second at a time, like real time: each phone ticks once a second).
  Future<void> elapse(WidgetTester t, int seconds) async {
    for (var i = 0; i < seconds; i++) {
      now = now.add(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
    }
  }

  Future<void> startAll(WidgetTester t) async {
    for (final p in phones) {
      p.c.start();
    }
    await t.pump();
    await t.pump();
  }

  Future<void> setup(WidgetTester t) async {
    now = DateTime.utc(2026, 10, 19, 20);
    server = SimServer(() => now);
    // stream A (host pkMe) and stream B (host pkOther); every phone's clock is wrong by a different amount
    hostA = phone('host A', pkMyStream, pkMe, const Duration(seconds: 7), host: true);
    hostB = phone('host B', pkOtherStream, pkOther, const Duration(seconds: -12), host: true);
    viewerA = phone('viewer of A', pkMyStream, 'viewer-a', const Duration(seconds: -3), host: false);
    viewerB = phone('viewer of B', pkOtherStream, 'viewer-b', const Duration(seconds: 25), host: false);
    phones = [hostA, hostB, viewerA, viewerB];
    await startAll(t);
  }

  void everyone(String what, bool Function(Phone) ok, {Iterable<Phone>? of}) {
    for (final p in of ?? phones) {
      expect(ok(p), isTrue, reason: '$what: ${p.name}');
    }
  }

  Future<void> tearDown(WidgetTester t) async {
    for (final p in phones) {
      p.c.dispose();
    }
  }

  /// The invited -> accepted -> live walk, with the real time it takes.
  Future<void> startBattle(WidgetTester t, {int seconds = 300}) async {
    server.publish(pkRow(status: 'invited', seconds: seconds));
    await t.pump();
    await t.pump();
    server.publish(pkRow(status: 'accepted', seconds: seconds));
    await t.pump();
    await elapse(t, 3); // the 3-2-1: the hosts' phones then ask the server to begin (a viewer's own call is refused)
    await t.pump();
  }

  testWidgets('the whole battle, four phones with four wrong clocks: the same phases, scores, clock, opponent and result everywhere', (t) async {
    await setup(t);

    // 1. the invite
    server.publish(pkRow(status: 'invited'));
    await t.pump();
    await t.pump();
    expect(hostA.c.phase, PkPhase.inviting, reason: 'the inviter waits');
    expect(hostB.c.phase, PkPhase.incoming, reason: 'the invited host is asked');
    expect(viewerA.c.phase, PkPhase.inviting, reason: 'a viewer is never asked to accept: it sees "waiting"');
    expect(viewerB.c.phase, PkPhase.inviting);

    // 2. accepted: the 3-2-1 on every phone, then the hosts begin it
    server.publish(pkRow(status: 'accepted'));
    await t.pump();
    everyone('countdown', (p) => p.c.phase == PkPhase.countdown);
    await elapse(t, 3);
    await t.pump();
    everyone('live after the 3-2-1', (p) => p.c.phase == PkPhase.live);
    expect(server.row!.status, 'live', reason: 'one of the hosts began it on the server');

    // 3. who is the opponent: each phone shows the OTHER room's host, viewers included
    await t.pump();
    for (final p in [hostA, viewerA]) {
      expect(p.c.opponent?.name, 'Host B', reason: '${p.name}: this room is A, the opponent is B');
    }
    for (final p in [hostB, viewerB]) {
      expect(p.c.opponent?.name, 'Host A', reason: '${p.name}: this room is B, the opponent is A');
    }

    // 4. the clock: every phone counts the same remaining time, although their own clocks are off by 7, -12, -3 and 25 seconds
    await elapse(t, 20);
    final left = phones.map((p) => p.c.secondsLeft.value).toList();
    expect(left.reduce((a, b) => a > b ? a : b) - left.reduce((a, b) => a < b ? a : b), lessThanOrEqualTo(1),
        reason: 'the clocks agree within a second: $left');
    expect(left.first, inInclusiveRange(276, 280), reason: '300 s battle, 23 s in');

    // 5. gifts from both rooms: every phone ends with the same two scores, each seen from its own side
    server.publish(server.gift('a', 120));
    await t.pump();
    server.publish(server.gift('b', 80));
    await t.pump();
    server.publish(server.gift('a', 30));
    await t.pump();
    for (final p in [hostA, viewerA]) {
      expect((p.c.scoreMine, p.c.scoreTheirs), (150, 80), reason: '${p.name} (room A)');
    }
    for (final p in [hostB, viewerB]) {
      expect((p.c.scoreMine, p.c.scoreTheirs), (80, 150), reason: '${p.name} (room B): the same two numbers, mirrored');
    }

    // 6. the audio / video moves to the battle's shared channel on every phone, once
    everyone('moved to the shared channel', (p) => p.channels.length == 1 && p.channels.single == 'pk-b1');

    // 7. the final bell: the hosts close it; everybody gets the same result
    await elapse(t, 290);
    await t.pump();
    await t.pump();
    everyone('finished', (p) => p.c.phase == PkPhase.finished);
    expect(hostA.c.result?.outcome, PkOutcome.win);
    expect(viewerA.c.result?.outcome, PkOutcome.win, reason: 'the viewer of the winning room: that room won');
    expect(hostB.c.result?.outcome, PkOutcome.lose);
    expect(viewerB.c.result?.outcome, PkOutcome.lose);
    for (final p in [hostA, viewerA]) {
      expect((p.c.result?.mine, p.c.result?.theirs), (150, 80), reason: p.name);
    }
    for (final p in [hostB, viewerB]) {
      expect((p.c.result?.mine, p.c.result?.theirs), (80, 150), reason: p.name);
    }
    everyone('no forfeit flag on a normal ending', (p) => p.c.result?.forfeit == false);
    everyone('back to the own channel', (p) => p.channels.length == 2 && p.channels.last == null);
    await tearDown(t);
  });

  testWidgets('a draw is a draw for everybody', (t) async {
    await setup(t);
    await startBattle(t, seconds: 60);
    server.publish(server.gift('a', 50));
    await t.pump();
    server.publish(server.gift('b', 50));
    await t.pump();
    await elapse(t, 62);
    await t.pump();
    everyone('finished', (p) => p.c.phase == PkPhase.finished);
    everyone('draw', (p) => p.c.result?.outcome == PkOutcome.draw);
    await tearDown(t);
  });

  testWidgets('a host gives up: both hosts and both rooms\' viewers see the same ending, from their own side', (t) async {
    await setup(t);
    await startBattle(t);
    server.publish(server.gift('a', 500)); // A is far ahead and still gives up
    await t.pump();
    await elapse(t, 10);
    server.publish(server.finish(giveUpBy: 'a'));
    await t.pump();
    await t.pump();
    everyone('finished', (p) => p.c.phase == PkPhase.finished);
    expect(hostA.c.result?.outcome, PkOutcome.lose);
    expect(viewerA.c.result?.outcome, PkOutcome.lose);
    expect(hostB.c.result?.outcome, PkOutcome.win);
    expect(viewerB.c.result?.outcome, PkOutcome.win);
    everyone('told it was a forfeit', (p) => p.c.result?.forfeit == true);
    everyone('back to the own channel', (p) => p.channels.last == null);
    await tearDown(t);
  });

  testWidgets('a phone that MISSED rows (its connection dropped) catches up: the scores within a minute, the ending a few seconds after the bell', (t) async {
    await setup(t);
    await startBattle(t);
    // viewer B loses its connection in the middle of the battle
    await elapse(t, 30);
    viewerB.api.offline = true;
    server.publish(server.gift('a', 100));
    await t.pump();
    server.publish(server.gift('b', 40));
    await t.pump();
    expect((viewerB.c.scoreMine, viewerB.c.scoreTheirs), (0, 0), reason: 'it heard nothing');
    expect((viewerA.c.scoreMine, viewerA.c.scoreTheirs), (100, 40), reason: 'the others did');
    // the connection comes back (but Realtime does not replay what was missed)
    viewerB.api.offline = false;
    await elapse(t, 65);
    expect((viewerB.c.scoreMine, viewerB.c.scoreTheirs), (40, 100), reason: 'its own periodic read brought it up to date');

    // it drops again right before the end, and misses the closing row
    viewerB.api.offline = true;
    server.publish(server.gift('b', 500));
    await t.pump();
    await elapse(t, 300 - 30 - 65 + 1); // past the final bell
    await t.pump();
    expect(hostA.c.phase, PkPhase.finished);
    expect(viewerA.c.phase, PkPhase.finished);
    expect(viewerB.c.phase, PkPhase.live, reason: 'still showing the battle: it never saw the end');
    viewerB.api.offline = false;
    await elapse(t, 12); // its safety read after the final bell
    await t.pump();
    expect(viewerB.c.phase, PkPhase.finished, reason: 'it asked the server and got the closing row');
    expect(viewerB.c.result?.outcome, PkOutcome.win, reason: 'B won 540 to 100 after the gift it missed');
    expect((viewerB.c.result?.mine, viewerB.c.result?.theirs), (540, 100));
    await tearDown(t);
  });

  testWidgets('a viewer who joins in the MIDDLE of the battle sees the same battle: the opponent, the scores and the clock', (t) async {
    await setup(t);
    await startBattle(t);
    server.publish(server.gift('a', 70));
    await t.pump();
    server.publish(server.gift('b', 20));
    await t.pump();
    await elapse(t, 100);

    final late = phone('late viewer of B', pkOtherStream, 'viewer-late', const Duration(seconds: -40), host: false);
    phones.add(late);
    late.c.start();
    await t.pump();
    await t.pump();
    expect(late.c.phase, PkPhase.live);
    expect(late.c.opponent?.name, 'Host A');
    expect((late.c.scoreMine, late.c.scoreTheirs), (20, 70));
    expect((late.c.secondsLeft.value - viewerB.c.secondsLeft.value).abs(), lessThanOrEqualTo(1), reason: 'the same clock as the others');
    // it is told to be in the shared channel at once
    expect(late.channels, ['pk-b1']);
    await tearDown(t);
  });

  testWidgets('rows that arrive twice, or an OLD row after a new one, change nothing', (t) async {
    await setup(t);
    await startBattle(t);
    final early = server.gift('a', 10);
    server.publish(early);
    await t.pump();
    final later = server.gift('a', 90); // 100 in all
    server.publish(later);
    await t.pump();
    for (final p in phones) {
      p.api.emit(early); // the old row arrives late, out of order
      p.api.emit(later); // and the new one a second time
    }
    await t.pump();
    for (final p in [hostA, viewerA]) {
      expect(p.c.scoreMine, 100, reason: p.name);
    }
    // the ending arrives, then an old "live" row: the battle stays over
    server.publish(server.finish(giveUpBy: 'b'));
    await t.pump();
    for (final p in phones) {
      p.api.emit(later);
    }
    await t.pump();
    everyone('still finished', (p) => p.c.phase == PkPhase.finished);
    await tearDown(t);
  });
}
