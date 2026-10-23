import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/state/blocks_controller.dart';
import 'package:sabalive/state/live_streams_controller.dart';

/// The live list's cost control: how often it reads, and when it listens to Realtime at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  LiveStream live(String id, int viewers) =>
      LiveStream(id: id, host: AppUser(id: 'h$id', name: 'H$id', username: '@h$id'), title: 't', category: 'Chat', viewers: viewers);

  late int reads;
  late int listens;
  late int stops;
  void Function()? emit;
  late List<LiveStream> served;

  LiveStreamsController make({Duration gap = const Duration(seconds: 8)}) {
    reads = 0;
    listens = 0;
    stops = 0;
    emit = null;
    served = [live('a', 5), live('b', 50)];
    return LiveStreamsController(
      reloadGap: gap,
      blocks: BlocksController.test(() async => <String>{}),
      fetch: () async {
        reads++;
        return List.of(served);
      },
      listen: (onChange) {
        listens++;
        emit = onChange;
        return () async {
          stops++;
          emit = null;
        };
      },
    );
  }

  testWidgets('it reads once at start, listens, and lists the most watched first', (t) async {
    final c = make();
    await t.pump();
    expect(reads, 1);
    expect(listens, 1);
    expect(c.listening, isTrue);
    expect(c.loading, isFalse);
    expect([for (final s in c.streams) s.id], ['b', 'a']);
    c.dispose();
  });

  testWidgets('a stream of Realtime events reads at most once every 8 seconds (it used to be up to 40 a minute)', (t) async {
    final c = make();
    await t.pump();
    final before = reads;
    // an event every 200 ms for a minute: 300 events
    for (var i = 0; i < 300; i++) {
      emit?.call();
      await t.pump(const Duration(milliseconds: 200));
    }
    final extra = reads - before;
    expect(extra, inInclusiveRange(6, 9), reason: 'about 60 s / 8 s, got $extra');
    c.dispose();
  });

  testWidgets('a single event after a quiet spell is read at once (a new live shows without waiting)', (t) async {
    final c = make();
    await t.pump(const Duration(seconds: 20));
    final before = reads;
    served = [live('a', 5), live('b', 50), live('c', 500)];
    emit!.call();
    await t.pump();
    expect(reads, before + 1);
    expect(c.streams.first.id, 'c');
    c.dispose();
  });

  testWidgets('in the background it stops listening, and on return it listens again and reads fresh', (t) async {
    final c = make();
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump();
    expect(c.listening, isFalse);
    expect(stops, 1);
    final readsBefore = reads;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(c.listening, isTrue);
    expect(listens, 2);
    expect(reads, readsBefore + 1, reason: 'whatever changed while away is read once');
    c.dispose();
  });

  testWidgets('while a live is open full-screen it does not listen; when it closes it listens again and reads fresh', (t) async {
    final c = make();
    await t.pump();
    c.setInLiveRoom(true);
    expect(c.listening, isFalse);
    expect(stops, 1);
    final readsBefore = reads;
    c.setInLiveRoom(true); // the same state again changes nothing
    expect(stops, 1);
    c.setInLiveRoom(false);
    await t.pump();
    expect(c.listening, isTrue);
    expect(reads, readsBefore + 1);
    c.dispose();
  });

  testWidgets('it listens only when it is neither in the background nor in a live room', (t) async {
    final c = make();
    await t.pump();
    c.setInLiveRoom(true);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(c.listening, isFalse, reason: 'back in the app, but still inside the live');
    c.setInLiveRoom(false);
    await t.pump();
    expect(c.listening, isTrue);
    c.dispose();
  });

  testWidgets('a failed read keeps the list that is showing and does not throw', (t) async {
    final c = make();
    await t.pump();
    expect(c.streams, hasLength(2));
    served = []; // not used: the next read throws
    final failing = LiveStreamsController(
      blocks: BlocksController.test(() async => <String>{}),
      fetch: () async => throw Exception('offline'),
      listen: (_) => () async {},
    );
    await t.pump();
    expect(failing.loading, isTrue, reason: 'never loaded: the spinner stays, as before');
    expect(failing.refresh, returnsNormally);
    failing.dispose();
    c.dispose();
  });

  testWidgets('dispose stops listening and cancels what is pending', (t) async {
    final c = make();
    await t.pump();
    emit!.call();
    emit!.call();
    c.dispose();
    expect(stops, 1);
    final before = reads;
    await t.pump(const Duration(seconds: 30));
    expect(reads, before, reason: 'a pending run does not fire after dispose');
  });
}
