import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/services/pk_channel_switcher.dart';

void main() {
  late List<String> switches;
  late List<bool> roles;
  Object? failWith;

  late List<bool> cameras;

  PkChannelSwitcher make({
    bool Function(bool)? broadcaster,
    bool Function(bool)? publishCamera,
    RtcEngine? Function()? engine,
    void Function(Object)? onError,
    bool joined = true,
  }) {
    final s = PkChannelSwitcher(
    engine: engine ?? () => _FakeEngine(),
    ownChannel: 'room-1',
    broadcaster: broadcaster ?? (_) => true,
    publishCamera: publishCamera,
    onError: onError,
    switcher: (e, {required newChannelName, required asBroadcaster, required publishCamera}) async {
      if (failWith != null) throw failWith!;
      switches.add(newChannelName);
      roles.add(asBroadcaster);
      cameras.add(publishCamera);
    },
    );
    // a screen calls markJoined from onJoinChannelSuccess; the helper has done that already unless a test says otherwise
    if (joined) s.markJoined('room-1');
    return s;
  }

  setUp(() {
    switches = [];
    roles = [];
    cameras = [];
    failWith = null;
  });

  test('goes to the battle channel and back, once each', () async {
    final s = make();
    await s.sync(null); // nothing to do: already in the live's own channel
    expect(switches, isEmpty);
    await s.sync('pk-b1');
    await s.sync('pk-b1'); // the same answer again
    await s.sync(null);
    await s.sync(null);
    expect(switches, ['pk-b1', 'room-1']);
  });

  test('a seat guest keeps publishing, a plain listener does not', () async {
    var onSeat = true;
    final s = make(broadcaster: (_) => onSeat);
    await s.sync('pk-b1');
    onSeat = false;
    await s.sync(null);
    expect(roles, [true, false]);
  });

  test('a video host keeps its camera on in both channels; in a video battle the guests only listen', () async {
    final host = make(publishCamera: (_) => true);
    await host.sync('pk-b1');
    await host.sync(null);
    expect(cameras, [true, true]);
    expect(roles, [true, true]);

    roles.clear();
    cameras.clear();
    final guest = make(broadcaster: (inBattle) => !inBattle);
    await guest.sync('pk-b1');
    await guest.sync(null);
    expect(roles, [false, true], reason: 'a listener in the battle channel, a speaker again in the live\'s own');
    expect(cameras, [false, false]);
  });

  test('a battle that is already on when the phone gets in: the switch waits for the first join, then happens', () async {
    final s = make(joined: false);
    await s.sync('pk-b1'); // the battle row arrived before onJoinChannelSuccess
    expect(switches, isEmpty, reason: 'the first join is still on its way: switching now would be overridden by it');
    s.markJoined('room-1'); // ... and now the first join has succeeded
    await Future<void>.delayed(Duration.zero);
    expect(switches, ['pk-b1']);
    s.markJoined('pk-b1'); // the join of the switch itself reports in too: nothing more to do
    await Future<void>.delayed(Duration.zero);
    expect(switches, ['pk-b1']);
  });

  test('before the engine has joined nothing happens, and a battle that is over before the switch ran costs no switch at all', () async {
    final s = make(engine: () => null);
    await s.sync('pk-b1');
    expect(switches, isEmpty);

    final t = make();
    final a = t.sync('pk-b1');
    final b = t.sync(null);
    await Future.wait([a, b]);
    expect(switches, isEmpty, reason: 'the last answer wins: the phone never left its own channel, so there is nothing to switch back');
  });

  test('a failed switch is reported, not thrown', () async {
    failWith = Exception('token refused');
    Object? seen;
    final s = make(onError: (e) => seen = e);
    await s.sync('pk-b1');
    expect(seen, isNotNull);
  });
test('reapply: in a battle channel the role is applied again (a viewer was seated), outside one nothing happens', () async {
    var onSeat = false;
    final s = make(broadcaster: (_) => onSeat);
    expect(s.inSharedChannel, isFalse);
    await s.reapply(); // in the live's own channel: the screen changes the role itself
    expect(switches, isEmpty);

    await s.sync('pk-b1');
    expect(s.inSharedChannel, isTrue);
    expect(switches, ['pk-b1']);
    expect(roles, [false]);
    onSeat = true; // the host said yes: the viewer holds a seat now
    await s.reapply();
    expect(switches, ['pk-b1', 'pk-b1'], reason: 'the same channel again, with the new role');
    expect(roles, [false, true]);

    await s.sync(null);
    expect(s.inSharedChannel, isFalse);
    await s.reapply();
    expect(switches.length, 3, reason: 'back in its own channel: nothing more');
  });

  test('reapply before the first join does nothing, and a failure is reported', () async {
    final errors = <Object>[];
    final early = make(joined: false);
    await early.reapply();
    expect(switches, isEmpty);

    final s = make(onError: errors.add);
    await s.sync('pk-b1');
    failWith = Exception('token');
    await s.reapply();
    expect(errors, hasLength(1));
  });

}

class _FakeEngine implements RtcEngine {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
