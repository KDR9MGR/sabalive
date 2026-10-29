import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/games_repository.dart';
import 'package:sabalive/features/games/games_sort.dart';

/// How the Games tab orders and filters its cards (the pure rules; the screen is tested in games_sorting_screen_test.dart).
void main() {
  final oct13 = DateTime.utc(2026, 10, 13, 9);
  final oct26 = DateTime.utc(2026, 10, 26, 9);
  final oct28 = DateTime.utc(2026, 10, 28, 9);

  // the platform's order: Tulasi's list, then SUD's in the panel's order
  final teenPattiGold = MerchantGame(id: 2883, name: 'Teen Patti Gold', identification: 'a', addedAt: oct13);
  final roulette = MerchantGame(id: 2882, name: 'roulette', identification: 'b', addedAt: oct13); // same moment as the one above
  final fishing = const MerchantGame(id: 2890, name: 'Fishing', identification: 'c'); // a server without added_at: no date
  final pirate = MerchantGame(id: 1000001, name: 'Pirate Fishing', identification: 'sud-1', provider: GameProvider.sud, usesCoins: true, addedAt: oct28);
  final ludo = MerchantGame(id: 1000002, name: 'Ludo', identification: 'sud-2', provider: GameProvider.sud, usesCoins: false, addedAt: oct26);
  final games = [teenPattiGold, roulette, fishing, pirate, ludo];
  List<int> ids(Iterable<MerchantGame> g) => [for (final x in g) x.id];

  test('which games stake coins: every Tulasi game, and a SUD game marked as a coin game', () {
    expect([for (final g in games) g.stakesCoins], [true, true, true, true, false]);
    expect(hasBothKinds(games), isTrue);
    expect(hasBothKinds([teenPattiGold, roulette, fishing]), isFalse, reason: 'only coin games: a coin / party filter would do nothing');
    expect(hasBothKinds([ludo]), isFalse);
    expect(hasBothKinds(const []), isFalse);
  });

  test('Top picks is the platform\'s own order, untouched', () {
    expect(ids(arrangeGames(games, sort: GameSort.topPicks)), ids(games));
  });

  test('the kind filter keeps the order and only drops games', () {
    expect(ids(arrangeGames(games, sort: GameSort.topPicks, kind: GameKind.coin)), [2883, 2882, 2890, 1000001]);
    expect(ids(arrangeGames(games, sort: GameSort.topPicks, kind: GameKind.party)), [1000002]);
    expect(ids(arrangeGames(games, sort: GameSort.topPicks, kind: GameKind.all)), ids(games));
  });

  test('Most played: by times opened, then by different people, then the top-picks order; games nobody opened keep their order', () {
    final pop = {
      2882: const GamePopularity(plays: 40, players: 5),
      2883: const GamePopularity(plays: 40, players: 9), // same plays, more people: first
      1000001: const GamePopularity(plays: 90, players: 20),
    };
    expect(ids(arrangeGames(games, sort: GameSort.mostPlayed, popularity: pop)), [1000001, 2883, 2882, 2890, 1000002]);
  });

  test('Most played with no counts at all (an older server, nothing opened yet) is just the top picks', () {
    expect(ids(arrangeGames(games, sort: GameSort.mostPlayed)), ids(games));
  });

  test('Newest first: the latest added first; games added at the same moment go by id (it grows with time); no date counts as the oldest', () {
    expect(ids(arrangeGames(games, sort: GameSort.newest)), [1000001, 1000002, 2883, 2882, 2890]);
  });

  test('Oldest first is the exact opposite', () {
    expect(ids(arrangeGames(games, sort: GameSort.oldest)), [2890, 2882, 2883, 1000002, 1000001]);
  });

  test('A to Z ignores capitals; equal names keep the top-picks order', () {
    expect([for (final g in arrangeGames(games, sort: GameSort.nameAz)) g.name], ['Fishing', 'Ludo', 'Pirate Fishing', 'roulette', 'Teen Patti Gold']);
    final twins = [MerchantGame(id: 5, name: 'Same'), MerchantGame(id: 3, name: 'same'), MerchantGame(id: 4, name: 'Aaa')];
    expect(ids(arrangeGames(twins, sort: GameSort.nameAz)), [4, 5, 3]);
  });

  test('a filter and an order together', () {
    final pop = {1000001: const GamePopularity(plays: 5, players: 2), 2890: const GamePopularity(plays: 50, players: 30)};
    expect(ids(arrangeGames(games, sort: GameSort.mostPlayed, kind: GameKind.coin, popularity: pop)), [2890, 1000001, 2883, 2882]);
    expect(ids(arrangeGames(games, sort: GameSort.newest, kind: GameKind.party, popularity: pop)), [1000002]);
  });

  test('the input list is not changed, and an empty list is fine', () {
    final before = ids(games);
    arrangeGames(games, sort: GameSort.nameAz);
    expect(ids(games), before);
    expect(arrangeGames(const [], sort: GameSort.newest), isEmpty);
  });

  test('added_at is read from either table\'s row; a missing or unreadable one is null', () {
    expect(MerchantGame.fromRow({'id': 1, 'name': 'x', 'added_at': '2026-10-13T09:00:00+00:00'}).addedAt, DateTime.utc(2026, 10, 13, 9));
    expect(MerchantGame.fromRow({'id': 1, 'name': 'x'}).addedAt, isNull);
    expect(MerchantGame.fromRow({'id': 1, 'name': 'x', 'added_at': 'not a date'}).addedAt, isNull);
    expect(MerchantGame.fromSudRow({'id': 1000001, 'name': 'x', 'provider_game_id': '19', 'added_at': '2026-10-28T09:00:00+00:00'}).addedAt, DateTime.utc(2026, 10, 28, 9));
  });
}
