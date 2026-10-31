import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/utils/formatters.dart';
import '../../core/media/disk_cached_image.dart';
import '../../data/games_repository.dart';
import '../../state/games_store.dart';
import '../../state/remote_config_controller.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';
import 'game_launcher.dart';
import 'games_sort.dart';
import '../../core/i18n/text.dart';

/// Are the games on for this phone? The panel's `games_enabled` switch (default off), and Android only for now (iOS waits for store review).
bool gamesAvailable(RemoteConfigController config, {bool? isAndroid}) =>
    (isAndroid ?? Platform.isAndroid) && config.flag('games_enabled', defaultValue: false);

/// The Games tab. While games are switched off, or on a phone that is not Android, it shows the "coming soon" screen; otherwise the
/// platform's games in two tabs, New and Old, kept in step with the panel by [GamesStore] (a change there shows here without a restart).
class GamesScreen extends StatefulWidget {
  const GamesScreen({
    super.key,
    this.repo,
    this.config,
    this.isAndroid,
    this.openGame = openGameInWebView,
    this.onRecharge,
    this.userId,
    this.balance,
    this.store,
  });

  final GamesRepository? repo;
  final RemoteConfigController? config;
  final bool? isAndroid;
  final OpenGame openGame;
  final Future<void> Function(BuildContext context)? onRecharge;
  final String? Function(BuildContext context)? userId;

  /// The coin balance shown in the app bar (default: the wallet's balance).
  final Widget Function(BuildContext context)? balance;

  /// The shared game list (default: the app-wide one; a screen given its own [repo] gets a private one, for tests).
  final GamesStore? store;

  @override
  State<GamesScreen> createState() => _GamesScreenState();
}

class _GamesScreenState extends State<GamesScreen> {
  late final GamesStore _store = widget.store ?? (widget.repo != null
      ? GamesStore(repo: widget.repo, feed: (_) => () {}, sudEnabled: () => _config.flag('sud_games_enabled', defaultValue: false))
      : GamesStore.instance);
  late final GameLauncher _launcher =
      GameLauncher(repo: widget.repo, openGame: widget.openGame, onRecharge: widget.onRecharge, userId: widget.userId);
  RemoteConfigController get _config => widget.config ?? RemoteConfigController.instance;

  bool get _on => gamesAvailable(_config, isAndroid: widget.isAndroid);

  // How the cards are ordered and which kind is shown: remembered on this phone, so the tab opens the way the person left it.
  static const _sortKey = 'games.sort.v1';
  static const _kindKey = 'games.kind.v1';
  static const _tabKey = 'games.tab.v1';
  GameSort _sort = GameSort.topPicks;
  GameKind _kind = GameKind.all;
  GameTab _tab = GameTab.newGames;

  Future<void> _loadChoice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sort = GameSort.values.asNameMap()[prefs.getString(_sortKey)];
      final kind = GameKind.values.asNameMap()[prefs.getString(_kindKey)];
      final tab = GameTab.values.asNameMap()[prefs.getString(_tabKey)];
      if (!mounted || (sort == null && kind == null && tab == null)) return;
      setState(() {
        _sort = sort ?? _sort;
        _kind = kind ?? _kind;
        _tab = tab ?? _tab;
      });
    } catch (_) {
      // not remembered: the tab opens with the top picks
    }
  }

  Future<void> _remember(String key, String value) async {
    try {
      await (await SharedPreferences.getInstance()).setString(key, value);
    } catch (_) {}
  }

  void _setSort(GameSort sort) {
    setState(() => _sort = sort);
    unawaited(_remember(_sortKey, sort.name));
  }

  void _setTab(GameTab tab) {
    setState(() => _tab = tab);
    unawaited(_remember(_tabKey, tab.name));
  }

  void _setKind(GameKind kind) {
    setState(() => _kind = kind);
    unawaited(_remember(_kindKey, kind.name));
  }

  static String _sortLabel(GameSort s) => switch (s) {
    GameSort.topPicks => 'Top picks',
    GameSort.mostPlayed => 'Most played',
    GameSort.newest => 'Newest first',
    GameSort.oldest => 'Oldest first',
    GameSort.nameAz => 'A to Z',
  };

  static String _kindLabel(GameKind k) => switch (k) {
    GameKind.all => 'All',
    GameKind.coin => 'Coin games',
    GameKind.party => 'Party games',
  };

  Future<void> _openSort() async {
    final picked = await showModalBottomSheet<GameSort>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Sort by', style: TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ),
            for (final s in GameSort.values)
              ListTile(
                key: ValueKey('games-sort-${s.name}'),
                title: Text(_sortLabel(s)),
                trailing: s == _sort ? Icon(Icons.check_rounded, color: AppColors.primaryBright) : null,
                onTap: () => Navigator.pop(sheet, s),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null && mounted) _setSort(picked);
  }

  /// The New / Old tabs (shown only when both have games: a tab with nothing in it would be pointless).
  Widget _tabs(GameTab tab) {
    Widget one(GameTab t, String label) {
      final on = tab == t;
      return Expanded(
        child: GestureDetector(
          key: ValueKey('games-tab-${t == GameTab.newGames ? 'new' : 'old'}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _setTab(t),
          child: Container(
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? AppColors.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(19),
            ),
            child: Text(label,
                style: TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                    color: on ? AppColors.textOnPrimary : AppColors.textSecondary)),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppColors.stroke),
        ),
        child: Row(children: [one(GameTab.newGames, 'New'), one(GameTab.oldGames, 'Old')]),
      ),
    );
  }

  /// The filter chips (only with BOTH kinds of game: a filter that cannot change anything is not offered) and the sort button.
  Widget _controls({required bool bothKinds, required GameKind kind}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: bothKinds
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final k in GameKind.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              key: ValueKey('games-kind-${k.name}'),
                              label: Text(_kindLabel(k)),
                              selected: kind == k,
                              onSelected: (_) => _setKind(k),
                            ),
                          ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          TextButton.icon(
            key: const ValueKey('games-sort'),
            onPressed: _openSort,
            icon: const Icon(Icons.swap_vert_rounded, size: 18),
            label: Text(_sortLabel(_sort)),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _config.addListener(_onConfig);
    if (_on) _store.start();
    unawaited(_loadChoice());
  }

  @override
  void dispose() {
    _config.removeListener(_onConfig);
    _launcher.dispose();
    if (widget.store == null && widget.repo != null) _store.dispose();
    super.dispose();
  }

  void _onConfig() {
    if (!mounted) return;
    if (_on) _store.start();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!_on) return const _ComingSoon();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Games'),
        actions: [Padding(padding: const EdgeInsets.only(right: 16), child: Center(child: (widget.balance ?? _coinChip)(context)))],
      ),
      body: ListenableBuilder(listenable: _store, builder: (context, _) => _body()),
    );
  }

  Widget _coinChip(BuildContext context) {
    final coins = context.watch<WalletController>().coins;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.monetization_on_rounded, color: AppColors.coin, size: 16),
        const SizedBox(width: 4),
        Text(compactCount(coins), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      ],
    );
  }

  Widget _body() {
    final games = _store.games;
    if (games == null && _store.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_store.error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textMuted)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _store.refresh, child: const Text('Try again')),
          ],
        ),
      );
    }
    if (games == null) return const Center(child: CircularProgressIndicator());
    if (games.isEmpty) {
      return RefreshIndicator(
        onRefresh: _store.refresh,
        child: ListView(
          children: const [
            SizedBox(height: 200),
            Center(child: Text('No games available right now', style: TextStyle(color: AppColors.textMuted))),
          ],
        ),
      );
    }
    // "New" and "Old" tabs, only when both have games; with just one kind of game that list is shown as it is
    final split = splitGames(games);
    final bothTabs = split.newGames.isNotEmpty && split.oldGames.isNotEmpty;
    final tab = bothTabs ? _tab : (split.newGames.isNotEmpty ? GameTab.newGames : GameTab.oldGames);
    final inTab = tab == GameTab.newGames ? split.newGames : split.oldGames;
    // a remembered "Coin games" filter does nothing when only one kind is left in this tab: then everything shows
    final bothKinds = hasBothKinds(inTab);
    final kind = bothKinds ? _kind : GameKind.all;
    final shown = arrangeGames(inTab, sort: _sort, kind: kind, popularity: _store.popularity);
    return RefreshIndicator(
      onRefresh: _store.refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (bothTabs) SliverToBoxAdapter(child: _tabs(tab)),
          if (inTab.length > 1) SliverToBoxAdapter(child: _controls(bothKinds: bothKinds, kind: kind)),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
            sliver: SliverGrid.count(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.95,
              children: [
                for (final g in shown)
                  ValueListenableBuilder<int?>(
                    valueListenable: _launcher.launching,
                    builder: (context, launching, _) =>
                        GameCard(game: g, busy: launching == g.id, onTap: () => _launcher.play(context, g)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One game as a card: its picture (or a controller icon) and name.
class GameCard extends StatelessWidget {
  const GameCard({super.key, required this.game, required this.busy, required this.onTap});

  final MerchantGame game;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: ValueKey('game-${game.id}'),
      onTap: game.launchable ? onTap : null,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.stroke),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (game.imageUrl != null)
                    Image(image: ResizeImage(DiskCachedNetworkImage(game.imageUrl!), width: 640), fit: BoxFit.cover, errorBuilder: (_, _, _) => const _GameIcon())
                  else
                    const _GameIcon(),
                  if (busy) const ColoredBox(color: Color(0x88000000), child: Center(child: CircularProgressIndicator())),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text(game.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}

class _GameIcon extends StatelessWidget {
  const _GameIcon();

  @override
  Widget build(BuildContext context) => const Center(child: Text('🎮', style: TextStyle(fontSize: 38)));
}

/// The old screen: games are not available yet (or not on this phone).
class _ComingSoon extends StatelessWidget {
  const _ComingSoon();

  static const _games = [
    ('Lucky Spin', '🎡', 'Spin to win coins & gifts'),
    ('Dice Duel', '🎲', 'Roll against the room'),
    ('Fishing', '🐠', 'Cast for rare catches'),
    ('Teen Patti', '🃏', 'Classic 3-card game'),
    ('Fruit Loot', '🍉', 'Match & multiply'),
    ('PK Arena', '⚔️', 'Host vs host battles'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Games')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(gradient: AppColors.brandGradient, borderRadius: BorderRadius.circular(18)),
            child: const Row(
              children: [
                Text('🎮', style: TextStyle(fontSize: 28)),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Games are coming soon — you\'ll be able to play these live '
                    'in rooms and bet coins.',
                    style: TextStyle(color: Colors.white, fontSize: 12.5, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.1,
            children: [
              for (final (name, emoji, desc) in _games)
                Opacity(
                  opacity: 0.55,
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.stroke),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(emoji, style: const TextStyle(fontSize: 34)),
                        const SizedBox(height: 8),
                        Text(name, style: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 13)),
                        const SizedBox(height: 2),
                        Text(desc, textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
                        const SizedBox(height: 6),
                        const Text('SOON',
                            style: TextStyle(fontSize: 8, fontWeight: FontWeight.w700, letterSpacing: 1, color: AppColors.gold)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
