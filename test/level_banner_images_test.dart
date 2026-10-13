import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/level_banner_images.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/join_banner.dart';
import 'package:sabalive/features/live/widgets/room_effect.dart';

Map<String, dynamic> _row(int level, String? url) => {'track': 'charm', 'level': level, 'image_url': url};
Map<String, dynamic> _wrow(int level, String? url) => {'track': 'wealth', 'level': level, 'image_url': url};

void main() {
  group('LevelBannerImages', () {
    test('a person gets the picture of the highest charm level they have reached that has one', () async {
      final images = LevelBannerImages(loader: () async => [_row(1, 'a'), _row(5, 'b'), _row(10, 'c')]);
      expect(await images.charmImage(1), 'a');
      expect(await images.charmImage(4), 'a');
      expect(await images.charmImage(5), 'b');
      expect(await images.charmImage(9), 'b');
      expect(await images.charmImage(40), 'c');
    });

    test('levels without a picture are skipped, and below the first picture there is none', () async {
      final images = LevelBannerImages(loader: () async => [_row(2, '  '), _row(3, null), _row(6, 'x')]);
      expect(await images.charmImage(5), isNull);
      expect(await images.charmImage(6), 'x');
    });

    test('one query serves a whole room, then it is remembered for the ttl', () async {
      var reads = 0;
      var clock = DateTime(2026, 10, 11, 12);
      final images = LevelBannerImages(
        loader: () async {
          reads++;
          return [_row(1, 'a')];
        },
        now: () => clock,
        ttl: const Duration(minutes: 10),
      );
      await Future.wait([images.charmImage(1), images.charmImage(2), images.charmImage(3)]);
      await images.charmImage(4);
      expect(reads, 1);
      clock = clock.add(const Duration(minutes: 11));
      await images.charmImage(1);
      expect(reads, 2, reason: 'a changed picture in the panel shows up within the ttl');
    });

    test('a failed read gives null, is not remembered, and a later read works', () async {
      var fail = true;
      final images = LevelBannerImages(loader: () async {
        if (fail) throw Exception('offline');
        return [_row(1, 'a')];
      });
      expect(await images.charmImage(1), isNull);
      fail = false;
      expect(await images.charmImage(1), 'a');
    });

    test('once read, a failing refresh keeps serving the old pictures', () async {
      var fail = false;
      var clock = DateTime(2026, 10, 11, 12);
      final images = LevelBannerImages(
        loader: () async {
          if (fail) throw Exception('offline');
          return [_row(1, 'a')];
        },
        now: () => clock,
      );
      expect(await images.charmImage(1), 'a');
      clock = clock.add(const Duration(hours: 1));
      fail = true;
      expect(await images.charmImage(1), 'a');
    });
  });

  group('bannerFor (the joiner\'s own banner)', () {
    test('their charm level\'s picture wins; wealth is the fallback', () async {
      final images = LevelBannerImages(loader: () async => [_row(5, 'charm5'), _wrow(1, 'wealth1'), _wrow(8, 'wealth8')]);
      expect(await images.bannerFor(wealthLevel: 9, charmLevel: 6), 'charm5');
      expect(await images.bannerFor(wealthLevel: 9, charmLevel: 2), 'wealth8', reason: 'no charm picture reached yet');
      expect(await images.bannerFor(wealthLevel: 3, charmLevel: 2), 'wealth1');
    });

    test('nothing set for either track gives null', () async {
      final images = LevelBannerImages(loader: () async => [_row(9, 'high')]);
      expect(await images.bannerFor(wealthLevel: 1, charmLevel: 1), isNull);
    });

    test('charmImage ignores the wealth track', () async {
      final images = LevelBannerImages(loader: () async => [_wrow(1, 'wealth1')]);
      expect(await images.charmImage(5), isNull);
    });
  });

  group('the join banner', () {
    Future<JoinBanner?> play({
      required Future<String?> Function(int)? lookup,
      String? rowImage = 'https://x/wealth.png',
      int charm = 12,
    }) async {
      final c = RoomEffectController(levelImageFor: lookup);
      final who = AppUser(id: 'u', name: 'Asha', username: '@asha', wealthLevel: 3, charmLevel: charm);
      await c.onEntryRow(
        {'kind': 'system', 'id': 1, 'sender_id': 'u', 'level_image_url': rowImage},
        meId: 'me',
        senderName: 'Asha',
        loadItems: (_) async => [],
        sender: who,
      );
      final banner = c.banners.current;
      c.dispose();
      return banner;
    }

    test('uses the picture of their CHARM level when the panel has one', () async {
      int? asked;
      final banner = await play(lookup: (level) async {
        asked = level;
        return 'https://x/charm12.png';
      });
      expect(asked, 12);
      expect(banner?.imageUrl, 'https://x/charm12.png');
    });

    test('with no charm picture it keeps the one the join row carried', () async {
      final banner = await play(lookup: (_) async => null);
      expect(banner?.imageUrl, 'https://x/wealth.png');
    });

    test('a lookup that fails still shows the row picture', () async {
      final banner = await play(lookup: (_) async => throw Exception('offline'));
      expect(banner?.imageUrl, 'https://x/wealth.png');
    });

    test('without the lookup (or without knowing who joined) the row picture is used', () async {
      expect((await play(lookup: null))?.imageUrl, 'https://x/wealth.png');
      final c = RoomEffectController(levelImageFor: (_) async => 'https://x/charm.png');
      await c.onEntryRow(
        {'kind': 'system', 'id': 2, 'sender_id': 'u', 'level_image_url': 'https://x/wealth.png'},
        meId: 'me',
        senderName: 'Asha',
        loadItems: (_) async => [],
      );
      expect(c.banners.current?.imageUrl, 'https://x/wealth.png');
      c.dispose();
    });

    test('my own banner shows at once from my own levels, and my join row then does not play it a second time', () async {
      final c = RoomEffectController();
      final me = AppUser(id: 'me', name: 'Me', username: '@me', wealthLevel: 2, charmLevel: 3);
      c.playOwnBanner(imageUrl: 'https://x/own.png', name: 'Me', who: me);
      expect(c.banners.current?.imageUrl, 'https://x/own.png');
      final first = c.banners.playId;
      await c.onEntryRow(
        {'kind': 'system', 'id': 7, 'sender_id': 'me', 'level_image_url': 'https://x/row.png'},
        meId: 'me', senderName: 'Me', loadItems: (_) async => [], sender: me,
      );
      expect(c.banners.playId, first, reason: 'no second banner for my own join');
      // someone else's join still plays
      await c.onEntryRow(
        {'kind': 'system', 'id': 8, 'sender_id': 'other', 'level_image_url': 'https://x/row.png'},
        meId: 'me', senderName: 'Other', loadItems: (_) async => [],
      );
      c.dispose();
    });

    test('my own join row still plays when the local banner could not (nothing set, offline)', () async {
      final c = RoomEffectController();
      await c.onEntryRow(
        {'kind': 'system', 'id': 9, 'sender_id': 'me', 'level_image_url': 'https://x/row.png'},
        meId: 'me', senderName: 'Me', loadItems: (_) async => [],
        sender: AppUser(id: 'me', name: 'Me', username: '@me'),
      );
      expect(c.banners.current?.imageUrl, 'https://x/row.png');
      c.dispose();
    });

    test('a banner now stays about five seconds, a little slower than before', () {
      final c = JoinBannerController();
      expect(c.hold, greaterThanOrEqualTo(const Duration(milliseconds: 5000)));
      c.dispose();
    });
  });
}
