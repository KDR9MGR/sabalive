import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:sabalive/data/games_repository.dart';
import 'package:sabalive/features/games/game_webview_screen.dart';
import 'package:sabalive/features/games/games_screen.dart';
import 'package:sabalive/state/remote_config_controller.dart';

const _kingdoms = MerchantGame(id: 2883, name: 'Teen Patti Gold', identification: 'kingdoms');

void main() {
  group('buildGameUrl', () {
    test('uses the default domain and keeps every parameter the platform asks for', () {
      final u = buildGameUrl(_kingdoms, 'TOKEN123');
      expect(u.scheme, 'https');
      expect(u.host, 'gamesp.tulasigame.com');
      expect(u.path, '/kingdoms/');
      expect(u.queryParameters, {
        'merchant': '1503251',
        'gameId': '2883',
        'lang': 'en',
        'isLandscape': 'false',
        'roomId': '111',
        'token': 'TOKEN123',
      });
    });

    test('language and orientation can be set', () {
      final u = buildGameUrl(_kingdoms, 't', lang: 'cn', landscape: true);
      expect(u.queryParameters['lang'], 'cn');
      expect(u.queryParameters['isLandscape'], 'true');
    });

    test('a custom https game domain is used (a missing trailing slash is fixed); a bad one falls back to the default', () {
      MerchantGame withDomain(String? d) => MerchantGame(id: 1, name: 'g', identification: 'g1', gameDomain: d);
      expect(buildGameUrl(withDomain('https://games.example.com/'), 't').host, 'games.example.com');
      expect(buildGameUrl(withDomain('https://games.example.com'), 't').path, '/g1/');
      for (final bad in ['http://games.example.com/', 'https://localhost/', 'https://u:p@games.example.com/', 'nonsense', '']) {
        expect(buildGameUrl(withDomain(bad), 't').host, 'gamesp.tulasigame.com', reason: bad);
      }
    });

    test('a token with odd characters is encoded, not broken', () {
      expect(buildGameUrl(_kingdoms, 'a b&c=d').queryParameters['token'], 'a b&c=d');
      expect(buildGameUrl(_kingdoms, 'a b&c=d').toString(), isNot(contains('a b&c=d')));
    });
  });

  group('MerchantGame.fromRow', () {
    test('reads the row, trims, and treats blanks as missing', () {
      final g = MerchantGame.fromRow({'id': 2883, 'name': ' Teen Patti Gold ', 'identification': 'kingdoms', 'image_url': '  ', 'game_domain': null, 'description': 'x'});
      expect(g.id, 2883);
      expect(g.name, 'Teen Patti Gold');
      expect(g.identification, 'kingdoms');
      expect(g.imageUrl, isNull);
      expect(g.launchable, isTrue);
      expect(MerchantGame.fromRow({'id': 1, 'name': 'x'}).launchable, isFalse);
    });
  });

  group('decideGameNavigation', () {
    GameNavigation d(String url) => decideGameNavigation(url, gameHost: 'gamesp.tulasigame.com');

    test('the platform\'s own pages are allowed', () {
      expect(d('https://gamesp.tulasigame.com/kingdoms/?token=1'), GameNavigation.allow);
      expect(d('https://gamede.tulasigame.com/x'), GameNavigation.allow);
      expect(d('https://cdn.tulasigame.com/a.js'), GameNavigation.allow);
      expect(d('about:blank'), GameNavigation.allow);
    });

    test('the game\'s messages close it or ask for the coin shop', () {
      expect(d('tulasigame://exit'), GameNavigation.exit);
      expect(d('tulasigame://recharge'), GameNavigation.recharge);
      expect(d('tulasigame://something-else'), GameNavigation.block);
    });

    test('anything else is blocked: other sites, plain http, look-alike domains, other schemes', () {
      for (final bad in ['https://evil.example.com/', 'http://gamesp.tulasigame.com/', 'https://tulasigame.com.evil.com/', 'https://nottulasigame.com/', 'intent://x', 'javascript:alert(1)', '::not a url::']) {
        expect(d(bad), GameNavigation.block, reason: bad);
      }
    });

    test('a game on a custom domain may navigate on that domain', () {
      expect(decideGameNavigation('https://games.example.com/g1/x', gameHost: 'games.example.com'), GameNavigation.allow);
    });
  });

  group('the Games tab', () {
    final games = [_kingdoms, const MerchantGame(id: 2882, name: 'Teen Patti', identification: 'kingdoms2'), const MerchantGame(id: 9, name: 'No path')];

    Future<RemoteConfigController> config(bool on) async {
      final c = RemoteConfigController(
        fetch: () async => {'feature_flags': {if (on) 'games_enabled': true}},
        buildNumber: () async => 8,
        isIos: false,
      );
      await c.refresh(force: true);
      return c;
    }

    Widget host(Widget screen) => MaterialApp(home: screen);

    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('switched off: the old "coming soon" screen, and the database is not asked', (t) async {
      final repo = _Repo(games);
      await t.pumpWidget(host(GamesScreen(repo: repo, config: await config(false), isAndroid: true, balance: (_) => const SizedBox(), userId: (_) => 'u1')));
      await t.pump();
      expect(find.textContaining('Games are coming soon'), findsOneWidget);
      expect(repo.loads, 0);
    });

    testWidgets('on an iPhone: still "coming soon" even when games are switched on', (t) async {
      final repo = _Repo(games);
      await t.pumpWidget(host(GamesScreen(repo: repo, config: await config(true), isAndroid: false, balance: (_) => const SizedBox(), userId: (_) => 'u1')));
      await t.pump();
      expect(find.textContaining('Games are coming soon'), findsOneWidget);
      expect(repo.loads, 0);
    });

    testWidgets('switched on (Android): the platform\'s games are listed', (t) async {
      final repo = _Repo(games);
      await t.pumpWidget(host(GamesScreen(repo: repo, config: await config(true), isAndroid: true, balance: (_) => const SizedBox(), userId: (_) => 'u1')));
      await t.pumpAndSettle();
      expect(find.text('Teen Patti Gold'), findsOneWidget);
      expect(find.text('Teen Patti'), findsOneWidget);
      expect(find.textContaining('coming soon'), findsNothing);
    });

    testWidgets('the first play shows the notice; it needs the tick; then the game opens with the session\'s token', (t) async {
      final repo = _Repo(games);
      final opened = <String>[];
      await t.pumpWidget(host(GamesScreen(
        repo: repo,
        config: await config(true),
        isAndroid: true,
        balance: (_) => const SizedBox(),
        userId: (_) => 'u1',
        openGame: (ctx, g, s) async {
          opened.add('${g.id}:${s.token}');
          return GameExit.closed;
        },
      )));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('game-2883')));
      await t.pumpAndSettle();
      expect(find.text('Before you play'), findsOneWidget);
      expect(find.textContaining('may adjust outcomes'), findsOneWidget, reason: 'the notice says plainly that results can be adjusted');
      // cannot continue without the tick
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('games-notice-continue'))).onPressed, isNull);
      await t.tap(find.byKey(const ValueKey('games-notice-check')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('games-notice-continue')));
      await t.pumpAndSettle();
      expect(opened, ['2883:TOKEN-2883']);
      expect(repo.started, [2883]);

      // the notice is remembered for this person: the second play goes straight in
      await t.tap(find.byKey(const ValueKey('game-2882')));
      await t.pumpAndSettle();
      expect(find.text('Before you play'), findsNothing);
      expect(opened, ['2883:TOKEN-2883', '2882:TOKEN-2882']);
    });

    testWidgets('cancelling the notice starts nothing', (t) async {
      final repo = _Repo(games);
      await t.pumpWidget(host(GamesScreen(repo: repo, config: await config(true), isAndroid: true, balance: (_) => const SizedBox(), userId: (_) => 'u1', openGame: (c, g, s) async => null)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('game-2883')));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(repo.started, isEmpty, reason: 'no session without the notice');
    });

    testWidgets('the server refusing (under 18, no date of birth, games off) shows its message and opens nothing', (t) async {
      SharedPreferences.setMockInitialValues({'games.notice.v1.u1': true});
      final repo = _Repo(games)..startError = const PostgrestException(message: 'Add your date of birth in your profile to play games', code: 'P0001');
      var opened = 0;
      await t.pumpWidget(host(GamesScreen(repo: repo, config: await config(true), isAndroid: true, balance: (_) => const SizedBox(), userId: (_) => 'u1', openGame: (c, g, s) async {
        opened++;
        return null;
      })));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('game-2883')));
      await t.pumpAndSettle();
      expect(find.text('Add your date of birth in your profile to play games'), findsOneWidget);
      expect(opened, 0);
    });

    testWidgets('when the game asks for the coin shop, the coin shop opens', (t) async {
      SharedPreferences.setMockInitialValues({'games.notice.v1.u1': true});
      var shop = 0;
      await t.pumpWidget(host(GamesScreen(
        repo: _Repo(games),
        config: await config(true),
        isAndroid: true,
        balance: (_) => const SizedBox(),
        userId: (_) => 'u1',
        openGame: (c, g, s) async => GameExit.recharge,
        onRecharge: (c) async => shop++,
      )));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('game-2883')));
      await t.pumpAndSettle();
      expect(shop, 1);
    });

    testWidgets('a game with no path is shown but cannot be opened', (t) async {
      SharedPreferences.setMockInitialValues({'games.notice.v1.u1': true});
      await t.binding.setSurfaceSize(const Size(800, 1400)); // tall enough that the third card is on screen, so the tap really lands
      addTearDown(() => t.binding.setSurfaceSize(null));
      final repo = _Repo(games);
      await t.pumpWidget(host(GamesScreen(repo: repo, config: await config(true), isAndroid: true, balance: (_) => const SizedBox(), userId: (_) => 'u1', openGame: (c, g, s) async => null)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('game-9')));
      await t.pumpAndSettle();
      expect(repo.started, isEmpty);
    });

    testWidgets('an empty list and a failed load say so', (t) async {
      await t.pumpWidget(host(GamesScreen(repo: _Repo(const []), config: await config(true), isAndroid: true, balance: (_) => const SizedBox(), userId: (_) => 'u1')));
      await t.pumpAndSettle();
      expect(find.text('No games available right now'), findsOneWidget);
      await t.pumpWidget(const SizedBox()); // a fresh screen, not the old one with its old repository
      final failing = _Repo(const [])..listError = Exception('offline');
      await t.pumpWidget(host(GamesScreen(repo: failing, config: await config(true), isAndroid: true, balance: (_) => const SizedBox(), userId: (_) => 'u1')));
      await t.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);
    });
  });
}

class _Repo extends GamesRepository {
  _Repo(this.list);
  final List<MerchantGame> list;
  int loads = 0;
  final started = <int>[];
  Object? startError;
  Object? listError;

  @override
  Future<List<MerchantGame>> games() async {
    loads++;
    if (listError != null) throw listError!;
    return list;
  }

  @override
  Future<GameSession> start(MerchantGame game) async {
    if (startError != null) throw startError!;
    started.add(game.id);
    return GameSession(token: 'TOKEN-${game.id}', uid: 10001);
  }
}
