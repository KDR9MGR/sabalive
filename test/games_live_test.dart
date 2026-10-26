import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabalive/data/games_repository.dart';
import 'package:sabalive/features/games/game_launcher.dart';
import 'package:sabalive/features/games/games_strip.dart';
import 'package:sabalive/state/games_store.dart';
import 'package:sabalive/state/remote_config_controller.dart';

const _gold = MerchantGame(id: 2883, name: 'Teen Patti Gold', identification: 'kingdoms');
const _tp = MerchantGame(id: 2882, name: 'Teen Patti', identification: 'kingdoms2');
const _roulette = MerchantGame(id: 2890, name: 'Roulette', identification: 'roulette');

/// A repository whose list the test edits, the way the Tulasi panel's "Sync Game List" edits `merchant_games`.
class _Repo extends GamesRepository {
  _Repo(this.list);
  List<MerchantGame> list;
  int loads = 0;
  Object? listError;
  Completer<void>? hold;
  final started = <int>[];

  @override
  Future<List<MerchantGame>> games() async {
    loads++;
    final h = hold;
    if (h != null) await h.future;
    if (listError != null) throw listError!;
    return List.of(list);
  }

  @override
  Future<GameSession> start(MerchantGame game, {String? roomId, String lang = 'en'}) async {
    started.add(game.id);
    return GameSession(token: 'TOKEN-${game.id}', uid: 10001);
  }
}

/// A change feed the test fires by hand (stands in for Supabase Realtime).
class _Feed {
  void Function()? fire;
  int stopped = 0;
  void Function() call(void Function() onChange) {
    fire = onChange;
    return () {
      stopped++;
      fire = null;
    };
  }
}

const _fast = Duration(milliseconds: 20);
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 80));

Future<RemoteConfigController> _config(bool on) async {
  final c = RemoteConfigController(
    fetch: () async => {'feature_flags': {if (on) 'games_enabled': true}},
    buildNumber: () async => 8,
    isIos: false,
  );
  await c.refresh(force: true);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GamesStore (the list follows the Tulasi panel)', () {
    test('start loads the list and tells its listeners', () async {
      final repo = _Repo([_gold, _tp]);
      final store = GamesStore(repo: repo, feed: _Feed().call, window: _fast);
      var heard = 0;
      store.addListener(() => heard++);
      expect(store.games, isNull);
      store.start();
      await _settle();
      expect(store.games!.map((g) => g.name), ['Teen Patti Gold', 'Teen Patti']);
      expect(heard, greaterThan(0));
      store.dispose();
    });

    test('a change from the panel (game added, game switched off, game renamed) shows up without a restart', () async {
      final repo = _Repo([_gold, _tp]);
      final feed = _Feed();
      final store = GamesStore(repo: repo, feed: feed.call, window: _fast)..start();
      await _settle();

      repo.list = [_gold, _tp, _roulette]; // Sync Game List: a new game
      feed.fire!();
      await _settle();
      expect(store.games!.length, 3);

      repo.list = [_gold, _roulette]; // a game is disabled (it drops out of the enabled list)
      feed.fire!();
      await _settle();
      expect(store.games!.map((g) => g.id), [2883, 2890]);

      repo.list = [const MerchantGame(id: 2883, name: 'Teen Patti Royal', identification: 'kingdoms'), _roulette]; // renamed
      feed.fire!();
      await _settle();
      expect(store.games!.first.name, 'Teen Patti Royal');
      store.dispose();
    });

    test('a burst of changes (a whole list pushed) is read once, not once per row', () async {
      final repo = _Repo([_gold]);
      final feed = _Feed();
      final store = GamesStore(repo: repo, feed: feed.call, window: _fast)..start();
      await _settle();
      final before = repo.loads;
      for (var i = 0; i < 12; i++) {
        feed.fire!();
      }
      await _settle();
      expect(repo.loads - before, 1);
      store.dispose();
    });

    test('a change that arrives while a read is running is not lost', () async {
      final repo = _Repo([_gold])..hold = Completer<void>();
      final feed = _Feed();
      final store = GamesStore(repo: repo, feed: feed.call, window: _fast)..start();
      await _settle();
      repo.list = [_gold, _tp];
      feed.fire!(); // arrives mid-read
      repo.hold!.complete();
      repo.hold = null;
      await _settle();
      await _settle();
      expect(store.games!.length, 2);
      store.dispose();
    });

    test('coming back to the app reads the list again', () async {
      final repo = _Repo([_gold]);
      final store = GamesStore(repo: repo, feed: _Feed().call, window: _fast)..start();
      await _settle();
      repo.list = [_gold, _tp];
      store.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _settle();
      expect(store.games!.length, 2);
      store.dispose();
    });

    test('a failed read keeps the games already shown and records the error; the next success clears it', () async {
      final repo = _Repo([_gold]);
      final store = GamesStore(repo: repo, feed: _Feed().call, window: _fast)..start();
      await _settle();
      repo.listError = Exception('offline');
      await store.refresh();
      expect(store.games!.length, 1);
      expect(store.error, isNotNull);
      repo.listError = null;
      await store.refresh();
      expect(store.error, isNull);
      store.dispose();
    });

    test('start twice listens once; stop stops listening and later changes do nothing', () async {
      final repo = _Repo([_gold]);
      final feed = _Feed();
      final store = GamesStore(repo: repo, feed: feed.call, window: _fast);
      store.start();
      store.start();
      await _settle();
      expect(repo.loads, 1);
      final fire = feed.fire!;
      store.stop();
      expect(feed.stopped, 1);
      final before = repo.loads;
      fire();
      await _settle();
      expect(repo.loads, before);
      store.dispose();
    });

    test('if Realtime cannot start, the list still loads', () async {
      final repo = _Repo([_gold]);
      final store = GamesStore(repo: repo, feed: (_) => throw StateError('no socket'), window: _fast)..start();
      await _settle();
      expect(store.games!.length, 1);
      store.dispose();
    });
  });

  group('GamesStrip (Home)', () {
    setUp(() => SharedPreferences.setMockInitialValues({'games.notice.v1.u1': true}));

    GameLauncher launcher(_Repo repo, [OpenGame? open]) =>
        GameLauncher(repo: repo, openGame: open ?? (c, g, s) async => null, userId: (_) => 'u1');

    Future<void> mount(WidgetTester t, {required GamesStore store, required RemoteConfigController config, required GameLauncher launcher, bool android = true, void Function(BuildContext)? onSeeAll}) {
      return t.pumpWidget(MaterialApp(
        home: Scaffold(body: GamesStrip(store: store, config: config, launcher: launcher, isAndroid: android, onSeeAll: onSeeAll)),
      ));
    }

    testWidgets('switched off, or not Android, or no games: nothing is drawn and the database is not asked when off', (t) async {
      final repo = _Repo([_gold]);
      final store = GamesStore(repo: repo, feed: _Feed().call, window: _fast);
      await mount(t, store: store, config: await _config(false), launcher: launcher(repo));
      await t.pump();
      expect(find.text('Games'), findsNothing);
      expect(repo.loads, 0);

      await t.pumpWidget(const SizedBox());
      await mount(t, store: store, config: await _config(true), launcher: launcher(repo), android: false);
      await t.pump();
      expect(find.text('Games'), findsNothing);
      expect(repo.loads, 0);

      await t.pumpWidget(const SizedBox());
      final empty = _Repo(const []);
      final emptyStore = GamesStore(repo: empty, feed: _Feed().call, window: _fast);
      await mount(t, store: emptyStore, config: await _config(true), launcher: launcher(empty));
      await t.runAsync(_settle);
      await t.pump();
      expect(find.text('Games'), findsNothing);
      store.dispose();
      emptyStore.dispose();
    });

    testWidgets('switched on: a Games row with the platform\'s games; See All opens the Games tab', (t) async {
      final repo = _Repo([_gold, _tp]);
      final store = GamesStore(repo: repo, feed: _Feed().call, window: _fast);
      var seeAll = 0;
      await mount(t, store: store, config: await _config(true), launcher: launcher(repo), onSeeAll: (_) => seeAll++);
      await t.runAsync(_settle);
      await t.pump();
      expect(find.text('Games'), findsOneWidget);
      expect(find.text('Teen Patti Gold'), findsOneWidget);
      expect(find.text('Teen Patti'), findsOneWidget);
      await t.tap(find.text('See All'));
      expect(seeAll, 1);
      store.dispose();
    });

    testWidgets('tapping a game plays it with a fresh session', (t) async {
      final repo = _Repo([_gold, _tp]);
      final store = GamesStore(repo: repo, feed: _Feed().call, window: _fast);
      final opened = <String>[];
      await mount(t, store: store, config: await _config(true), launcher: launcher(repo, (c, g, s) async {
        opened.add('${g.id}:${s.token}');
        return null;
      }));
      await t.runAsync(_settle);
      await t.pump();
      await t.tap(find.byKey(const ValueKey('game-2882')));
      await t.pumpAndSettle();
      expect(repo.started, [2882]);
      expect(opened, ['2882:TOKEN-2882']);
      store.dispose();
    });

    testWidgets('the row follows the panel live: a game appears, another disappears, and the whole row hides when none are left', (t) async {
      final repo = _Repo([_gold]);
      final feed = _Feed();
      final store = GamesStore(repo: repo, feed: feed.call, window: _fast);
      await mount(t, store: store, config: await _config(true), launcher: launcher(repo));
      await t.runAsync(_settle);
      await t.pump();
      expect(find.text('Roulette'), findsNothing);

      repo.list = [_gold, _roulette];
      feed.fire!();
      await t.pump(_fast * 2); // the store's short wait runs on the test's clock
      await t.pump();
      expect(find.text('Roulette'), findsOneWidget);

      repo.list = [_roulette];
      feed.fire!();
      await t.pump(_fast * 2);
      await t.pump();
      expect(find.text('Teen Patti Gold'), findsNothing);
      expect(find.text('Roulette'), findsOneWidget);

      repo.list = const [];
      feed.fire!();
      await t.pump(_fast * 2);
      await t.pump();
      expect(find.text('Games'), findsNothing);
      store.dispose();
    });

    testWidgets('the panel\'s Games switch flips the row on and off while the app is open', (t) async {
      final repo = _Repo([_gold]);
      var on = false;
      final config = RemoteConfigController(
        fetch: () async => {'feature_flags': {if (on) 'games_enabled': true}},
        buildNumber: () async => 8,
        isIos: false,
      );
      await config.refresh(force: true);
      final store = GamesStore(repo: repo, feed: _Feed().call, window: _fast);
      await mount(t, store: store, config: config, launcher: launcher(repo));
      await t.pump();
      expect(find.text('Games'), findsNothing);

      on = true; // the panel switches Games on; the app hears app_config change and re-reads it
      await t.runAsync(() => config.refresh(force: true));
      await t.runAsync(_settle);
      await t.pump();
      expect(find.text('Games'), findsOneWidget);

      on = false;
      await t.runAsync(() => config.refresh(force: true));
      await t.pump();
      expect(find.text('Games'), findsNothing);
      store.dispose();
    });
  });

  group('wiring (guards against a regression that tests cannot see)', () {
    String src(String p) => File(p).readAsStringSync();

    test('games open as a panel through the navigator in scope (the live room\'s own while a live is on screen), never a raw MaterialPageRoute (which would replace the live)', () {
      for (final f in ['lib/features/games/game_launcher.dart', 'lib/features/games/games_screen.dart', 'lib/features/games/games_strip.dart', 'lib/features/games/game_webview_screen.dart', 'lib/features/games/game_panel.dart']) {
        expect(src(f).contains('MaterialPageRoute'), isFalse, reason: f);
      }
      expect(src('lib/features/games/game_launcher.dart').contains('showGamePanel'), isTrue);
      expect(src('lib/features/games/game_panel.dart').contains('Navigator.of(context)'), isTrue); // the navigator in scope, i.e. the live room's own
      expect(src('lib/features/games/game_panel.dart').contains('GamePanelRoute<T>(page: page, modal: !fromLive)'), isTrue);
    });

    test('Home shows the games row, and the Games tab and in-room menus still reach the Games screen', () {
      expect(src('lib/features/home/home_screen.dart').contains('GamesStrip()'), isTrue);
      expect(src('lib/router/app_nav.dart').contains('GamesScreen()'), isTrue);
      expect(src('lib/features/shell/main_shell.dart').contains('AppNav.games(context)'), isTrue);
    });

    test('the app lists only games that are on in Tulasi AND not hidden from our panel', () {
      final s = src('lib/data/games_repository.dart');
      expect(s.contains(".eq('status', 1)"), isTrue);
      expect(s.contains(".eq('hidden', false)"), isTrue);
    });

    test('the store listens to merchant_games and app_config', () {
      final s = src('lib/state/games_store.dart');
      expect(s.contains("table: 'merchant_games'"), isTrue);
      expect(s.contains("table: 'app_config'"), isTrue);
    });
  });
}
