import 'dart:async';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/data/store_repository.dart';
import 'package:sabalive/features/live/widgets/room_chat_state.dart';
import 'package:sabalive/features/live/widgets/room_effect.dart';
import 'package:sabalive/features/live/widgets/seat_speaking.dart';

AppUser _u(String id) => AppUser(id: id, name: id, username: '@$id');

void main() {
  group('RoomChatState', () {
    test('reads the pinned notice, and a blank one means none', () {
      final s = RoomChatState();
      s.apply({'pinned_notice': ' Welcome '}, initial: true);
      expect(s.notice, 'Welcome');
      s.apply({'pinned_notice': '  '});
      expect(s.notice, isNull);
    });

    test('a newer chat_cleared_at clears the chat, an old or repeated one does not', () {
      final s = RoomChatState();
      expect(s.apply({'chat_cleared_at': '2026-10-04T10:00:00Z'}, initial: true), isFalse);
      expect(s.apply({'chat_cleared_at': '2026-10-04T10:00:00Z'}), isFalse);
      expect(s.apply({'chat_cleared_at': '2026-10-04T10:05:00Z'}), isTrue);
      expect(s.apply({'chat_cleared_at': '2026-10-04T10:01:00Z'}), isFalse);
    });

    test('an update row without the fields changes nothing', () {
      final s = RoomChatState()..apply({'pinned_notice': 'hi'}, initial: true);
      expect(s.apply({'viewer_count': 3}), isFalse);
      expect(s.notice, 'hi');
    });
  });

  group('SeatSpeaking', () {
    AudioVolumeInfo v(int uid, int volume) => AudioVolumeInfo(uid: uid, volume: volume);

    test('maps a seat holder, the host and this device to their seats', () {
      final speaking = SeatSpeaking()
        ..hostUid = 7
        ..bindSeat(3, 55);
      final seats = speaking.seatsFor(
        [v(55, 90), v(7, 60), v(0, 80)],
        occupants: {1: _u('host'), 3: _u('guest'), 4: _u('me')},
        hostId: 'host',
        mySeat: 4,
        meMuted: false,
      );
      expect(seats, {1, 3, 4});
    });

    test('quiet speakers, a muted me and unknown uids light nothing', () {
      final speaking = SeatSpeaking()..bindSeat(3, 55);
      final seats = speaking.seatsFor(
        [v(55, 5), v(0, 100), v(999, 100)],
        occupants: {3: _u('guest')},
        hostId: 'host',
        mySeat: 4,
        meMuted: true,
      );
      expect(seats, isEmpty);
    });

    test('Agora uids above 2^31 (about half of them) still match, whichever sign they arrive with', () {
      const hostBig = 4287323012; // the largest uid seen in production
      const guestBig = 3000000001;
      int signed32(int uid) => uid - 0x100000000; // the same uid as a signed 32-bit number
      final speaking = SeatSpeaking()
        ..hostUid = signed32(hostBig) // stored one way...
        ..bindSeat(3, guestBig);
      expect(
        speaking.seatsFor(
          [v(hostBig, 90), v(signed32(guestBig), 90)], // ...reported the other way
          occupants: {1: _u('host'), 3: _u('guest')},
          hostId: 'host',
          mySeat: null,
          meMuted: false,
        ),
        {1, 3},
      );
    });

    test('hostTalking: the host heard remotely, or this device when I am the host', () {
      final speaking = SeatSpeaking()..hostUid = 7;
      expect(speaking.hostTalking([v(7, 60)], iAmHost: false, meMuted: false), isTrue);
      expect(speaking.hostTalking([v(7, 5)], iAmHost: false, meMuted: false), isFalse);
      expect(speaking.hostTalking([v(8, 90)], iAmHost: false, meMuted: false), isFalse);
      expect(speaking.hostTalking([v(0, 90)], iAmHost: false, meMuted: false), isFalse,
          reason: 'my own voice is not the host\'s when I am a viewer');
      expect(speaking.hostTalking([v(0, 90)], iAmHost: true, meMuted: false), isTrue);
      expect(speaking.hostTalking([v(0, 90)], iAmHost: true, meMuted: true), isFalse);
    });

    test('another person\'s quieter voice (it arrives over the network) still lights their seat; this device\'s needs more', () {
      final speaking = SeatSpeaking()..bindSeat(3, 55);
      Set<int> seats(List<AudioVolumeInfo> v) => speaking.seatsFor(
            v,
            occupants: {3: _u('guest'), 4: _u('me')},
            hostId: 'host',
            mySeat: 4,
            meMuted: false,
          );
      expect(seats([v(55, 14)]), {3}, reason: 'a quiet remote voice');
      expect(seats([v(55, 6)]), isEmpty, reason: 'room noise');
      expect(seats([v(0, 14)]), isEmpty, reason: 'my own microphone must be louder than that');
      expect(seats([v(0, 40)]), {4});
      expect(speaking.hostTalking([v(7, 14)], iAmHost: false, meMuted: false), isFalse, reason: 'host uid unknown');
      speaking.hostUid = 7;
      expect(speaking.hostTalking([v(7, 14)], iAmHost: false, meMuted: false), isTrue);
    });

    test('a speaker whose seat is unknown is remembered, so the screen can re-read the seats (at most every few seconds)', () {
      final speaking = SeatSpeaking()
        ..hostUid = 7
        ..bindSeat(3, 55);
      speaking.seatsFor(
        [v(55, 90), v(999, 90), v(7, 90)],
        occupants: {1: _u('host'), 3: _u('guest')},
        hostId: 'host',
        mySeat: null,
        meMuted: false,
      );
      expect(speaking.unmapped, {999}, reason: 'the seat holder and the host are known; 999 is not');
      final t0 = DateTime(2026, 10, 12, 10);
      expect(speaking.needsSeatRefresh(now: t0), isTrue);
      expect(speaking.needsSeatRefresh(now: t0.add(const Duration(seconds: 2))), isFalse, reason: 'not again so soon');
      expect(speaking.needsSeatRefresh(now: t0.add(const Duration(seconds: 5))), isTrue);
      // nobody unknown speaking: nothing to refresh
      speaking.seatsFor([v(55, 90)], occupants: {3: _u('guest')}, hostId: 'host', mySeat: null, meMuted: false);
      expect(speaking.unmapped, isEmpty);
      expect(speaking.needsSeatRefresh(now: t0.add(const Duration(minutes: 1))), isFalse);
    });

    test('a voice that can never be matched stops triggering seat re-reads after three tries, for a minute', () {
      final speaking = SeatSpeaking()..hostUid = 7;
      void speak() => speaking.seatsFor([v(999, 90)], occupants: {}, hostId: 'host', mySeat: null, meMuted: false);
      final t0 = DateTime(2026, 10, 12, 10);
      speak();
      expect(speaking.needsSeatRefresh(now: t0), isTrue);
      speak();
      expect(speaking.needsSeatRefresh(now: t0.add(const Duration(seconds: 5))), isTrue);
      speak();
      expect(speaking.needsSeatRefresh(now: t0.add(const Duration(seconds: 10))), isTrue);
      speak();
      expect(speaking.needsSeatRefresh(now: t0.add(const Duration(seconds: 15))), isFalse, reason: 'three tries, still unknown');
      expect(speaking.needsSeatRefresh(now: t0.add(const Duration(seconds: 40))), isFalse);
      speak();
      expect(speaking.needsSeatRefresh(now: t0.add(const Duration(minutes: 2))), isTrue, reason: 'a minute later it may have changed');
    });

    test('a seat that is freed stops matching its old uid', () {
      final speaking = SeatSpeaking()..bindSeat(3, 55);
      speaking.unbindSeat(3);
      expect(
        speaking.seatsFor([v(55, 90)], occupants: {}, hostId: 'h', mySeat: null, meMuted: false),
        isEmpty,
      );
      expect(speaking.seatOfUid(55), isNull);
    });

    test('seatOfUid finds the seat of a big uid whichever sign it arrives with', () {
      const big = 3000000001;
      final speaking = SeatSpeaking()..bindSeat(4, big);
      expect(speaking.seatOfUid(big), 4);
      expect(speaking.seatOfUid(big - 0x100000000), 4);
      expect(speaking.seatOfUid(12), isNull);
    });
  });

  group('level image on join', () {
    test('a join row with a level image plays a banner strip, not a full-screen effect', () async {
      final c = RoomEffectController();
      final played = await c.onEntryRow(
        {'kind': 'system', 'id': 1, 'sender_id': 'u', 'level_image_url': 'https://x/lv.png'},
        meId: 'me',
        senderName: 'Asha',
        loadItems: (_) async => [],
      );
      expect(played, isTrue);
      expect(c.current, isNull, reason: 'nothing in the full-screen effect lane');
      expect(c.banners.current?.name, 'Asha');
      expect(c.banners.current?.imageUrl, 'https://x/lv.png');
      c.dispose();
    });

    test('the banner carries who joined, for their avatar, frame and level stars', () async {
      final c = RoomEffectController();
      final asha = AppUser(id: 'u', name: 'Asha', username: '@asha', wealthLevel: 7, charmLevel: 3);
      await c.onEntryRow(
        {'kind': 'system', 'id': 3, 'sender_id': 'u', 'level_image_url': 'https://x/lv.png'},
        meId: 'me',
        senderName: 'Asha',
        loadItems: (_) async => [],
        sender: asha,
      );
      expect(c.banners.current?.who?.wealthLevel, 7);
      c.dispose();
    });

    test('a vehicle and a banner for the same join run side by side', () async {
      final c = RoomEffectController();
      final car = StoreItem(id: 'i-car', category: StoreCategory.vehicle, name: 'Car', emoji: 'C', priceCoins: 1, durationDays: 7);
      await c.onEntryRow(
        {'kind': 'system', 'id': 4, 'sender_id': 'u', 'entry_item_ids': ['i-car'], 'level_image_url': 'https://x/lv.png'},
        meId: 'me',
        senderName: 'Asha',
        loadItems: (_) async => [car],
      );
      expect(c.current?.name, 'Car');
      expect(c.banners.current?.name, 'Asha');
      c.dispose();
    });

    test('my own entry is claimed the moment my join row is seen: a local play finishing during its loads adds nothing', () async {
      final c = RoomEffectController();
      final car = StoreItem(id: 'i-car', category: StoreCategory.vehicle, name: 'Car', emoji: 'C', priceCoins: 1, durationDays: 7);
      final me = AppUser(id: 'me', name: 'Me', username: '@me');
      final loading = Completer<List<StoreItem>>();
      // the row arrives first and is still loading its items...
      final rowDone = c.onEntryRow(
        {'kind': 'system', 'id': 20, 'sender_id': 'me', 'entry_item_ids': ['i-car'], 'level_image_url': 'https://x/l.png'},
        meId: 'me', senderName: 'Me', loadItems: (_) => loading.future, sender: me,
      );
      // ...when my own local play (from what I have equipped) lands
      c.playOwnEntry([car], senderId: 'me');
      c.playOwnBanner(imageUrl: 'https://x/own.png', name: 'Me', who: me);
      loading.complete([car]);
      await rowDone;
      var vehicles = 0;
      while (c.current != null) {
        vehicles++;
        c.finish(c.playId);
      }
      expect(vehicles, 1, reason: 'the vehicle plays once');
      expect(c.banners.current?.imageUrl, 'https://x/l.png', reason: 'one banner, the row\'s');
      c.banners.finish(c.banners.playId);
      expect(c.banners.current, isNull, reason: 'and no second banner behind it');
      c.dispose();
    });

    test('and the other way round: local first, then the row, still once', () async {
      final c = RoomEffectController();
      final car = StoreItem(id: 'i-car', category: StoreCategory.vehicle, name: 'Car', emoji: 'C', priceCoins: 1, durationDays: 7);
      final me = AppUser(id: 'me', name: 'Me', username: '@me');
      c.playOwnEntry([car], senderId: 'me');
      c.playOwnBanner(imageUrl: 'https://x/own.png', name: 'Me', who: me);
      await c.onEntryRow(
        {'kind': 'system', 'id': 21, 'sender_id': 'me', 'entry_item_ids': ['i-car'], 'level_image_url': 'https://x/l.png'},
        meId: 'me', senderName: 'Me', loadItems: (_) async => [car], sender: me,
      );
      var vehicles = 0;
      while (c.current != null) {
        vehicles++;
        c.finish(c.playId);
      }
      expect(vehicles, 1);
      expect(c.banners.current?.imageUrl, 'https://x/own.png');
      c.banners.finish(c.banners.playId);
      expect(c.banners.current, isNull);
      c.dispose();
    });

    test('a join row with neither entry items nor a level image plays nothing', () async {
      final c = RoomEffectController();
      final played = await c.onEntryRow(
        {'kind': 'system', 'id': 2, 'sender_id': 'u'},
        meId: 'me',
        senderName: 'Asha',
        loadItems: (_) async => [],
      );
      expect(played, isFalse);
      expect(c.current, isNull);
      c.dispose();
    });
  });
}
