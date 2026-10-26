import 'package:flutter/material.dart' hide Text;
import 'package:flutter/widgets.dart' as w;
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/config/feature_flags.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/core/media/gift_artwork_warmer.dart';
import 'package:sabalive/core/widgets/remote_media.dart' show MediaKind;
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/gift_icon.dart';
import 'package:sabalive/features/live/widgets/gift_sheet.dart';
import 'package:sabalive/state/remote_config_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The gift sheet's tabs (every category the panel has), who "Send All" counts, the gift picture while it loads, the background warm-up, and the iOS coin seller switch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
  });

  Gift gift(String id, String category, {bool effect = false, String? icon}) => Gift(id, 'G$id', '🎁', 10, category: category, effect: effect, iconUrl: icon);

  group('the tabs', () {
    test('Popular and New always, then a tab for each panel category that has a gift, in the panel order', () {
      final catalog = [gift('1', 'luxury'), gift('2', 'basic'), gift('3', 'event'), gift('4', 'vehicle'), gift('5', 'special')];
      expect(giftTabsFor(catalog), ['Popular', 'New', 'Basic', 'Luxury', 'Vehicle', 'Special', 'Event']);
    });

    test('a category with no gift has no tab, and Effects only when a gift has an effect', () {
      expect(giftTabsFor([gift('1', 'basic')]), ['Popular', 'New', 'Basic']);
      expect(giftTabsFor([gift('1', 'basic', effect: true), gift('2', 'luxury')]), ['Popular', 'New', 'Effects', 'Basic', 'Luxury']);
      expect(giftTabsFor(const []), ['Popular', 'New']);
    });

    test('the five categories of the panel are all there', () {
      expect([for (final c in giftCategoryTabs) c.$2], ['Basic', 'Luxury', 'Vehicle', 'Special', 'Event']);
    });

    test('each tab lists its own gifts; Popular is everything, New is the same newest first', () {
      final catalog = [gift('1', 'basic'), gift('2', 'luxury'), gift('3', 'luxury', effect: true), gift('4', 'vehicle')];
      expect([for (final g in giftsForTab(catalog, 'Luxury')) g.id], ['2', '3']);
      expect([for (final g in giftsForTab(catalog, 'Vehicle')) g.id], ['4']);
      expect([for (final g in giftsForTab(catalog, 'Special')) g.id], isEmpty);
      expect([for (final g in giftsForTab(catalog, 'Popular')) g.id], ['1', '2', '3', '4']);
      expect([for (final g in giftsForTab(catalog, 'New')) g.id], ['4', '3', '2', '1']);
      expect([for (final g in giftsForTab(catalog, 'Effects')) g.id], ['3']);
    });
  });

  group('Send All counts everyone offered, the sender included', () {
    AppUser person(String id) => AppUser(id: id, name: id, username: '@$id');

    test('host and two seated people (one of them me) are three people', () {
      expect(giftSendAllPeople([person('host'), person('me'), person('guest')]), 3);
    });

    test('never fewer than one', () {
      expect(giftSendAllPeople(const []), 1);
      expect(giftSendAllPeople([person('me')]), 1);
    });
  });

  group('the gift picture while it loads', () {
    // a different address per test: the picture cache shares one in-flight request per address, and a test that ends mid-request would leave the next one waiting on it
    const pngLoading = 'https://x.supabase.co/storage/v1/object/public/gift-assets/gifts/rose-loading.png';
    const pngFailing = 'https://x.supabase.co/storage/v1/object/public/gift-assets/gifts/rose-failing.png';
    const mp4 = 'https://x.supabase.co/storage/v1/object/public/gift-assets/gifts/rose.mp4';

    testWidgets('a gift with no artwork shows its emoji at once', (t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(body: GiftIcon(gift('1', 'basic'), size: 28))));
      expect(find.text('🎁'), findsOneWidget);
      expect(find.byKey(const ValueKey('gift-icon-loading')), findsNothing);
    });

    testWidgets('while the artwork loads a quiet shape is shown, not the emoji', (t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(body: GiftIcon(gift('1', 'basic', icon: pngLoading), size: 28))));
      expect(find.byKey(const ValueKey('gift-icon-loading')), findsOneWidget);
      expect(find.text('🎁'), findsNothing, reason: 'the emoji is not a stand-in for artwork that is on its way');
    });

    testWidgets('when the artwork cannot be loaded the emoji comes back, so the gift is never a hole', (t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(body: GiftIcon(gift('1', 'basic', icon: pngFailing), size: 28))));
      for (var i = 0; i < 30 && find.text('🎁').evaluate().isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100))); // the test network refuses the file
        await t.pump();
      }
      expect(find.text('🎁'), findsOneWidget);
      expect(find.byKey(const ValueKey('gift-icon-loading')), findsNothing);
    });

    testWidgets('an MP4 gift keeps the emoji as its stand-in (a video tile can be left without a decoder for good)', (t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(body: GiftIcon(gift('1', 'basic', icon: mp4), size: 28))));
      await t.pump();
      expect(find.byKey(const ValueKey('gift-icon-loading')), findsNothing);
      expect(find.text('🎁'), findsOneWidget);
    });

    testWidgets('the emoji is drawn at the size asked', (t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(body: GiftIcon(gift('1', 'basic'), size: 40))));
      expect(t.widget<w.Text>(find.text('🎁')).style!.fontSize, 40);
    });
  });

  group('warming the gift pictures', () {
    test('every gift with artwork is fetched once, by its kind; a second pass fetches nothing new', () async {
      final fetched = <(String, MediaKind)>[];
      final warmer = GiftArtworkWarmer(warmOne: (url, kind) async {
        fetched.add((url, kind));
        return true;
      });
      final catalog = [
        gift('1', 'basic', icon: 'https://x/a.svga'),
        gift('2', 'basic', icon: 'https://x/b.png'),
        gift('3', 'basic'),
        gift('4', 'basic', icon: 'https://x/c.mp4'),
        gift('5', 'basic', icon: 'https://x/d.svg'),
      ];
      await warmer.warm(catalog);
      expect(fetched.map((e) => e.$2).toSet(), {MediaKind.svga, MediaKind.image, MediaKind.video, MediaKind.svg});
      expect(fetched, hasLength(4), reason: 'the gift with no artwork is skipped');
      await warmer.warm(catalog);
      expect(fetched, hasLength(4), reason: 'already on the phone');
      expect(warmer.warmed, 4);
    });

    test('only the first gifts are warmed (the limit), in the panel order', () async {
      final urls = <String>[];
      final warmer = GiftArtworkWarmer(limit: 3, warmOne: (url, kind) async {
        urls.add(url);
        return true;
      });
      await warmer.warm([for (var i = 0; i < 10; i++) gift('$i', 'basic', icon: 'https://x/$i.png')]);
      expect(urls, ['https://x/0.png', 'https://x/1.png', 'https://x/2.png']);
    });

    test('a file that cannot be fetched never throws, and is tried again next time', () async {
      var attempts = 0;
      final warmer = GiftArtworkWarmer(warmOne: (url, kind) async {
        attempts++;
        if (attempts == 1) throw Exception('offline');
        return attempts > 2;
      });
      final catalog = [gift('1', 'basic', icon: 'https://x/a.png')];
      await warmer.warm(catalog);
      expect(warmer.warmed, 0);
      await warmer.warm(catalog);
      expect(warmer.warmed, 0, reason: 'a false answer is not "done" either');
      await warmer.warm(catalog);
      expect(warmer.warmed, 1);
      expect(attempts, 3);
    });

    test('no more than two files are fetched at once', () async {
      var running = 0;
      var peak = 0;
      final warmer = GiftArtworkWarmer(warmOne: (url, kind) async {
        running++;
        if (running > peak) peak = running;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        running--;
        return true;
      });
      await warmer.warm([for (var i = 0; i < 8; i++) gift('$i', 'basic', icon: 'https://x/$i.png')]);
      expect(peak, 2);
    });

    test('a newer list replaces what is still waiting', () async {
      final urls = <String>[];
      late GiftArtworkWarmer warmer;
      Future<void>? second;
      warmer = GiftArtworkWarmer(parallel: 1, warmOne: (url, kind) async {
        urls.add(url);
        if (url == 'https://x/old0.png') {
          second = warmer.warm([gift('9', 'basic', icon: 'https://x/new.png')]);
        }
        return true;
      });
      await warmer.warm([for (var i = 0; i < 4; i++) gift('$i', 'basic', icon: 'https://x/old$i.png')]);
      await second;
      expect(urls, ['https://x/old0.png', 'https://x/new.png'], reason: 'the rest of the old list was dropped');
    });
  });

  group('the coin seller button on iOS', () {
    Future<RemoteConfigController> config(Map<String, bool> flags) async {
      final c = RemoteConfigController(fetch: () async => {'feature_flags': flags}, buildNumber: () async => 8, isIos: true);
      await c.refresh(force: true);
      return c;
    }

    test('Android always shows it, whatever the switch says', () async {
      expect(FeatureFlags.coinSellerVisibleFor(await config({'coin_seller_ios': false}), isIOS: false), isTrue);
      expect(FeatureFlags.coinSellerVisibleFor(RemoteConfigController(), isIOS: false), isTrue);
    });

    test('iOS shows it by default (nothing changes until the panel switch is turned off)', () async {
      expect(FeatureFlags.coinSellerVisibleFor(RemoteConfigController(), isIOS: true), isTrue);
      expect(FeatureFlags.coinSellerVisibleFor(await config({}), isIOS: true), isTrue, reason: 'a server row without the key');
    });

    test('turned ON in the panel iOS shows it; turned OFF it hides it', () async {
      expect(FeatureFlags.coinSellerVisibleFor(await config({'coin_seller_ios': true}), isIOS: true), isTrue);
      expect(FeatureFlags.coinSellerVisibleFor(await config({'coin_seller_ios': false}), isIOS: true), isFalse);
    });
  });
}
