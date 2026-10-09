import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/media/effect_sound.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/data/store_repository.dart';
import 'package:sabalive/features/live/widgets/room_effect.dart';

const _rose = Gift('g-rose', 'Rose', '🌹', 10);
const _lion = Gift('g-lion', 'Lion', '🦁', 500);
const _catalog = {'g-rose': _rose, 'g-lion': _lion};
Gift? _lookup(String id) => _catalog[id];

Map<String, dynamic> _row({
  int id = 1,
  String sender = 'u-other',
  String kind = 'gift',
  Object? giftId = 'g-rose',
}) => {'id': id, 'sender_id': sender, 'kind': kind, 'gift_id': giftId};

bool _feed(RoomEffectController c, Map<String, dynamic> row) => c.onChatRow(
  row,
  meId: 'u-me',
  senderName: 'Sam',
  giftById: _lookup,
);

void main() {
  group('Gift.fromRow', () {
    Map<String, dynamic> row(Object? icon) => {
      'id': 'g1',
      'name': 'Rose',
      'emoji': '🌹',
      'price_coins': 10,
      'icon_url': icon,
    };

    test('carries the uploaded artwork url', () {
      expect(Gift.fromRow(row('https://x.co/rose.svga')).iconUrl, 'https://x.co/rose.svga');
    });

    test('a missing or blank url means "use the emoji"', () {
      expect(Gift.fromRow(row(null)).iconUrl, isNull);
      expect(Gift.fromRow(row('')).iconUrl, isNull);
      expect(Gift.fromRow(row('   ')).iconUrl, isNull);
    });
  });

  group('RoomEffectController.onChatRow', () {
    test('another user\'s gift row starts playing', () {
      final c = RoomEffectController();
      expect(_feed(c, _row()), isTrue);
      expect(c.current?.name, 'Rose');
      expect(c.current?.senderName, 'Sam');
      c.dispose();
    });

    test('ignores text/system rows and rows with no gift id', () {
      final c = RoomEffectController();
      expect(_feed(c, _row(kind: 'text')), isFalse);
      expect(_feed(c, _row(kind: 'system')), isFalse);
      expect(_feed(c, _row(giftId: null)), isFalse);
      expect(c.current, isNull);
      c.dispose();
    });

    test('skips the user\'s own gifts — they already played them locally', () {
      final c = RoomEffectController();
      expect(_feed(c, _row(sender: 'u-me')), isFalse);
      expect(c.current, isNull);
      c.dispose();
    });

    test('a row delivered twice (Realtime reconnect) plays once', () {
      final c = RoomEffectController();
      expect(_feed(c, _row(id: 7)), isTrue);
      expect(_feed(c, _row(id: 7)), isFalse);
      c.dispose();
    });

    test('a "to All" row says so in the caption, and does not merge with a one-person gift', () {
      final c = RoomEffectController();
      expect(_feed(c, {..._row(id: 20), 'to_all': true}), isTrue);
      expect(c.current?.caption, 'Sam sent Rose to All');
      // a plain Rose from the same person queued behind it stays its own effect
      expect(_feed(c, _row(id: 21)), isTrue);
      expect(_feed(c, {..._row(id: 22), 'to_all': true}), isTrue);
      c.finish(c.playId);
      expect(c.current?.caption, 'Sam sent Rose');
      c.finish(c.playId);
      expect(c.current?.caption, 'Sam sent Rose to All');
      c.dispose();
    });

    test('the sender\'s own effect for Send to All reads "You sent Rose to All"', () {
      final c = RoomEffectController();
      c.enqueue(RoomEffect.gift(gift: _rose, senderName: 'You', toAll: true));
      expect(c.current?.caption, 'You sent Rose to All');
      c.dispose();
    });

    test('a gift no longer in the catalog is skipped, not a crash', () {
      final c = RoomEffectController();
      expect(_feed(c, _row(giftId: 'g-retired')), isFalse);
      expect(c.current, isNull);
      c.dispose();
    });
  });

  group('RoomEffectController.onEntryRow', () {
    final car = StoreItem(
      id: 'i-car', category: StoreCategory.vehicle, name: 'Sports Car',
      emoji: '🚗', priceCoins: 1, durationDays: 7, assetUrl: 'https://x.co/car.svga',
    );
    final spark = StoreItem(
      id: 'i-spark', category: StoreCategory.entryEffect, name: 'Sparkle Entry',
      emoji: '✨', priceCoins: 1, durationDays: 7,
    );
    final items = {'i-car': car, 'i-spark': spark};
    Future<List<StoreItem>> load(List<String> ids) async => [
      for (final id in ids)
        if (items[id] case final item?) item,
    ];
    Map<String, dynamic> joinRow({
      int id = 10,
      String sender = 'u-other',
      Object? entry = const ['i-car', 'i-spark'],
      String? at,
    }) => {
      'id': id, 'sender_id': sender, 'kind': 'system', 'entry_item_ids': entry,
      'created_at': at ?? DateTime.now().toUtc().toIso8601String(),
    };
    Future<bool> feed(RoomEffectController c, Map<String, dynamic> row, {bool history = false, DateTime? now}) =>
        c.onEntryRow(row, meId: 'u-me', senderName: 'Sam', loadItems: load, history: history, now: now);

    test('somebody walking in plays their vehicle, then their entry effect', () async {
      final c = RoomEffectController();
      expect(await feed(c, joinRow()), isTrue);
      expect(c.current?.name, 'Sports Car');
      expect(c.current?.caption, 'Sam entered with Sports Car');
      expect(c.current?.mediaUrl, 'https://x.co/car.svga');
      c.finish(c.playId);
      expect(c.current?.name, 'Sparkle Entry');
      expect(c.current?.mediaUrl, isNull, reason: 'no artwork: plays as the emoji');
      c.dispose();
    });

    test('plays the user\'s own entry too (nothing played it locally)', () async {
      final c = RoomEffectController();
      expect(await feed(c, joinRow(sender: 'u-me')), isTrue);
      expect(c.current?.senderName, 'Sam');
      c.dispose();
    });

    test('a join with no entry items plays nothing', () async {
      final c = RoomEffectController();
      expect(await feed(c, joinRow(entry: null)), isFalse);
      expect(await feed(c, joinRow(entry: <String>[])), isFalse);
      expect(c.current, isNull);
      c.dispose();
    });

    test('ignores text and gift rows', () async {
      final c = RoomEffectController();
      expect(await feed(c, {'id': 1, 'kind': 'text', 'sender_id': 'u-other', 'entry_item_ids': ['i-car']}), isFalse);
      expect(await feed(c, {'id': 2, 'kind': 'gift', 'sender_id': 'u-other', 'entry_item_ids': ['i-car']}), isFalse);
      c.dispose();
    });

    test('the same row arriving twice (history then live) plays once', () async {
      final c = RoomEffectController();
      expect(await feed(c, joinRow(id: 5, sender: 'u-me'), history: true), isTrue);
      expect(await feed(c, joinRow(id: 5, sender: 'u-me')), isFalse);
      c.dispose();
    });

    group('history (backlog read when the screen opens)', () {
      test('replays only the user\'s own, very recent entry', () async {
        final c = RoomEffectController();
        final now = DateTime.utc(2026, 10, 2, 12, 0, 30);
        expect(await feed(c, joinRow(sender: 'u-other', at: '2026-10-02T12:00:25Z'), history: true, now: now), isFalse);
        expect(await feed(c, joinRow(id: 11, sender: 'u-me', at: '2026-10-02T11:50:00Z'), history: true, now: now), isFalse,
            reason: 'older than 20s');
        expect(await feed(c, joinRow(id: 12, sender: 'u-me', at: '2026-10-02T12:00:20Z'), history: true, now: now), isTrue);
        c.dispose();
      });
    });

    test('items that can no longer be loaded are skipped, not a crash', () async {
      final c = RoomEffectController();
      expect(
        await c.onEntryRow(joinRow(), meId: 'u-me', senderName: 'Sam', loadItems: (_) async => throw Exception('offline')),
        isFalse,
      );
      expect(c.current, isNull);
      c.dispose();
    });
  });

  group('handleRow', () {
    test('routes a gift row and an entry row to the right effect', () async {
      final c = RoomEffectController();
      Future<List<StoreItem>> load(List<String> ids) async => [
        StoreItem(id: 'i-spark', category: StoreCategory.entryEffect, name: 'Sparkle Entry', emoji: '✨', priceCoins: 1, durationDays: 7),
      ];
      await c.handleRow(_row(id: 1), meId: 'u-me', senderName: 'Sam', giftById: _lookup, loadItems: load);
      expect(c.current?.kind, RoomEffectKind.gift);
      c.finish(c.playId);
      await c.handleRow(
        {'id': 2, 'kind': 'system', 'sender_id': 'u-other', 'entry_item_ids': ['i-spark']},
        meId: 'u-me', senderName: 'Sam', giftById: _lookup, loadItems: load,
      );
      expect(c.current?.kind, RoomEffectKind.entry);
      c.dispose();
    });

    test('history never replays old gifts', () async {
      final c = RoomEffectController();
      await c.handleRow(_row(id: 1), meId: 'u-me', senderName: 'Sam', giftById: _lookup,
          loadItems: (_) async => const [], history: true);
      expect(c.current, isNull);
      c.dispose();
    });
  });

  group('queue', () {
    RoomEffect effect(Gift g, {String from = 'a', int count = 1}) =>
        RoomEffect.gift(gift: g, senderName: from, senderId: from, count: count);

    test('plays one at a time, in order', () {
      final c = RoomEffectController();
      c.enqueue(effect(_rose, from: 'a'));
      c.enqueue(effect(_lion, from: 'b'));
      expect(c.current?.name, 'Rose');
      c.finish(c.playId);
      expect(c.current?.name, 'Lion');
      c.finish(c.playId);
      expect(c.current, isNull);
      c.dispose();
    });

    test('a burst from one sender collapses into a single combo', () {
      final c = RoomEffectController();
      c.enqueue(effect(_lion, from: 'z')); // starts playing
      for (var i = 0; i < 5; i++) {
        c.enqueue(effect(_rose, from: 'a'));
      }
      c.finish(c.playId);
      expect(c.current?.name, 'Rose');
      expect(c.current?.count, 5, reason: 'five roses = one "x5", not five plays');
      c.finish(c.playId);
      expect(c.current, isNull);
      c.dispose();
    });

    test('different senders of the same gift are not merged', () {
      final c = RoomEffectController();
      c.enqueue(effect(_lion, from: 'z'));
      c.enqueue(effect(_rose, from: 'a'));
      c.enqueue(effect(_rose, from: 'b'));
      c.finish(c.playId);
      expect(c.current?.senderName, 'a');
      c.finish(c.playId);
      expect(c.current?.senderName, 'b');
      c.dispose();
    });

    test('a flooded room drops the oldest waiting gifts', () {
      final c = RoomEffectController(maxQueued: 2);
      c.enqueue(effect(_lion, from: 'now'));
      c.enqueue(effect(_rose, from: 'a'));
      c.enqueue(effect(_rose, from: 'b'));
      c.enqueue(effect(_rose, from: 'c'));
      c.finish(c.playId);
      expect(c.current?.senderName, 'b', reason: 'a was dropped');
      c.dispose();
    });

    test('a late finish from the previous effect cannot cut the next short', () {
      final c = RoomEffectController();
      c.enqueue(effect(_rose, from: 'a'));
      final first = c.playId;
      c.enqueue(effect(_lion, from: 'b'));
      c.finish(first);
      expect(c.current?.name, 'Lion');
      c.finish(first); // stale
      expect(c.current?.name, 'Lion');
      c.dispose();
    });

    test('an effect that never reports finishing is stopped after maxPlayTime', () async {
      final c = RoomEffectController(maxPlayTime: const Duration(milliseconds: 100));
      c.enqueue(effect(_rose, from: 'a'));
      c.enqueue(effect(_lion, from: 'b'));
      expect(c.current?.name, 'Rose');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(c.current?.name, 'Lion', reason: 'moved on by itself');
      c.dispose();
    });

    test('nothing happens after dispose', () {
      final c = RoomEffectController()..dispose();
      c.enqueue(effect(_rose));
      expect(c.current, isNull);
    });
  });

  group('RoomEffectLayer', () {
    Widget host(RoomEffectController c) => MaterialApp(
      home: Scaffold(body: Stack(children: [RoomEffectLayer(controller: c)])),
    );

    testWidgets('draws nothing while idle', (t) async {
      final c = RoomEffectController();
      await t.pumpWidget(host(c));
      expect(find.text('🌹'), findsNothing);
      c.dispose();
    });

    testWidgets('a gift without artwork plays as the emoji, then clears', (t) async {
      final c = RoomEffectController();
      await t.pumpWidget(host(c));
      c.enqueue(RoomEffect.gift(gift: _rose, senderName: 'Sam', senderId: 'a'));
      await t.pump();
      expect(find.text('🌹'), findsOneWidget);
      expect(find.text('Sam sent Rose'), findsOneWidget);

      // plays at the default 0.75x, so the 1.6 s burst takes about 2.1 s
      await t.pump(const Duration(milliseconds: 1700));
      expect(c.current, isNotNull, reason: 'slower than the file: still playing at 1.7 s');
      await t.pump(const Duration(milliseconds: 600));
      await t.pump();
      expect(find.text('🌹'), findsNothing);
      expect(c.current, isNull);
      c.dispose();
    });

    testWidgets('a gift set to 1x in the panel plays at the file\'s own speed', (t) async {
      final c = RoomEffectController();
      await t.pumpWidget(host(c));
      c.enqueue(
        RoomEffect.gift(
          gift: const Gift('g', 'Rose', '🌹', 10, playSpeed: 1),
          senderName: 'Sam',
          senderId: 'a',
        ),
      );
      await t.pump();
      expect(c.currentSpeed, 1);
      await t.pump(const Duration(milliseconds: 1700));
      await t.pump();
      expect(c.current, isNull);
      c.dispose();
    });

    testWidgets('a sound from the panel starts with the effect and stops when it ends', (t) async {
      final started = <String>[];
      var stopped = 0;
      final old = EffectSounds.starter;
      EffectSounds.starter = (url) {
        started.add(url);
        return _FakeSound(() => stopped++);
      };
      addTearDown(() => EffectSounds.starter = old);

      final c = RoomEffectController();
      await t.pumpWidget(host(c));
      c.enqueue(
        RoomEffect.gift(
          gift: const Gift('g', 'Rose', '🌹', 10, soundUrl: 'https://x.co/pop.mp3'),
          senderName: 'Sam',
          senderId: 'a',
        ),
      );
      await t.pump();
      expect(started, ['https://x.co/pop.mp3']);
      expect(stopped, 0);
      await t.pump(const Duration(milliseconds: 2400));
      await t.pump();
      expect(c.current, isNull);
      expect(stopped, 1);
      c.dispose();
    });

    testWidgets('a gift with no sound starts none', (t) async {
      var started = 0;
      final old = EffectSounds.starter;
      EffectSounds.starter = (url) {
        started++;
        return _FakeSound(() {});
      };
      addTearDown(() => EffectSounds.starter = old);
      final c = RoomEffectController();
      await t.pumpWidget(host(c));
      c.enqueue(RoomEffect.gift(gift: _rose, senderName: 'Sam', senderId: 'a'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 2400));
      expect(started, 0);
      c.dispose();
    });

    testWidgets('an entry shows who walked in', (t) async {
      final c = RoomEffectController();
      await t.pumpWidget(host(c));
      c.enqueue(
        RoomEffect.entry(
          item: StoreItem(id: 'i', category: StoreCategory.entryEffect, name: 'Fire Entry', emoji: '🔥', priceCoins: 1, durationDays: 7),
          senderName: 'Sam',
          senderId: 'a',
        ),
      );
      await t.pump();
      expect(find.text('Sam entered with Fire Entry'), findsOneWidget);
      expect(find.text('🔥'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 1700));
      c.dispose();
    });

    testWidgets('a combo shows its multiplier', (t) async {
      final c = RoomEffectController();
      await t.pumpWidget(host(c));
      c.enqueue(RoomEffect.gift(gift: _rose, senderName: 'You', senderId: 'me', count: 5));
      await t.pump();
      expect(find.text('You sent Rose x5'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 1700));
      c.dispose();
    });

    testWidgets('never swallows touches meant for the stream underneath', (t) async {
      final c = RoomEffectController();
      var taps = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(onTap: () => taps++, child: const ColoredBox(color: Colors.black)),
                ),
                Positioned.fill(child: RoomEffectLayer(controller: c)),
              ],
            ),
          ),
        ),
      );
      c.enqueue(RoomEffect.gift(gift: _rose, senderName: 'Sam', senderId: 'a'));
      await t.pump();
      await t.tapAt(const Offset(200, 300));
      expect(taps, 1);
      await t.pump(const Duration(milliseconds: 1700));
      c.dispose();
    });

    testWidgets('artwork that cannot be loaded falls back to the emoji', (t) async {
      final c = RoomEffectController();
      await t.pumpWidget(host(c));
      c.enqueue(
        RoomEffect.gift(
          gift: const Gift('g', 'Rose', '🌹', 10, iconUrl: 'https://x.co/none.png'),
          senderName: 'Sam',
          senderId: 'a',
        ),
      );
      await t.pump();
      // flutter_test answers every HTTP request with a 400, so the image errors.
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump();
      await t.pump();
      expect(find.text('🌹'), findsOneWidget, reason: 'the gift is still seen');
      await t.pump(const Duration(milliseconds: 2400));
      await t.pump();
      expect(c.current, isNull);
      c.dispose();
    });
  });

  group('RoomEffectController timing', () {
    test('the default speed is 0.75x and a panel speed wins', () {
      final c = RoomEffectController();
      c.enqueue(RoomEffect.gift(gift: _rose, senderName: 'A', senderId: 'a'));
      expect(c.currentSpeed, kDefaultEffectSpeed);
      c.finish(c.playId);
      c.enqueue(RoomEffect.gift(gift: const Gift('g2', 'Fast', 'F', 1, playSpeed: 1.5), senderName: 'A', senderId: 'a'));
      expect(c.currentSpeed, 1.5);
      c.dispose();
    });

    test('a busy room catches up: with enough waiting, slowed effects play at full speed', () {
      final c = RoomEffectController(catchUpAt: 2);
      c.enqueue(RoomEffect.gift(gift: _rose, senderName: 'A', senderId: 'a'));
      expect(c.currentSpeed, kDefaultEffectSpeed, reason: 'nobody waiting');
      c.enqueue(RoomEffect.gift(gift: _lion, senderName: 'B', senderId: 'b'));
      c.enqueue(RoomEffect.gift(gift: const Gift('g3', 'Star', 'S', 1), senderName: 'C', senderId: 'c'));
      c.enqueue(RoomEffect.gift(gift: const Gift('g4', 'Moon', 'M', 1), senderName: 'D', senderId: 'd'));
      c.finish(c.playId); // B starts with C and D waiting
      expect(c.currentSpeed, 1.0);
      c.finish(c.playId); // C starts with only D waiting
      expect(c.currentSpeed, kDefaultEffectSpeed);
      c.dispose();
    });

    test('once the file reports how long it runs, the guard is that long plus the margin', () async {
      final c = RoomEffectController(
        maxPlayTime: const Duration(milliseconds: 60),
        margin: const Duration(milliseconds: 60),
      );
      c.enqueue(RoomEffect.gift(gift: _rose, senderName: 'A', senderId: 'a'));
      c.reportDuration(c.playId, const Duration(milliseconds: 300));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(c.current, isNotNull, reason: 'longer than the load guard, still playing');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(c.current, isNull, reason: 'gave up after the expected length plus the margin');
      c.dispose();
    });

    test('a duration for an effect that already ended is ignored', () async {
      final c = RoomEffectController(maxPlayTime: const Duration(seconds: 5));
      c.enqueue(RoomEffect.gift(gift: _rose, senderName: 'A', senderId: 'a'));
      final first = c.playId;
      c.finish(first);
      c.enqueue(RoomEffect.gift(gift: _lion, senderName: 'B', senderId: 'b'));
      c.reportDuration(first, const Duration(milliseconds: 10)); // late word about the previous one
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.current?.name, 'Lion');
      c.dispose();
    });

    test('no effect is waited on longer than longestEffect, whatever its file claims', () async {
      final c = RoomEffectController(
        longestEffect: const Duration(milliseconds: 100),
        margin: const Duration(milliseconds: 50),
      );
      c.enqueue(RoomEffect.gift(gift: _rose, senderName: 'A', senderId: 'a'));
      c.reportDuration(c.playId, const Duration(hours: 3));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(c.current, isNull);
      c.dispose();
    });

    test('files are fetched as soon as the effect is queued', () {
      final fetched = <String>[];
      final c = RoomEffectController(prefetch: fetched.add);
      c.enqueue(
        RoomEffect.gift(
          gift: const Gift('g', 'Rose', 'R', 1, iconUrl: 'https://x.co/r.mp4', soundUrl: 'https://x.co/r.mp3'),
          senderName: 'A',
          senderId: 'a',
        ),
      );
      expect(fetched, ['https://x.co/r.mp4', 'https://x.co/r.mp3']);
      c.dispose();
    });

    test('my own entry plays at once, and my join row does not play it a second time', () async {
      final c = RoomEffectController(retryDelay: Duration.zero);
      final car = StoreItem(
        id: 'i-car', category: StoreCategory.vehicle, name: 'Sports Car',
        emoji: 'C', priceCoins: 1, durationDays: 7,
      );
      c.playOwnEntry([car], senderId: 'u-me');
      expect(c.current?.caption, 'You entered with Sports Car');
      final played = await c.onEntryRow(
        {'id': 5, 'sender_id': 'u-me', 'kind': 'system', 'entry_item_ids': ['i-car']},
        meId: 'u-me',
        senderName: 'Sam',
        loadItems: (ids) async => [car],
      );
      expect(played, isFalse);
      // ...but the level image on that same row still plays
      final level = await c.onEntryRow(
        {'id': 6, 'sender_id': 'u-me', 'kind': 'system', 'entry_item_ids': ['i-car'], 'level_image_url': 'https://x/lv.png'},
        meId: 'u-me',
        senderName: 'Sam',
        loadItems: (ids) async => [car],
      );
      expect(level, isTrue);
      c.finish(c.playId);
      expect(c.current?.caption, 'Sam joined');
      c.finish(c.playId);
      expect(c.current, isNull, reason: 'the car was not queued again');
      c.dispose();
    });

    test('an item lookup that fails once is tried again', () async {
      final c = RoomEffectController(retryDelay: const Duration(milliseconds: 5));
      final spark = StoreItem(
        id: 'i-spark', category: StoreCategory.entryEffect, name: 'Sparkle',
        emoji: 'S', priceCoins: 1, durationDays: 7,
      );
      var calls = 0;
      final played = await c.onEntryRow(
        {'id': 9, 'sender_id': 'u-other', 'kind': 'system', 'entry_item_ids': ['i-spark']},
        meId: 'u-me',
        senderName: 'Sam',
        loadItems: (ids) async {
          calls++;
          if (calls == 1) throw Exception('offline');
          return [spark];
        },
      );
      expect(played, isTrue);
      expect(calls, 2);
      expect(c.current?.name, 'Sparkle');
      c.dispose();
    });
  });
}

class _FakeSound implements EffectSound {
  _FakeSound(this.onStop);
  final void Function() onStop;
  @override
  Future<void> stop() async => onStop();
}
