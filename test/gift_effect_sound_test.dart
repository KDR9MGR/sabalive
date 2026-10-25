import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/media/effect_sound.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/room_effect.dart';

/// A gift's sound is for the people it was sent to; a combo plays once with its quantity and says how many people got it.
void main() {
  const rose = Gift('g-rose', 'Rose', '🌹', 10, soundUrl: 'https://x.co/pop.mp3');
  const me = 'me';

  Map<String, dynamic> row({Object? receivers, bool toAll = false, Object? count, String sender = 'sam'}) => {
        'id': 1,
        'kind': 'gift',
        'gift_id': 'g-rose',
        'sender_id': sender,
        'to_all': toAll,
        'gift_count': count,
        'gift_receiver_ids': receivers,
      };

  RoomEffect? first(RoomEffectController c) => c.current;

  group('who hears the sound (from the chat row)', () {
    test('a receiver hears it', () {
      final c = RoomEffectController();
      c.onChatRow(row(receivers: ['me', 'x']), meId: me, senderName: 'Sam', giftById: (_) => rose);
      expect(first(c)!.playSound, isTrue);
      c.dispose();
    });

    test('everybody else sees it silently', () {
      final c = RoomEffectController();
      c.onChatRow(row(receivers: ['x', 'y']), meId: me, senderName: 'Sam', giftById: (_) => rose);
      expect(first(c)!.playSound, isFalse);
      c.dispose();
    });

    test('a row from an older app does not say who got it: it plays as it always did', () {
      final c = RoomEffectController();
      c.onChatRow(row(), meId: me, senderName: 'Sam', giftById: (_) => rose);
      expect(first(c)!.playSound, isTrue);
      c.dispose();
    });

    test('nobody signed in hears nothing when receivers are listed', () {
      final c = RoomEffectController();
      c.onChatRow(row(receivers: ['x']), meId: null, senderName: 'Sam', giftById: (_) => rose);
      expect(first(c)!.playSound, isFalse);
      c.dispose();
    });

    test('the sender plays their own gift from their own phone (not the row), and it is silent', () {
      final e = RoomEffect.gift(gift: rose, senderName: 'You', senderId: me, playSound: false);
      expect(e.playSound, isFalse);
      final c = RoomEffectController();
      expect(c.onChatRow(row(sender: me, receivers: ['x']), meId: me, senderName: 'You', giftById: (_) => rose), isFalse, reason: 'their own row is ignored: already played');
      c.dispose();
    });
  });

  group('the quantity and the number of people', () {
    test('a x10 row is one combo of 10', () {
      final c = RoomEffectController();
      c.onChatRow(row(receivers: ['me'], count: 10), meId: me, senderName: 'Sam', giftById: (_) => rose);
      expect(first(c)!.count, 10);
      c.dispose();
    });

    test('a gift to everyone says how many people and the multiplier, always', () {
      final c = RoomEffectController();
      c.onChatRow(row(receivers: ['me', 'a', 'b', 'c', 'd'], toAll: true, count: 10), meId: me, senderName: 'Sam', giftById: (_) => rose);
      expect(first(c)!.recipientCount, 5);
      expect(first(c)!.caption, 'Sam sent 10x Rose to 5 people');
      c.dispose();
      final c1 = RoomEffectController();
      c1.onChatRow(row(receivers: ['me'], toAll: true, count: 1), meId: me, senderName: 'Sam', giftById: (_) => rose);
      expect(first(c1)!.caption, 'Sam sent 1x Rose to 1 person');
      c1.dispose();
    });

    test('older captions are unchanged', () {
      expect(RoomEffect.gift(gift: rose, senderName: 'Sam', toAll: true).caption, 'Sam sent Rose to All');
      expect(RoomEffect.gift(gift: rose, senderName: 'Sam', toAll: true, count: 3).caption, 'Sam sent Rose x3 to All');
      expect(RoomEffect.gift(gift: rose, senderName: 'Sam', count: 3).caption, 'Sam sent Rose x3');
    });

    test('an odd count is read safely', () {
      final c = RoomEffectController();
      c.onChatRow(row(receivers: ['me'], count: 0), meId: me, senderName: 'Sam', giftById: (_) => rose);
      expect(first(c)!.count, 1);
      c.dispose();
    });
  });

  group('parseUuidSet', () {
    test('a list, a Postgres array text, an empty one, and nothing', () {
      expect(parseUuidSet(['a', 'b', 5]), {'a', 'b'});
      expect(parseUuidSet('{a,b}'), {'a', 'b'});
      expect(parseUuidSet('{"a", "b"}'), {'a', 'b'});
      expect(parseUuidSet('{}'), <String>{});
      expect(parseUuidSet(<String>[]), <String>{});
      expect(parseUuidSet(null), isNull);
      expect(parseUuidSet(42), isNull);
    });
  });

  group('on screen', () {
    Widget host(RoomEffectController c) => MaterialApp(home: Scaffold(body: Stack(children: [RoomEffectLayer(controller: c)])));

    testWidgets('a gift whose sound is not for this phone starts no sound; one that is, does', (t) async {
      final started = <String>[];
      final old = EffectSounds.starter;
      EffectSounds.starter = (url) {
        started.add(url);
        return _Quiet();
      };
      addTearDown(() => EffectSounds.starter = old);

      final c = RoomEffectController();
      await t.pumpWidget(host(c));
      c.enqueue(RoomEffect.gift(gift: rose, senderName: 'Sam', senderId: 'a', playSound: false));
      await t.pump();
      await t.pump(const Duration(milliseconds: 2400));
      expect(started, isEmpty, reason: 'silent for everybody who is not a receiver');
      c.enqueue(RoomEffect.gift(gift: rose, senderName: 'Sam', senderId: 'a'));
      await t.pump();
      expect(started, ['https://x.co/pop.mp3']);
      await t.pump(const Duration(milliseconds: 2400));
      c.dispose();
    });

    testWidgets('a silent and an audible gift from the same sender are not merged into one combo', (t) async {
      final c = RoomEffectController();
      await t.pumpWidget(host(c));
      c.enqueue(RoomEffect.gift(gift: rose, senderName: 'Sam', senderId: 'a'));
      c.enqueue(RoomEffect.gift(gift: rose, senderName: 'Sam', senderId: 'a', playSound: false));
      c.enqueue(RoomEffect.gift(gift: rose, senderName: 'Sam', senderId: 'a', playSound: false));
      await t.pump();
      expect(c.current!.count, 1);
      await t.pump(const Duration(milliseconds: 2400));
      c.dispose();
    });
  });
}

class _Quiet implements EffectSound {
  @override
  Future<void> stop() async {}
}
