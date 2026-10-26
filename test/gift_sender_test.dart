import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/gift_sender.dart';
import 'package:sabalive/data/models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A gift with a quantity is ONE action: what is called, what happens against a database that does not have the new functions yet, and what is refused.
void main() {
  const rose = Gift('11111111-1111-1111-1111-111111111111', 'Rose', '🌹', 10);
  final host = AppUser(id: '22222222-2222-2222-2222-222222222222', name: 'Host', username: '@h');
  final guest = AppUser(id: '33333333-3333-3333-3333-333333333333', name: 'Guest', username: '@g');
  const live = '44444444-4444-4444-4444-444444444444';

  PostgrestException missing(String fn) => PostgrestException(message: 'Could not find the function public.$fn in the schema cache', code: 'PGRST202');

  group('one gift with a quantity', () {
    test('is ONE call to the new function, with the quantity', () async {
      final calls = <(String, Map<String, dynamic>)>[];
      final sender = GiftSender(rpc: (fn, p) async {
        calls.add((fn, p));
        return 10;
      });
      await sender.send(rose, host, liveStreamId: live, quantity: 10);
      expect(calls, hasLength(1));
      expect(calls.single.$1, 'send_gift_v2');
      expect(calls.single.$2, {'p_gift_id': rose.id, 'p_receiver_id': host.id, 'p_live_stream_id': live, 'p_quantity': 10});
    });

    test('against a database without the new function it falls back to one call per unit', () async {
      final calls = <String>[];
      final sender = GiftSender(rpc: (fn, p) async {
        calls.add(fn);
        if (fn == 'send_gift_v2') throw missing(fn);
        return null;
      });
      await sender.send(rose, host, liveStreamId: live, quantity: 3);
      expect(calls, ['send_gift_v2', 'send_gift', 'send_gift', 'send_gift']);
    });

    test('a real refusal (not enough coins) is passed on and is NOT retried with the old function (nothing is charged twice)', () async {
      final calls = <String>[];
      final sender = GiftSender(rpc: (fn, p) async {
        calls.add(fn);
        throw const PostgrestException(message: 'Insufficient coins', code: 'P0001');
      });
      await expectLater(sender.send(rose, host, liveStreamId: live, quantity: 10), throwsA(isA<PostgrestException>()));
      expect(calls, ['send_gift_v2']);
    });

    test('a demo host (mock data) is refused with a clear message and nothing is called', () async {
      var called = 0;
      final sender = GiftSender(rpc: (fn, p) async => called++);
      final demo = AppUser(id: 'demo-1', name: 'Demo', username: '@d');
      await expectLater(sender.send(rose, demo, quantity: 2), throwsA(predicate((e) => '$e'.contains("can't be sent yet"))));
      expect(called, 0);
    });
  });

  group('Send to All with a quantity', () {
    test('is ONE call to send_gift_to_all_v3 (the sender included) and returns how many people got it', () async {
      final calls = <(String, Map<String, dynamic>)>[];
      final sender = GiftSender(rpc: (fn, p) async {
        calls.add((fn, p));
        return 5;
      });
      final n = await sender.sendToAll(rose, liveStreamId: live, quantity: 10, fallbackRecipients: [host, guest]);
      expect(n, 5);
      expect(calls.single.$1, 'send_gift_to_all_v3');
      expect(calls.single.$2, {'p_gift_id': rose.id, 'p_live_stream_id': live, 'p_quantity': 10});
    });

    test('against a database without v3 it uses v2 (the sender is left out there, as before)', () async {
      final calls = <String>[];
      final sender = GiftSender(rpc: (fn, p) async {
        calls.add(fn);
        if (fn == 'send_gift_to_all_v3') throw missing(fn);
        return 4;
      });
      final n = await sender.sendToAll(rose, liveStreamId: live, quantity: 10, fallbackRecipients: [host]);
      expect(n, 4);
      expect(calls, ['send_gift_to_all_v3', 'send_gift_to_all_v2']);
    });

    test('without v3 and v2 it uses the old Send to All once per unit', () async {
      final calls = <String>[];
      final sender = GiftSender(rpc: (fn, p) async {
        calls.add(fn);
        if (fn == 'send_gift_to_all_v3' || fn == 'send_gift_to_all_v2') throw missing(fn);
        return 4;
      });
      final n = await sender.sendToAll(rose, liveStreamId: live, quantity: 2, fallbackRecipients: [host]);
      expect(n, 4);
      expect(calls, ['send_gift_to_all_v3', 'send_gift_to_all_v2', 'send_gift_to_all', 'send_gift_to_all']);
    });

    test('without either it sends one gift per person per unit', () async {
      final calls = <String>[];
      final sender = GiftSender(currentUserId: () => null, rpc: (fn, p) async {
        calls.add(fn);
        if (fn == 'send_gift_to_all_v3' || fn == 'send_gift_to_all_v2' || fn == 'send_gift_to_all') throw missing(fn);
        return null;
      });
      final n = await sender.sendToAll(rose, liveStreamId: live, quantity: 2, fallbackRecipients: [host, guest]);
      expect(n, 2);
      expect(calls.where((c) => c == 'send_gift'), hasLength(4), reason: '2 people x 2');
    });

    test('the fallback never sends a gift to myself', () async {
      final to = <String>[];
      final sender = GiftSender(
        currentUserId: () => host.id,
        rpc: (fn, p) async {
          if (fn == 'send_gift_to_all_v3' || fn == 'send_gift_to_all_v2' || fn == 'send_gift_to_all') throw missing(fn);
          to.add(p['p_receiver_id'] as String);
          return null;
        },
      );
      final n = await sender.sendToAll(rose, liveStreamId: live, fallbackRecipients: [host, guest]);
      expect(n, 1);
      expect(to, [guest.id]);
    });

    test('a short balance is a real refusal: passed on, never retried', () async {
      final calls = <String>[];
      final sender = GiftSender(rpc: (fn, p) async {
        calls.add(fn);
        throw const PostgrestException(message: 'Insufficient coins', code: 'P0001');
      });
      await expectLater(sender.sendToAll(rose, liveStreamId: live, quantity: 10, fallbackRecipients: [host]), throwsA(isA<PostgrestException>()));
      expect(calls, ['send_gift_to_all_v3']);
    });
  });
}
