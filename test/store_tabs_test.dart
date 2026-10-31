import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/store_repository.dart';
import 'package:sabalive/features/wallet/store_screen.dart';

void main() {
  test('the Store has a Room Skin tab and no Garage', () {
    final labels = [for (final (_, label) in storeTabs) label];
    expect(labels, ['Frame', 'Lucky ID', 'Entry', 'Room Skin']);
    expect(storeTabs.map((t) => t.$1), isNot(contains(StoreCategory.vehicle)));
    expect(storeTabs.map((t) => t.$1), contains(StoreCategory.roomSkin));
  });

  test('a Store item with price 0 says Free; a paid one shows its coins', () {
    expect(storePriceLabel(0), 'Free');
    expect(storePriceLabel(150), '150 coins');
    expect(storePriceLabel(4000), '4,000 coins');
  });

  test('the message after getting an item says it was added, not bought, when it was free', () {
    expect(storeGotMessage('Starry Night', 0), 'Starry Night added to your Bag!');
    expect(storeGotMessage('Starry Night', 4000), 'Starry Night purchased!');
  });
}
