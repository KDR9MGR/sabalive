import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabalive/data/games_repository.dart';
import 'package:sabalive/features/games/game_webview_screen.dart';
import 'package:sabalive/features/games/games_screen.dart';
import 'package:sabalive/state/active_live_session_controller.dart';
import 'package:sabalive/state/games_store.dart';
import 'package:sabalive/state/remote_config_controller.dart';

/// SUD games next to Tulasi's: the catalogue row, the launch through the `sud` function, the switch, the room, and the notice that matches the game.
const _tulasi = MerchantGame(id: 2883, name: 'Teen Patti Gold', identification: 'kingdoms');
const _ludo = MerchantGame(id: 1000001, name: 'Ludo', identification: 'sud-1468180338417074177', provider: GameProvider.sud, aspect: 1.0);
const _teen = MerchantGame(id: 1000002, name: 'TeenPatti', identification: 'sud-1557194487352053761', provider: GameProvider.sud, aspect: 1.0, usesCoins: true);

class _Repo extends GamesRepository {
  _Repo(this.list);
  final List<MerchantGame> list;
  final started = <int>[];
  final rooms = <String?>[];
  final langs = <String>[];

  @override
  Future<List<MerchantGame>> games() async => List.of(list);

  @override
  Future<GameSession> start(MerchantGame game, {String? roomId, String lang = 'en'}) async {
    started.add(game.id);
    rooms.add(roomId);
    langs.add(lang);
    return game.isSud
        ? GameSession(token: '', uid: 0, url: Uri.parse('https://sabalive.in/sud/play?gameId=${game.id}'), aspect: game.aspect)
        : GameSession(token: 'TOKEN-${game.id}', uid: 10001);
  }
}

void main() {
  group('MerchantGame.fromSudRow', () {
    test('reads a sud_games row: its own small id, the path-like identification, the proportions and the coin flag', () {
      final g = MerchantGame.fromSudRow({
        'id': 1000001,
        'provider_game_id': '1468180338417074177',
        'name': '  Ludo ',
        'image_url': 'https://img.example.com/ludo.png',
        'description': 'Classic Ludo',
        'aspect': 1.4,
        'uses_coins': false,
        'status': 1,
      });
      expect(g.id, 1000001);
      expect(g.name, 'Ludo');
      expect(g.identification, 'sud-1468180338417074177');
      expect(g.imageUrl, 'https://img.example.com/ludo.png');
      expect(g.provider, GameProvider.sud);
      expect(g.isSud, isTrue);
      expect(g.aspect, 1.4);
      expect(g.usesCoins, isFalse);
      expect(g.launchable, isTrue);
    });

    test('a row without a picture, an aspect or a coin flag still reads (it starts square-ish and stakes nothing)', () {
      final g = MerchantGame.fromSudRow({'id': 1000009, 'provider_game_id': '123456', 'name': 'X'});
      expect(g.imageUrl, isNull);
      expect(g.aspect, isNull);
      expect(g.usesCoins, isFalse);
    });

    test('a Tulasi row is still Tulasi', () {
      final g = MerchantGame.fromRow({'id': 2883, 'name': 'Teen Patti Gold', 'identification': 'kingdoms'});
      expect(g.provider, GameProvider.tulasi);
      expect(g.isSud, isFalse);
    });
  });

  group('GameSession.fromSud', () {
    test('the address of our page and its proportions', () {
      final s = GameSession.fromSud({'url': 'https://sabalive.in/sud/play?x=1', 'aspect': 1.2, 'name': 'Ludo'});
      expect(s.url.toString(), 'https://sabalive.in/sud/play?x=1');
      expect(s.aspect, 1.2);
      expect(s.token, '');
    });

    test('anything that is not an https address is refused, so a bad answer never opens a page', () {
      for (final bad in [
        {'url': 'http://sabalive.in/sud/play'},
        {'url': 'javascript:alert(1)'},
        {'url': ''},
        {'url': 5},
        <String, dynamic>{},
      ]) {
        expect(() => GameSession.fromSud(bad), throwsException, reason: '$bad');
      }
    });
  });

  group('GamesRepository.start', () {
    test('a SUD game goes through the sud function: the game, the live room and the language are sent; the address comes back', () async {
      final calls = <(String, Map<String, dynamic>)>[];
      final repo = GamesRepository(invoke: (fn, body) async {
        calls.add((fn, body));
        return {'url': 'https://sabalive.in/sud/play?a=1', 'aspect': 1.0};
      });
      final s = await repo.start(_ludo, roomId: 'live-123', lang: 'hi');
      expect(calls.single.$1, 'sud/launch');
      expect(calls.single.$2, {'gameId': 1000001, 'roomId': 'live-123', 'lang': 'hi'});
      expect(s.url.toString(), 'https://sabalive.in/sud/play?a=1');
    });

    test('with no live the room is left out (the server gives the person a table of their own)', () async {
      Map<String, dynamic>? sent;
      final repo = GamesRepository(invoke: (fn, body) async {
        sent = body;
        return {'url': 'https://sabalive.in/sud/play'};
      });
      await repo.start(_ludo);
      expect(sent, {'gameId': 1000001, 'lang': 'en'});
      await repo.start(_ludo, roomId: '');
      expect(sent!.containsKey('roomId'), isFalse);
    });

    test('the function\'s refusal reaches the caller, and a strange answer is not trusted', () async {
      final refusing = GamesRepository(invoke: (fn, body) async => throw Exception('Games are not available right now'));
      expect(() => refusing.start(_ludo), throwsA(isA<Exception>()));
      final odd = GamesRepository(invoke: (fn, body) async => 'not a map');
      expect(() => odd.start(_ludo), throwsException);
    });
  });

  group('GamesStore and the SUD switch', () {
    test('SUD games show only while the panel\'s SUD switch is on, with no reload', () async {
      var on = false;
      final store = GamesStore(repo: _Repo([_tulasi, _ludo, _teen]), feed: (_) => () {}, sudEnabled: () => on);
      await store.refresh();
      expect(store.games!.map((g) => g.name), ['Teen Patti Gold']);
      on = true;
      expect(store.games!.map((g) => g.name), ['Teen Patti Gold', 'Ludo', 'TeenPatti']);
      on = false;
      expect(store.games!.map((g) => g.isSud), [false]);
      store.dispose();
    });

    test('before the first load there is no list at all', () {
      final store = GamesStore(repo: _Repo([_ludo]), feed: (_) => () {}, sudEnabled: () => true);
      expect(store.games, isNull);
      store.dispose();
    });
  });

  group('launching from the Games screen', () {
    Future<RemoteConfigController> config({required bool sud}) async {
      final c = RemoteConfigController(
        fetch: () async => {'feature_flags': {'games_enabled': true, if (sud) 'sud_games_enabled': true}},
        buildNumber: () async => 8,
        isIos: false,
      );
      await c.refresh(force: true);
      return c;
    }

    setUp(() => SharedPreferences.setMockInitialValues({}));

    Widget screen(_Repo repo, RemoteConfigController c, {ActiveLiveSessionController? live, List<String>? opened}) {
      final games = GamesScreen(
        repo: repo,
        config: c,
        isAndroid: true,
        balance: (_) => const SizedBox(),
        userId: (_) => 'u1',
        openGame: (ctx, g, s) async {
          opened?.add(s.url?.toString() ?? 'token:${s.token}');
          return GameExit.closed;
        },
      );
      return MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: live == null ? games : ChangeNotifierProvider<ActiveLiveSessionController>.value(value: live, child: games),
      );
    }

    testWidgets('with the SUD switch off only the Tulasi game is listed', (t) async {
      await t.pumpWidget(screen(_Repo([_tulasi, _ludo]), await config(sud: false)));
      await t.pumpAndSettle();
      expect(find.text('Teen Patti Gold'), findsOneWidget);
      expect(find.text('Ludo'), findsNothing);
    });

    testWidgets('with it on, the games are in two tabs: New holds SUD\'s, Old holds Tulasi\'s (neither name is shown)', (t) async {
      await t.pumpWidget(screen(_Repo([_tulasi, _ludo, _teen]), await config(sud: true)));
      await t.pumpAndSettle();
      expect(find.text('Ludo'), findsOneWidget);
      expect(find.text('TeenPatti'), findsOneWidget);
      expect(find.text('Teen Patti Gold'), findsNothing, reason: 'the old games are on the other tab');
      await t.tap(find.byKey(const ValueKey('games-tab-old')));
      await t.pumpAndSettle();
      expect(find.text('Teen Patti Gold'), findsOneWidget);
      expect(find.text('Ludo'), findsNothing);
      expect(find.textContaining('SUD'), findsNothing);
      expect(find.textContaining('Tulasi'), findsNothing);
    });

    testWidgets('a SUD party game opens at once (no coins, so no "bets" notice), in the live the person is in, in their language', (t) async {
      final repo = _Repo([_tulasi, _ludo]);
      final opened = <String>[];
      final live = ActiveLiveSessionController()..start(roomId: 'live-77', builder: (_) => const SizedBox(), hostName: 'Host');
      await t.pumpWidget(screen(repo, await config(sud: true), live: live, opened: opened));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('game-1000001')));
      await t.pumpAndSettle();
      expect(find.text('Before you play'), findsNothing, reason: 'a party game stakes nothing');
      expect(repo.started, [1000001]);
      expect(repo.rooms, ['live-77']);
      expect(repo.langs, ['ar']);
      expect(opened, ['https://sabalive.in/sud/play?gameId=1000001']);
    });

    testWidgets('a minimised live, or none, gives the person a table of their own', (t) async {
      final repo = _Repo([_ludo]);
      final live = ActiveLiveSessionController()
        ..start(roomId: 'live-77', builder: (_) => const SizedBox(), hostName: 'Host')
        ..minimize();
      await t.pumpWidget(screen(repo, await config(sud: true), live: live, opened: []));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('game-1000001')));
      await t.pumpAndSettle();
      expect(repo.rooms, [null]);
      // and with no live controller at all
      final repo2 = _Repo([_ludo]);
      await t.pumpWidget(screen(repo2, await config(sud: true), opened: []));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('game-1000001')));
      await t.pumpAndSettle();
      expect(repo2.rooms, [null]);
    });

    testWidgets('a SUD COIN game shows the notice, without the Tulasi-only sentence about adjusted outcomes', (t) async {
      final repo = _Repo([_teen]);
      await t.pumpWidget(screen(repo, await config(sud: true), opened: []));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('game-1000002')));
      await t.pumpAndSettle();
      expect(find.text('Before you play'), findsOneWidget);
      expect(find.textContaining('SABALIVE coins'), findsOneWidget);
      expect(find.textContaining('may adjust outcomes'), findsNothing);
      expect(find.textContaining('aged 18 or over'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('games-notice-check')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('games-notice-continue')));
      await t.pumpAndSettle();
      expect(repo.started, [1000002]);
    });

    testWidgets('the Tulasi notice is unchanged: it still says results may be adjusted', (t) async {
      await t.pumpWidget(screen(_Repo([_tulasi]), await config(sud: true), opened: []));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('game-2883')));
      await t.pumpAndSettle();
      expect(find.textContaining('may adjust outcomes'), findsOneWidget);
    });
  });
}
