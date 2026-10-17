import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/services/pk_channel_switcher.dart';

void main() {
  late List<String> switches;
  late List<bool> roles;
  Object? failWith;

  PkChannelSwitcher make({bool Function()? broadcaster, RtcEngine? Function()? engine, void Function(Object)? onError}) => PkChannelSwitcher(
    engine: engine ?? () => _FakeEngine(),
    ownChannel: 'room-1',
    broadcaster: broadcaster ?? () => true,
    onError: onError,
    switcher: (e, {required newChannelName, required asBroadcaster}) async {
      if (failWith != null) throw failWith!;
      switches.add(newChannelName);
      roles.add(asBroadcaster);
    },
  );

  setUp(() {
    switches = [];
    roles = [];
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
    final s = make(broadcaster: () => onSeat);
    await s.sync('pk-b1');
    onSeat = false;
    await s.sync(null);
    expect(roles, [true, false]);
  });

  test('before the engine has joined nothing happens, and a quick "joined then over" runs in order', () async {
    final s = make(engine: () => null);
    await s.sync('pk-b1');
    expect(switches, isEmpty);

    final t = make();
    final a = t.sync('pk-b1');
    final b = t.sync(null);
    await Future.wait([a, b]);
    expect(switches.last, 'room-1', reason: 'the last answer wins');
  });

  test('a failed switch is reported, not thrown', () async {
    failWith = Exception('token refused');
    Object? seen;
    final s = make(onError: (e) => seen = e);
    await s.sync('pk-b1');
    expect(seen, isNotNull);
  });
}

class _FakeEngine implements RtcEngine {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
