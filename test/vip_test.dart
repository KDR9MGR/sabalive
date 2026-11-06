import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/widgets.dart' as w;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/data/profile_labels_repository.dart';
import 'package:sabalive/data/vip_repository.dart';
import 'package:sabalive/features/profile/widgets/profile_labels.dart';
import 'package:sabalive/features/vip/vip_kinds.dart';
import 'package:sabalive/features/vip/vip_product_screen.dart';
import 'package:sabalive/features/vip/vip_screen.dart';
import 'package:sabalive/state/active_live_session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// VIP products (owner, 2026-11-06): the list of cards, a product's page with its benefits and Buy, the badge on a profile, and how rows from the database are read.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
  });

  Map<String, dynamic> row(String id, String name, {int price = 1000, int days = 30, int sort = 0, String? tagline, String? badge, List<Map<String, dynamic>> benefits = const []}) => {
        'id': id,
        'name': name,
        'tagline': tagline,
        'badge_url': badge,
        'price_coins': price,
        'duration_days': days,
        'sort_order': sort,
        'vip_product_benefits': benefits,
      };

  Map<String, dynamic> ben(String id, String kind, {String? title, int sort = 0, String? image, String? link}) =>
      {'id': id, 'kind': kind, 'title': title, 'image_url': image, 'link_item_id': link, 'sort_order': sort};

  VipProduct product(String id, String name, {int price = 1000, int days = 30, List<Map<String, dynamic>>? benefits}) => VipProduct.fromRow(row(id, name, price: price, days: days, benefits: benefits ?? [
        ben('b1', 'identity', sort: 0),
        ben('b2', 'avatar_frame', sort: 1),
        ben('b3', 'anti_kick', sort: 2),
      ]))!;

  group('reading rows', () {
    test('a product with its benefits, in the panel\'s order', () {
      final p = VipProduct.fromRow(row('p1', ' VIP1 ', price: 2000000, days: 30, tagline: ' Start here ', badge: ' https://x/b.png ', benefits: [
        ben('b2', 'avatar_frame', sort: 2),
        ben('b1', 'identity', sort: 1),
        ben('b3', 'custom', title: ' Golden mic ', sort: 3),
      ]))!;
      expect(p.name, 'VIP1');
      expect(p.tagline, 'Start here');
      expect(p.badgeUrl, 'https://x/b.png');
      expect(p.priceCoins, 2000000);
      expect(p.durationDays, 30);
      expect([for (final b in p.benefits) b.kind], ['identity', 'avatar_frame', 'custom']);
      expect(p.benefits.last.label, 'Golden mic');
    });

    test('a blank tagline and badge are none; a row without an id, a name, a price or days is dropped', () {
      final p = VipProduct.fromRow(row('p1', 'VIP', tagline: '  ', badge: ''))!;
      expect(p.tagline, isNull);
      expect(p.badgeUrl, isNull);
      expect(VipProduct.fromRow(null), isNull);
      expect(VipProduct.fromRow(row('p1', '   ')), isNull);
      expect(VipProduct.fromRow(row('p1', 'VIP', price: 0)), isNull);
      expect(VipProduct.fromRow(row('p1', 'VIP', days: 0)), isNull);
      expect(VipProduct.fromRow({'name': 'No id', 'price_coins': 5, 'duration_days': 5}), isNull);
    });

    test('a bad benefit is skipped, the rest stay', () {
      final p = VipProduct.fromRow(row('p1', 'VIP', benefits: [ben('b1', 'identity'), {'id': 'b2'}, {'kind': 'x'}, ben('b3', '')]))!;
      expect(p.benefits.map((b) => b.id), ['b1']);
    });

    test('a benefit says its own title, else its kind\'s name, else nothing (a kind this app does not know has no name of its own)', () {
      expect(VipBenefit.fromRow(ben('b', 'anti_ban'))!.label, 'Anti-Ban');
      expect(VipBenefit.fromRow(ben('b', 'anti_ban', title: 'No bans'))!.label, 'No bans');
      expect(VipBenefit.fromRow(ben('b', 'brand_new_kind'))!.label, '');
      expect(VipBenefit.fromRow(ben('b', 'brand_new_kind', title: 'Shiny'))!.label, 'Shiny');
    });

    test('what a person owns: only what has not ended, the later end of two rows of one product', () {
      final now = DateTime.utc(2026, 11, 6, 12);
      final owned = VipRepository.ownedFrom([
        {'product_id': 'a', 'expires_at': '2026-12-01T00:00:00Z'},
        {'product_id': 'b', 'expires_at': '2026-11-01T00:00:00Z'}, // ended
        {'product_id': 'c', 'expires_at': '2026-12-05T00:00:00Z'},
        {'product_id': 'c', 'expires_at': '2026-12-09T00:00:00Z'},
        {'product_id': 'd', 'expires_at': 'not a date'},
        {'expires_at': '2026-12-01T00:00:00Z'},
      ], now: now);
      expect(owned.keys.toSet(), {'a', 'c'});
      expect(owned['c']!.toUtc(), DateTime.utc(2026, 12, 9));
    });

    test('the badge a person shows is the dearest product they own; none for nothing', () {
      expect(VipRepository.pickBadge(const []), isNull);
      final badge = VipRepository.pickBadge([
        {'expires_at': 'x', 'vip_products': {'name': 'VIP1', 'badge_url': 'https://x/1.png', 'price_coins': 1000}},
        {'expires_at': 'x', 'vip_products': {'name': 'VIP5', 'badge_url': '', 'price_coins': 5000}},
        {'expires_at': 'x', 'vip_products': {'name': '  ', 'badge_url': 'https://x/z.png', 'price_coins': 99999}},
        {'expires_at': 'x', 'vip_products': null},
      ])!;
      expect(badge.name, 'VIP5');
      expect(badge.imageUrl, isNull, reason: 'a product with no picture is shown by its name');
    });
  });

  group('the kinds', () {
    test('every fixed kind has a unique key and a name; custom is not in the list', () {
      final keys = [for (final k in kVipKinds) k.key];
      expect(keys.toSet().length, keys.length);
      expect(keys, isNot(contains(kVipCustomKind)));
      for (final k in kVipKinds) {
        expect(k.label, isNotEmpty, reason: k.key);
        expect(k.key, matches(RegExp(r'^[a-z][a-z0-9_]{1,39}$')), reason: 'the database accepts exactly this shape');
      }
    });

    test('only the kinds that can be linked to a Store item give something today', () {
      expect({for (final k in kVipKinds) if (k.gives) k.key}, {'identity', 'entry_effect', 'vehicle', 'avatar_frame', 'theme'});
    });

    test('a kind the app does not know is a plain star with no name', () {
      final k = vipKindFor('brand_new_kind');
      expect(k.icon, Icons.star_rounded);
      expect(k.label, '');
      expect(vipKindFor('anti_kick').label, 'Anti-Kick');
    });

    test('days are said in words', () {
      expect(vipDaysLabel(1), '1 day');
      expect(vipDaysLabel(30), '30 days');
    });

    test('a date is day, month, year', () {
      expect(vipEndLabel(DateTime(2026, 12, 5, 10)), '5 Dec 2026');
    });
  });

  group('the VIP list', () {
    Future<({List<VipProduct> products, Map<String, DateTime> mine})> Function() loaderOf(List<VipProduct> products, [Map<String, DateTime> mine = const {}]) =>
        () async => (products: products, mine: mine);

    Future<void> pump(WidgetTester t, VipScreen screen) async {
      t.view.physicalSize = const Size(400, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        ChangeNotifierProvider(create: (_) => ActiveLiveSessionController(), child: MaterialApp(home: screen)),
      );
      await t.pump();
      await t.pump();
    }

    testWidgets('a card per product in the given order, with its benefit count, price and days', (t) async {
      await pump(t, VipScreen(loader: loaderOf([product('p1', 'VIP1'), product('p2', 'Royal Pack', price: 2500000, days: 7, benefits: [ben('b1', 'identity')])])));
      expect(find.byType(VipCard), findsNWidgets(2));
      expect(find.text('VIP1'), findsOneWidget);
      expect(find.text('Royal Pack'), findsOneWidget);
      expect(find.text('3 benefits'), findsOneWidget);
      expect(find.text('1 benefit'), findsOneWidget);
      expect(find.textContaining('7 days'), findsOneWidget);
      expect(find.textContaining('30 days'), findsOneWidget);
      expect(find.textContaining('Active until'), findsNothing);
    });

    testWidgets('a product the person owns says when it ends', (t) async {
      await pump(t, VipScreen(loader: loaderOf([product('p1', 'VIP1'), product('p2', 'VIP2')], {'p2': DateTime(2026, 12, 5, 10)})));
      expect(find.text('Active until 5 Dec 2026'), findsOneWidget);
    });

    testWidgets('no products yet says so', (t) async {
      await pump(t, VipScreen(loader: loaderOf(const [])));
      expect(find.text('No VIP products yet.'), findsOneWidget);
      expect(find.byType(VipCard), findsNothing);
    });

    testWidgets('a failed first read shows the message and Retry, and Retry loads the list', (t) async {
      var tries = 0;
      await pump(t, VipScreen(loader: () async {
        tries++;
        if (tries == 1) throw Exception('Could not reach the server');
        return (products: [product('p1', 'VIP1')], mine: const <String, DateTime>{});
      }));
      expect(find.text('Could not reach the server'), findsOneWidget);
      await t.tap(find.text('Retry'));
      await t.pump();
      await t.pump();
      expect(find.byType(VipCard), findsOneWidget);
    });

    testWidgets('tapping a card opens that product\'s page, and coming back reads the list again', (t) async {
      var reads = 0;
      await pump(t, VipScreen(loader: () async {
        reads++;
        return (products: [product('p1', 'VIP1')], mine: const <String, DateTime>{});
      }));
      expect(reads, 1);
      await t.tap(find.byType(VipCard));
      await t.pumpAndSettle();
      expect(find.byType(VipProductScreen), findsOneWidget);
      expect(find.text('VIP Benefits'), findsOneWidget);
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.byType(VipProductScreen), findsNothing);
      expect(reads, 2);
    });
  });

  group('a product page', () {
    Future<void> pump(WidgetTester t, VipProductScreen screen) async {
      t.view.physicalSize = const Size(400, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: screen));
      await t.pump();
    }

    testWidgets('its name, price, days, the benefit count and a tile per benefit', (t) async {
      await pump(t, VipProductScreen(product: product('p1', 'VIP1', price: 2000000, days: 30, benefits: [ben('b1', 'identity'), ben('b2', 'avatar_frame', sort: 1), ben('b3', 'custom', title: 'Golden mic', sort: 2)]), coinsOf: (_) => 5000000));
      expect(find.text('VIP1'), findsWidgets);
      expect(find.text('VIP Benefits'), findsOneWidget);
      expect(find.text('(3)'), findsOneWidget);
      expect(find.byType(VipBenefitTile), findsNWidgets(3));
      expect(find.text('Identity'), findsOneWidget);
      expect(find.text('Avatar Frame'), findsOneWidget);
      expect(find.text('Golden mic'), findsOneWidget);
      expect(find.text('2,000,000'), findsOneWidget);
      expect(find.text('30 days'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Buy'), findsOneWidget);
    });

    testWidgets('a product with no benefits says so', (t) async {
      await pump(t, VipProductScreen(product: product('p1', 'Empty', benefits: const []), coinsOf: (_) => 0));
      expect(find.text('No benefits listed yet.'), findsOneWidget);
    });

    testWidgets('an active product shows Active until and the button says Extend', (t) async {
      await pump(t, VipProductScreen(product: product('p1', 'VIP1'), endsAt: DateTime(2026, 12, 5, 10), coinsOf: (_) => 5000));
      expect(find.byKey(const ValueKey('vip-active')), findsOneWidget);
      expect(find.text('Active until 5 Dec 2026'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Extend'), findsOneWidget);
    });

    testWidgets('Buy asks first; confirming buys that product, then shows when it ends, the button becomes Extend and the page pops true', (t) async {
      final bought = <String>[];
      var after = 0;
      bool? result;
      t.view.physicalSize = const Size(400, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<bool>(MaterialPageRoute(
                  builder: (_) => VipProductScreen(
                    product: product('p1', 'VIP1', price: 1000, days: 30),
                    coinsOf: (_) => 5000,
                    buy: (id) async {
                      bought.add(id);
                      return DateTime(2027, 1, 9, 10);
                    },
                    afterBuy: (_) async => after++,
                  ),
                ));
              },
              child: const w.Text('open'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('vip-buy')));
      await t.pumpAndSettle();
      expect(find.text('Buy VIP1?'), findsOneWidget);
      expect(find.textContaining('1,000 coins for 30 days of VIP'), findsOneWidget);
      expect(bought, isEmpty, reason: 'nothing is bought until it is confirmed');
      await t.tap(find.widgetWithText(TextButton, 'Buy'));
      await t.pumpAndSettle();
      expect(bought, ['p1']);
      expect(after, 1);
      expect(find.text('VIP1 is yours until 9 Jan 2027'), findsOneWidget);
      expect(find.text('Active until 9 Jan 2027'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Extend'), findsOneWidget);
      await t.pageBack();
      await t.pumpAndSettle();
      expect(result, isTrue);
    });

    testWidgets('cancelling the question buys nothing', (t) async {
      var bought = 0;
      await pump(t, VipProductScreen(product: product('p1', 'VIP1'), coinsOf: (_) => 5000, buy: (_) async {
        bought++;
        return DateTime.now();
      }));
      await t.tap(find.byKey(const ValueKey('vip-buy')));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await t.pumpAndSettle();
      expect(bought, 0);
      expect(find.widgetWithText(FilledButton, 'Buy'), findsOneWidget);
    });

    testWidgets('too few coins does not even ask: it says so and buys nothing', (t) async {
      var bought = 0;
      await pump(t, VipProductScreen(product: product('p1', 'VIP1', price: 1000), coinsOf: (_) => 999, buy: (_) async {
        bought++;
        return DateTime.now();
      }));
      await t.tap(find.byKey(const ValueKey('vip-buy')));
      await t.pumpAndSettle();
      expect(find.text('Not enough coins'), findsOneWidget);
      expect(find.text('Buy VIP1?'), findsNothing);
      expect(bought, 0);
    });

    testWidgets('a refusal from the server is shown as it is, and the page stays as it was', (t) async {
      await pump(t, VipProductScreen(product: product('p1', 'VIP1'), coinsOf: (_) => 5000, buy: (_) async => throw Exception('This VIP is not available')));
      await t.tap(find.byKey(const ValueKey('vip-buy')));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(TextButton, 'Buy'));
      await t.pumpAndSettle();
      expect(find.text('This VIP is not available'), findsOneWidget);
      expect(find.byKey(const ValueKey('vip-active')), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Buy'), findsOneWidget, reason: 'the button is usable again');
    });

    testWidgets('while buying, a second tap is ignored', (t) async {
      final gate = Completer<DateTime>();
      var bought = 0;
      await pump(t, VipProductScreen(product: product('p1', 'VIP1'), coinsOf: (_) => 5000, buy: (_) {
        bought++;
        return gate.future;
      }, afterBuy: (_) async {}));
      await t.tap(find.byKey(const ValueKey('vip-buy')));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(TextButton, 'Buy'));
      await t.pump();
      // the button is disabled while the purchase runs
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('vip-buy'))).onPressed, isNull);
      expect(bought, 1);
      gate.complete(DateTime(2027, 1, 1));
      await t.pumpAndSettle();
      expect(bought, 1);
    });
  });

  group('the VIP badge on a profile', () {
    testWidgets('a profile page draws it first, as a gold pill with the name when the product has no picture', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ProfileLabelsRow(
            profileId: 'p',
            loader: (_) async => ProfileLabels(vip: const VipBadge(name: 'VIP5'), badges: const [ProfileBadge(id: 'b', name: 'Early', emoji: '⭐')]),
          ),
        ),
      ));
      await t.pump();
      expect(find.byKey(const ValueKey('profile-vip')), findsOneWidget);
      expect(find.text('VIP5'), findsOneWidget);
      // before the badges
      expect(t.getTopLeft(find.byKey(const ValueKey('profile-vip'))).dx, lessThan(t.getTopLeft(find.textContaining('Early')).dx));
    });

    testWidgets('a person with only a VIP still gets a row (it is not "nothing to show")', (t) async {
      expect(const ProfileLabels(vip: VipBadge(name: 'VIP1')).isEmpty, isFalse);
      expect(const ProfileLabels().isEmpty, isTrue);
    });

    testWidgets('a one-line list row never shows it (lists do not read it)', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ProfileLabelsRow(profileId: 'p', compact: true, loader: (_) async => const ProfileLabels(vip: VipBadge(name: 'VIP5'))),
        ),
      ));
      await t.pump();
      expect(find.byKey(const ValueKey('profile-vip')), findsNothing);
    });
  });
}
