import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/store_repository.dart';
import 'package:sabalive/features/live/widgets/entry_catch_up.dart';

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
}
