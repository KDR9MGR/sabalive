import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/store_repository.dart';
import 'package:sabalive/features/live/widgets/room_skin_sheet.dart';

StoreItem _skin(String id, String name) =>
    StoreItem(id: id, category: StoreCategory.roomSkin, name: name, emoji: 'S', priceCoins: 1, durationDays: 30);

class _FakeRepo extends Fake implements StoreRepository {
  _FakeRepo(this.owned);
  List<OwnedItem> owned;
  final calls = <String>[];
  Object? failWith;

  @override
  Future<List<OwnedItem>> myItems() async => owned;

  @override
  Future<void> setEquipped(String itemId, bool equipped) async {
    if (failWith != null) throw failWith!;
    calls.add('$itemId:$equipped');
    // what set_item_equipped does: one skin on at a time
    owned = [
      for (final o in owned)
        OwnedItem(o.item, o.expiresAt, o.item.id == itemId ? equipped : (equipped ? false : o.equipped)),
    ];
  }
}

void main() {
  final future = DateTime.now().add(const Duration(days: 5));
  Widget host(_FakeRepo repo, {VoidCallback? onOpenStore}) => MaterialApp(
        home: Scaffold(body: RoomSkinSheet(repo: repo, onOpenStore: onOpenStore)),
      );

  testWidgets('lists the skins the host owns, marks the one that is on', (t) async {
    final repo = _FakeRepo([
      OwnedItem(_skin('a', 'Starry Night'), future, true),
      OwnedItem(_skin('b', 'Sunset Lounge'), future, false),
      OwnedItem(
        StoreItem(id: 'f', category: StoreCategory.frame, name: 'Gold Frame', emoji: 'F', priceCoins: 1, durationDays: 1),
        future,
        true,
      ),
    ]);
    await t.pumpWidget(host(repo));
    await t.pumpAndSettle();
    expect(find.text('Starry Night'), findsOneWidget);
    expect(find.text('Sunset Lounge'), findsOneWidget);
    expect(find.text('Gold Frame'), findsNothing, reason: 'only room skins');
    expect(find.text('Plain room'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
  });

  testWidgets('tapping another skin puts it on', (t) async {
    final repo = _FakeRepo([
      OwnedItem(_skin('a', 'Starry Night'), future, true),
      OwnedItem(_skin('b', 'Sunset Lounge'), future, false),
    ]);
    await t.pumpWidget(host(repo));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('skin-b')));
    await t.pumpAndSettle();
    expect(repo.calls, ['b:true']);
    expect(find.text('Sunset Lounge is now your room skin'), findsOneWidget);
  });

  testWidgets('tapping the skin that is already on does nothing more', (t) async {
    final repo = _FakeRepo([OwnedItem(_skin('a', 'Starry Night'), future, true)]);
    await t.pumpWidget(host(repo));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('skin-a')));
    await t.pumpAndSettle();
    expect(repo.calls, isEmpty);
  });

  testWidgets('Plain room takes the skin off', (t) async {
    final repo = _FakeRepo([OwnedItem(_skin('a', 'Starry Night'), future, true)]);
    await t.pumpWidget(host(repo));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('skin-none')));
    await t.pumpAndSettle();
    expect(repo.calls, ['a:false']);
    expect(find.text('Back to the plain room'), findsOneWidget);
  });

  testWidgets('a refused change shows the reason and leaves things as they were', (t) async {
    final repo = _FakeRepo([
      OwnedItem(_skin('a', 'Starry Night'), future, true),
      OwnedItem(_skin('b', 'Sunset Lounge'), future, false),
    ])..failWith = Exception('You do not own an active copy of this item');
    await t.pumpWidget(host(repo));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('skin-b')));
    await t.pumpAndSettle();
    expect(find.textContaining('do not own'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
  });

  testWidgets('expired skins are not offered', (t) async {
    final repo = _FakeRepo([
      OwnedItem(_skin('old', 'Old Skin'), DateTime.now().subtract(const Duration(days: 1)), false),
      OwnedItem(_skin('a', 'Starry Night'), future, false),
    ]);
    await t.pumpWidget(host(repo));
    await t.pumpAndSettle();
    expect(find.text('Old Skin'), findsNothing);
    expect(find.text('Starry Night'), findsOneWidget);
  });

  testWidgets('with no skin it says so and offers the Store', (t) async {
    var opened = 0;
    await t.pumpWidget(host(_FakeRepo([]), onOpenStore: () => opened++));
    await t.pumpAndSettle();
    expect(find.textContaining("don't have a room skin"), findsOneWidget);
    await t.tap(find.text('Open the Store'));
    expect(opened, 1);
  });
}
