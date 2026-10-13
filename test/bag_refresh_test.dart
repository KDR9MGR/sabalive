import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sabalive/state/active_live_session_controller.dart';
import 'package:sabalive/data/store_repository.dart';
import 'package:sabalive/features/wallet/bag_screen.dart';

StoreItem _frame(String id, String name) =>
    StoreItem(id: id, category: StoreCategory.frame, name: name, emoji: 'F', priceCoins: 1, durationDays: 7);

class _FakeRepo extends Fake implements StoreRepository {
  List<OwnedItem> items = [];
  int loads = 0;
  @override
  Future<List<OwnedItem>> myItems() async {
    loads++;
    return items;
  }
}

Widget _app(Widget home) => ChangeNotifierProvider(
      create: (_) => ActiveLiveSessionController(),
      child: MaterialApp(home: home),
    );

void main() {
  final future = DateTime.now().add(const Duration(days: 7));

  testWidgets('a frame bought in the Store is in the Bag when the Store closes', (t) async {
    final repo = _FakeRepo();
    repo.items = [];
    await t.pumpWidget(_app(
      BagScreen(
        repo: repo,
        // a stand-in Store: "buying" adds the frame, then closing returns to the Bag
        storePage: () => Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  repo.items = [OwnedItem(_frame('f1', 'Queen frame'), future, false)];
                  Navigator.pop(ctx);
                },
                child: const Text('Buy and close'),
              ),
            ),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text("You don't own anything yet"), findsOneWidget);

    await t.tap(find.byIcon(Icons.storefront_outlined));
    await t.pumpAndSettle();
    await t.tap(find.text('Buy and close'));
    await t.pumpAndSettle();

    expect(find.text('Queen frame'), findsOneWidget, reason: 'the Bag read its list again');
    expect(find.text('Equip'), findsOneWidget);
  });

  testWidgets('pulling down reads the Bag again', (t) async {
    final repo = _FakeRepo()..items = [OwnedItem(_frame('f1', 'Star'), future, false)];
    await t.pumpWidget(_app(BagScreen(repo: repo)));
    await t.pumpAndSettle();
    final before = repo.loads;
    repo.items = [OwnedItem(_frame('f1', 'Star'), future, false), OwnedItem(_frame('f2', 'Crown'), future, false)];
    await t.fling(find.text('Star'), const Offset(0, 300), 1000);
    await t.pumpAndSettle();
    expect(repo.loads, greaterThan(before));
    expect(find.text('Crown'), findsOneWidget);
  });
}
