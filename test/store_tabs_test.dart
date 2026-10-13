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
}
