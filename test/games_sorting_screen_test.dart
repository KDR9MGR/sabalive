import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:sabalive/data/games_repository.dart';
import 'package:sabalive/features/games/games_screen.dart';
import 'package:sabalive/state/remote_config_controller.dart';

/// The Games tab: the New / Old tabs (New = the newer games, Old = the first ones), and in each its sort and filter: what shows, in which order, what is remembered, and when a play is counted.
final _oct13 = DateTime.utc(2026, 10, 13);
final _gold = MerchantGame(id: 2883, name: 'Teen Patti Gold', identification: 'kingdoms', addedAt: _oct13);
final _roulette = MerchantGame(id: 2882, name: 'Roulette', identification: 'roulette', addedAt: _oct13);
final _pirate = MerchantGame(id: 1000001, name: 'Pirate Fishing', identification: 'sud-1', provider: GameProvider.sud, usesCoins: true, addedAt: DateTime.utc(2026, 10, 28));
final _ludo = MerchantGame(id: 1000002, name: 'Ludo', identification: 'sud-2', provider: GameProvider.sud, usesCoins: false, addedAt: DateTime.utc(2026, 10, 26));

class _Repo extends GamesRepository {
  _Repo(this.list, {this.counts = const {}});
  final List<MerchantGame> list;
  final Map<int, GamePopularity> counts;
  final played = <int>[];
  final started = <int>[];
  Object? startError;

  @override
  Future<List<MerchantGame>> games() async => list;

  @override
  Future<Map<int, GamePopularity>> popularity() async => counts;

  @override
  Future<GameSession> start(MerchantGame game, {String? roomId, String lang = 'en'}) async {
    if (startError != null) throw startError!;
    started.add(game.id);
    return GameSession(token: 'T-${game.id}', uid: 10001);
  }

  @override
  Future<void> recordPlay(MerchantGame game) async => played.add(game.id);
}

Future<RemoteConfigController> _config() async {
  final c = RemoteConfigController(
    fetch: () async => {'feature_flags': {'games_enabled': true, 'sud_games_enabled': true}},
    buildNumber: () async => 8,
    isIos: false,
  );
  await c.refresh(force: true);
  return c;
}

void main() {
  final all = [_gold, _roulette, _pirate, _ludo];

  Future<void> open(WidgetTester t, _Repo repo, {Future<Object?> Function(BuildContext, MerchantGame, GameSession)? openGame}) async {
    await t.binding.setSurfaceSize(const Size(800, 1600)); // every card on screen at once
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      home: GamesScreen(
        repo: repo,
        config: await _config(),
        isAndroid: true,
        balance: (_) => const SizedBox(),
        userId: (_) => 'u1',
        openGame: (c, g, s) async => null,
      ),
    ));
    await t.pumpAndSettle();
  }

  /// The ids of the cards on screen, in reading order (top to bottom, left to right).
  List<int> shown(WidgetTester t) {
    final at = <int, Offset>{};
    for (final g in all) {
      final f = find.byKey(ValueKey('game-${g.id}'));
      if (f.evaluate().isNotEmpty) at[g.id] = t.getTopLeft(f);
    }
    final e = at.entries.toList()..sort((a, b) => a.value.dy != b.value.dy ? a.value.dy.compareTo(b.value.dy) : a.value.dx.compareTo(b.value.dx));
    return [for (final x in e) x.key];
  }

  Future<void> goOld(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('games-tab-old')));
    await t.pumpAndSettle();
  }

  Future<void> goNew(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('games-tab-new')));
    await t.pumpAndSettle();
  }

  Future<void> sortBy(WidgetTester t, String key) async {
    await t.tap(find.byKey(const ValueKey('games-sort')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(ValueKey('games-sort-$key')));
    await t.pumpAndSettle();
  }

  Finder sortButtonText(String label) => find.descendant(of: find.byKey(const ValueKey('games-sort')), matching: find.text(label));

  setUp(() => SharedPreferences.setMockInitialValues({'games.notice.v1.u1': true, 'games.notice.sud.v1.u1': true}));

  group('the New and Old tabs', () {
    testWidgets('it opens on New (the newer games); Old holds the first games; neither provider is named', (t) async {
      await open(t, _Repo(all));
      expect(find.byKey(const ValueKey('games-tab-new')), findsOneWidget);
      expect(find.byKey(const ValueKey('games-tab-old')), findsOneWidget);
      expect(find.text('New'), findsOneWidget);
      expect(find.text('Old'), findsOneWidget);
      expect(shown(t), [1000001, 1000002], reason: 'the newer games only');
      await goOld(t);
      expect(shown(t), [2883, 2882], reason: 'the first games only, in the platform\'s order');
      await goNew(t);
      expect(shown(t), [1000001, 1000002]);
      for (final name in ['Tulasi', 'SUD', 'Sud', 'tulasi']) {
        expect(find.textContaining(name), findsNothing, reason: name);
      }
    });

    testWidgets('with only one kind of game there are no tabs and that list shows', (t) async {
      await open(t, _Repo([_gold, _roulette]));
      expect(find.byKey(const ValueKey('games-tab-new')), findsNothing);
      expect(shown(t), [2883, 2882]);
      await t.pumpWidget(const SizedBox());
      await open(t, _Repo([_pirate, _ludo]));
      expect(find.byKey(const ValueKey('games-tab-old')), findsNothing);
      expect(shown(t), [1000001, 1000002]);
    });

    testWidgets('the tab you left is remembered', (t) async {
      await open(t, _Repo(all));
      await goOld(t);
      expect((await SharedPreferences.getInstance()).getString('games.tab.v1'), 'oldGames');
      await t.pumpWidget(const SizedBox());
      await open(t, _Repo(all));
      expect(shown(t), [2883, 2882], reason: 'opens on Old again');
    });
  });

  testWidgets('it opens with the top picks (the platform\'s order), a sort button and, where both kinds exist, the three filter chips', (t) async {
    await open(t, _Repo(all));
    expect(shown(t), [1000001, 1000002]);
    expect(sortButtonText('Top picks'), findsOneWidget);
    for (final k in ['all', 'coin', 'party']) {
      expect(find.byKey(ValueKey('games-kind-$k')), findsOneWidget, reason: k);
    }
    await goOld(t);
    expect(find.byKey(const ValueKey('games-kind-coin')), findsNothing, reason: 'the first games are all coin games: a filter would change nothing');
  });

  testWidgets('A to Z, Newest first and Oldest first reorder the cards, and the button names the choice', (t) async {
    await open(t, _Repo(all));
    await sortBy(t, 'nameAz');
    expect(shown(t), [1000002, 1000001], reason: 'Ludo, Pirate Fishing');
    expect(sortButtonText('A to Z'), findsOneWidget);
    await sortBy(t, 'newest');
    expect(shown(t), [1000001, 1000002], reason: 'added 10-28, 10-26');
    await sortBy(t, 'oldest');
    expect(shown(t), [1000002, 1000001]);
    await sortBy(t, 'topPicks');
    expect(shown(t), [1000001, 1000002]);
    await goOld(t);
    await sortBy(t, 'nameAz');
    expect(shown(t), [2882, 2883], reason: 'Roulette, Teen Patti Gold');
    await sortBy(t, 'newest');
    expect(shown(t), [2883, 2882], reason: 'added together: the later id first');
  });

  testWidgets('Most played follows the counts the server gave', (t) async {
    await open(t, _Repo(all, counts: {1000002: const GamePopularity(plays: 80, players: 30), 2882: const GamePopularity(plays: 10, players: 4)}));
    await sortBy(t, 'mostPlayed');
    expect(shown(t), [1000002, 1000001]);
    await goOld(t);
    expect(shown(t), [2882, 2883], reason: 'most opened first; the sort is kept when the tab changes');
  });

  testWidgets('Most played with no counts (an older server) leaves the order as it was', (t) async {
    await open(t, _Repo(all));
    await sortBy(t, 'mostPlayed');
    expect(shown(t), [1000001, 1000002]);
  });

  testWidgets('the filter chips: coin games, party games, all', (t) async {
    await open(t, _Repo(all));
    await t.tap(find.byKey(const ValueKey('games-kind-coin')));
    await t.pumpAndSettle();
    expect(shown(t), [1000001], reason: 'the party game is gone');
    await t.tap(find.byKey(const ValueKey('games-kind-party')));
    await t.pumpAndSettle();
    expect(shown(t), [1000002], reason: 'only the party game');
    await t.tap(find.byKey(const ValueKey('games-kind-all')));
    await t.pumpAndSettle();
    expect(shown(t), [1000001, 1000002]);
  });

  testWidgets('a filter and a sort work together', (t) async {
    await open(t, _Repo(all));
    await t.tap(find.byKey(const ValueKey('games-kind-coin')));
    await t.pumpAndSettle();
    await sortBy(t, 'nameAz');
    expect(shown(t), [1000001]);
  });

  testWidgets('the choice is remembered: the next time the tab opens the same way', (t) async {
    await open(t, _Repo(all));
    await sortBy(t, 'newest');
    await t.tap(find.byKey(const ValueKey('games-kind-coin')));
    await t.pumpAndSettle();
    await goOld(t);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('games.sort.v1'), 'newest');
    expect(prefs.getString('games.kind.v1'), 'coin');
    expect(prefs.getString('games.tab.v1'), 'oldGames');

    await t.pumpWidget(const SizedBox()); // closed; a fresh tab
    await t.pumpWidget(MaterialApp(
      home: GamesScreen(repo: _Repo(all), config: await _config(), isAndroid: true, balance: (_) => const SizedBox(), userId: (_) => 'u1', openGame: (c, g, s) async => null),
    ));
    await t.pumpAndSettle();
    expect(shown(t), [2883, 2882], reason: 'Old, newest first');
    expect(sortButtonText('Newest first'), findsOneWidget);
  });

  testWidgets('a remembered choice that is nonsense is ignored', (t) async {
    SharedPreferences.setMockInitialValues({'games.sort.v1': 'sideways', 'games.kind.v1': 'weird', 'games.tab.v1': 'elsewhere'});
    await open(t, _Repo(all));
    expect(shown(t), [1000001, 1000002]);
    expect(sortButtonText('Top picks'), findsOneWidget);
  });

  testWidgets('only one kind of game in a tab: no filter chips (they could change nothing), but the sort still works', (t) async {
    await open(t, _Repo([_gold, _roulette]));
    expect(find.byKey(const ValueKey('games-kind-coin')), findsNothing);
    await sortBy(t, 'nameAz');
    expect(shown(t), [2882, 2883]);
  });

  testWidgets('a remembered "Party games" filter when only coin games are left shows everything', (t) async {
    SharedPreferences.setMockInitialValues({'games.kind.v1': 'party'});
    await open(t, _Repo([_gold, _roulette]));
    expect(shown(t), [2883, 2882], reason: 'nothing would be left, so nothing is filtered');
  });

  testWidgets('one game: no controls at all', (t) async {
    await open(t, _Repo([_gold]));
    expect(find.byKey(const ValueKey('games-sort')), findsNothing);
    expect(shown(t), [2883]);
  });

  group('a play is counted', () {
    testWidgets('when the launch goes through, once, for that game', (t) async {
      final repo = _Repo(all);
      await open(t, repo);
      await t.tap(find.byKey(const ValueKey('game-1000001')));
      await t.pumpAndSettle();
      expect(repo.started, [1000001]);
      expect(repo.played, [1000001]);
    });

    testWidgets('not when the server refuses the launch (under 18, no date of birth)', (t) async {
      final repo = _Repo(all)..startError = const PostgrestException(message: 'Games are for people aged 18 or over', code: 'P0001');
      await open(t, repo);
      await goOld(t);
      await t.tap(find.byKey(const ValueKey('game-2883')));
      await t.pumpAndSettle();
      expect(repo.played, isEmpty);
    });

    testWidgets('not when the person cancels the first-time notice', (t) async {
      SharedPreferences.setMockInitialValues({});
      final repo = _Repo(all);
      await open(t, repo);
      await goOld(t);
      await t.tap(find.byKey(const ValueKey('game-2883')));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(repo.started, isEmpty);
      expect(repo.played, isEmpty);
    });
  });
}
