import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/level_banner_images.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/data/store_repository.dart';
import 'package:sabalive/features/live/widgets/entry_catch_up.dart';
import 'package:sabalive/features/live/widgets/room_effect.dart';

class _NoItemsRepo extends Fake implements StoreRepository {
  @override
  Future<List<OwnedItem>> equippedFor(String userId) async => const [];
}

StoreItem _item(String id, StoreCategory c) =>
    StoreItem(id: id, category: c, name: id, emoji: 'E', priceCoins: 1, durationDays: 7);

void main() {
  final future = DateTime.now().add(const Duration(days: 3));
  final past = DateTime.now().subtract(const Duration(days: 1));

  test('the vehicle comes first, then the entry effect', () {
    final items = entryItemsFrom([
      OwnedItem(_item('spark', StoreCategory.entryEffect), future, true),
      OwnedItem(_item('car', StoreCategory.vehicle), future, true),
    ]);
    expect([for (final i in items) i.id], ['car', 'spark']);
  });

  test('expired, unequipped and non-entry items are left out', () {
    final items = entryItemsFrom([
      OwnedItem(_item('old', StoreCategory.vehicle), past, true),
      OwnedItem(_item('unworn', StoreCategory.entryEffect), future, false),
      OwnedItem(_item('frame', StoreCategory.frame), future, true),
      OwnedItem(_item('skin', StoreCategory.roomSkin), future, true),
      OwnedItem(_item('ok', StoreCategory.entryEffect), future, true),
    ]);
    expect([for (final i in items) i.id], ['ok']);
  });

  test('nothing equipped plays nothing', () {
    expect(entryItemsFrom(const []), isEmpty);
  });

  group('playMyEntry: my own level banner', () {
    final images = LevelBannerImages(loader: () async => [
          {'track': 'charm', 'level': 1, 'image_url': 'https://x/charm1.png'},
        ]);
    final me = AppUser(id: 'me', name: 'Me', username: '@me', charmLevel: 2);

    test('a viewer who joins sees their own banner at once', () async {
      final c = RoomEffectController();
      await playMyEntry(c, meId: 'me', me: me, repo: _NoItemsRepo(), images: images);
      expect(c.banners.current?.imageUrl, 'https://x/charm1.png');
      expect(c.banners.current?.name, 'Me');
      c.dispose();
    });

    test('nothing set in the panel for their levels: no banner', () async {
      final c = RoomEffectController();
      await playMyEntry(c, meId: 'me', me: me, repo: _NoItemsRepo(), images: LevelBannerImages(loader: () async => []));
      expect(c.banners.current, isNull);
      c.dispose();
    });

    test('a ghost joins invisibly: no banner', () async {
      final c = RoomEffectController();
      final ghost = AppUser(id: 'g', name: 'G', username: '@g', isGhost: true);
      await playMyEntry(c, meId: 'g', me: ghost, repo: _NoItemsRepo(), images: images);
      expect(c.banners.current, isNull);
      c.dispose();
    });

    test('without knowing who I am, only the entry items are handled', () async {
      final c = RoomEffectController();
      await playMyEntry(c, meId: 'me', repo: _NoItemsRepo(), images: images);
      expect(c.banners.current, isNull);
      c.dispose();
    });
  });
}
