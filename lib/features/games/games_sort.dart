import '../../data/games_repository.dart';

/// How the Games tab orders its cards.
enum GameSort {
  /// The platform's own order (the old games' list, then the new ones in the panel's order): what the owner put first.
  topPicks,

  /// Opened most in the last 14 days (ties keep the top-picks order).
  mostPlayed,

  /// Added most recently, and the other way round.
  newest,
  oldest,

  /// By name.
  nameAz,
}

/// The Games tab's two tabs: "New" holds the newer games (the ones from the second provider) and "Old" the first ones. Neither provider is named anywhere in the app.
enum GameTab { newGames, oldGames }

/// [games] split into the two tabs, each keeping the platform's order.
({List<MerchantGame> newGames, List<MerchantGame> oldGames}) splitGames(Iterable<MerchantGame> games) => (
      newGames: [for (final g in games) if (g.isSud) g],
      oldGames: [for (final g in games) if (!g.isSud) g],
    );

/// Which games the Games tab shows: all of them, the ones you stake coins in, or the party games (no coins).
enum GameKind { all, coin, party }

/// Are there both kinds? (With only one kind a "Coin games / Party games" filter would do nothing.)
bool hasBothKinds(Iterable<MerchantGame> games) => games.any((g) => g.stakesCoins) && games.any((g) => !g.stakesCoins);

/// [games] (in the platform's order) filtered by [kind] and put in the order of [sort]. Every order is stable: whatever two games tie on, the one that
/// comes first in [games] comes first. [popularity] is by game id; a game without a count counts as never opened. A game without an `addedAt` (a server
/// that does not have it yet) counts as the oldest; games added at the same moment (all that existed when the column was introduced) go by id, which
/// grows with time.
List<MerchantGame> arrangeGames(
  List<MerchantGame> games, {
  required GameSort sort,
  GameKind kind = GameKind.all,
  Map<int, GamePopularity> popularity = const {},
}) {
  final order = {for (var i = 0; i < games.length; i++) games[i].id: i};
  final kept = [
    for (final g in games)
      if (kind == GameKind.all || (kind == GameKind.coin ? g.stakesCoins : !g.stakesCoins)) g,
  ];
  int byOrder(MerchantGame a, MerchantGame b) => order[a.id]!.compareTo(order[b.id]!);
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  DateTime added(MerchantGame g) => g.addedAt ?? epoch;

  int compare(MerchantGame a, MerchantGame b) {
    switch (sort) {
      case GameSort.topPicks:
        return byOrder(a, b);
      case GameSort.mostPlayed:
        final pa = popularity[a.id], pb = popularity[b.id];
        final plays = (pb?.plays ?? 0).compareTo(pa?.plays ?? 0);
        if (plays != 0) return plays;
        final players = (pb?.players ?? 0).compareTo(pa?.players ?? 0);
        return players != 0 ? players : byOrder(a, b);
      case GameSort.newest:
        final c = added(b).compareTo(added(a));
        if (c != 0) return c;
        final id = b.id.compareTo(a.id);
        return id != 0 ? id : byOrder(a, b);
      case GameSort.oldest:
        final c = added(a).compareTo(added(b));
        if (c != 0) return c;
        final id = a.id.compareTo(b.id);
        return id != 0 ? id : byOrder(a, b);
      case GameSort.nameAz:
        final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return c != 0 ? c : byOrder(a, b);
    }
  }

  return kept..sort(compare);
}
