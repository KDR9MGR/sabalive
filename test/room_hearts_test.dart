import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/live_hearts_repository.dart';
import 'package:sabalive/features/live/widgets/live_chat_bubble.dart';
import 'package:sabalive/features/live/widgets/room_hearts.dart';

/// 2026-11-07 (owner: "like preview and count sync; sum of all users like and hearts should be seen by all"): every heart tapped in a live by anybody is added to ONE total that
/// everybody in the room sees move, and the hearts float on everybody's screen.
class FakeHearts implements LiveHeartsApi {
  FakeHearts({this.initial = 0});
  int initial;
  int serverTotal = 0;
  final adds = <int>[];
  bool failNext = false;
  final events = StreamController<HeartsEvent>.broadcast();
  int watchers = 0;

  @override
  Future<int> total(String streamId) async => initial;

  @override
  Future<int?> add(String streamId, int count) async {
    adds.add(count);
    if (failNext) {
      failNext = false;
      return null;
    }
    serverTotal += count;
    return serverTotal;
  }

  @override
  Stream<HeartsEvent> watch(String streamId) => events.stream;
}

void main() {
  const me = 'me';

  RoomHearts make(FakeHearts api, {Duration flushEvery = const Duration(seconds: 3)}) => RoomHearts(streamId: 's1', api: api, meId: me, flushEvery: flushEvery);

  test('a person who joins late starts from everybody\'s total so far', () async {
    final api = FakeHearts(initial: 1200);
    final h = make(api);
    await h.start();
    expect(h.count, 1200);
    h.dispose();
  });

  test('a tap moves the number at once and floats a heart, before anything is sent', () async {
    final api = FakeHearts(initial: 10);
    final h = make(api);
    await h.start();
    final bursts = <int>[];
    h.bursts.listen(bursts.add);
    h.tap();
    h.tap();
    await Future<void>.delayed(Duration.zero);
    expect(h.count, 12);
    expect(bursts, [1, 1]);
    expect(api.adds, isEmpty, reason: 'sent in a batch, not per tap');
    h.dispose();
  });

  testWidgets('taps go out as ONE batch a few seconds after the first tap of a run, and the total stays right', (t) async {
    final api = FakeHearts(initial: 100)..serverTotal = 100;
    final h = make(api);
    unawaited(h.start());
    await t.pump();
    for (var i = 0; i < 7; i++) {
      h.tap();
      await t.pump(const Duration(milliseconds: 300));
    }
    expect(api.adds, isEmpty, reason: '2.1 s in: not yet');
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    expect(api.adds, [7], reason: 'one call with all the taps of the run');
    expect(h.count, 107, reason: 'the server\'s answer (107) and the 7 taps are the same hearts: counted once');
    h.dispose();
  });

  test('somebody else\'s batch sets the total and floats that many hearts; my own echo neither floats nor counts twice', () async {
    final api = FakeHearts(initial: 50)..serverTotal = 50;
    final h = make(api, flushEvery: const Duration(milliseconds: 10));
    await h.start();
    final bursts = <int>[];
    h.bursts.listen(bursts.add);
    api.events.add(const HeartsEvent(total: 58, by: 'other', count: 8));
    await Future<void>.delayed(Duration.zero);
    expect(h.count, 58);
    expect(bursts, [8]);
    bursts.clear();

    h.tap();
    h.tap();
    h.tap(); // 61 on my screen
    expect(h.count, 61);
    await Future<void>.delayed(Duration.zero);
    expect(bursts, [1, 1, 1], reason: 'each of my taps floated at once');
    bursts.clear();
    await Future<void>.delayed(const Duration(milliseconds: 30)); // my batch of 3 is sent
    // the server's echo of my own batch arrives
    api.events.add(const HeartsEvent(total: 61, by: me, count: 3));
    await Future<void>.delayed(Duration.zero);
    expect(h.count, 61, reason: 'my 3 are in the total now: not 64');
    expect(bursts, isEmpty, reason: 'they floated when I tapped');
    h.dispose();
  });

  test('a total that arrives out of order never makes the number go backwards', () async {
    final api = FakeHearts();
    final h = make(api);
    await h.start();
    api.events.add(const HeartsEvent(total: 90, by: 'a', count: 5));
    api.events.add(const HeartsEvent(total: 85, by: 'b', count: 5));
    await Future<void>.delayed(Duration.zero);
    expect(h.count, 90);
    h.dispose();
  });

  testWidgets('a send that fails keeps the taps for the next batch (nothing is lost, the number does not drop)', (t) async {
    final api = FakeHearts()..failNext = true;
    final h = make(api);
    unawaited(h.start());
    await t.pump();
    h.tap();
    h.tap();
    await t.pump(const Duration(seconds: 4));
    await t.pump();
    expect(api.adds, [2]);
    expect(h.count, 2, reason: 'the two taps are still counted');
    await t.pump(const Duration(seconds: 7));
    await t.pump();
    expect(api.adds, [2, 2], reason: 'sent again');
    expect(h.count, 2);
    h.dispose();
  });

  test('a batch is at most 100 hearts; the rest goes in the next', () async {
    final api = FakeHearts()..serverTotal = 0;
    final h = make(api);
    await h.start();
    for (var i = 0; i < 250; i++) {
      h.tap();
    }
    await h.flush();
    expect(api.adds, [100]);
    await h.flush();
    expect(api.adds, [100, 100]);
    await h.flush();
    expect(api.adds, [100, 100, 50]);
    expect(h.count, 250);
    h.dispose();
  });

  test('closing the room sends the taps that had not gone yet', () async {
    final api = FakeHearts();
    final h = make(api);
    await h.start();
    h.tap();
    h.tap();
    h.tap();
    h.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(api.adds, [3]);
  });

  test('a sample live that is not on the server keeps its hearts on this phone and talks to nobody', () async {
    final h = RoomHearts(streamId: 'mock-1', meId: me);
    await h.start();
    h.tap();
    h.tap();
    expect(h.count, 2);
    h.dispose();
  });

  testWidgets('the layer floats a heart for a tap, a handful for somebody else\'s big batch, and takes them away when they are done', (t) async {
    final api = FakeHearts();
    final h = make(api);
    await t.runAsync(() => h.start());
    await t.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 60, height: 320, child: RoomHeartsLayer(hearts: h)))));
    expect(find.byIcon(Icons.favorite_rounded), findsNothing);
    h.tap();
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    // somebody else sent 60: only a handful float (8), spread over about a second
    api.events.add(const HeartsEvent(total: 60, by: 'other', count: 60));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
    await t.pump(const Duration(milliseconds: 1200));
    expect(find.byIcon(Icons.favorite_rounded).evaluate().length, inInclusiveRange(1, 9));
    await t.pump(const Duration(seconds: 4));
    await t.pump();
    expect(find.byIcon(Icons.favorite_rounded), findsNothing, reason: 'they rose and faded out');
    h.dispose();
    await t.pumpWidget(const SizedBox.shrink());
  });

  test('the chat window shows three lines at a time', () {
    expect(kLiveChatVisibleLines, 3);
    expect(kLiveChatVisibleHeight, 3 * kLiveChatLineExtent);
  });
}
