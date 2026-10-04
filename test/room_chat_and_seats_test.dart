import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
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

    test('a seat that is freed stops matching its old uid', () {
      final speaking = SeatSpeaking()..bindSeat(3, 55);
      speaking.unbindSeat(3);
      expect(
        speaking.seatsFor([v(55, 90)], occupants: {}, hostId: 'h', mySeat: null, meMuted: false),
        isEmpty,
      );
    });
  });

  group('level image on join', () {
    test('a join row with only a level image plays it, full screen', () async {
      final c = RoomEffectController();
      final played = await c.onEntryRow(
        {'kind': 'system', 'id': 1, 'sender_id': 'u', 'level_image_url': 'https://x/lv.png'},
        meId: 'me',
        senderName: 'Asha',
        loadItems: (_) async => [],
      );
      expect(played, isTrue);
      expect(c.current?.fillScreen, isTrue);
      expect(c.current?.caption, 'Asha joined');
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
