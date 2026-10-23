import 'dart:io' show Platform;

import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../../core/utils/formatters.dart';
import '../../data/games_repository.dart';
import '../../state/games_store.dart';
import '../../state/remote_config_controller.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';
import 'game_launcher.dart';
import '../../core/i18n/text.dart';

/// Are the games on for this phone? The panel's `games_enabled` switch (default off), and Android only for now (iOS waits for store review).
bool gamesAvailable(RemoteConfigController config, {bool? isAndroid}) =>
    (isAndroid ?? Platform.isAndroid) && config.flag('games_enabled', defaultValue: false);

/// The Games tab. While games are switched off, or on a phone that is not Android, it shows the "coming soon" screen; otherwise the
/// platform's games, kept in step with the Tulasi panel by [GamesStore] (a change there shows here without a restart).
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
  late final GamesStore _store = widget.store ?? (widget.repo != null ? GamesStore(repo: widget.repo, feed: (_) => () {}) : GamesStore.instance);
  late final GameLauncher _launcher =
      GameLauncher(repo: widget.repo, openGame: widget.openGame, onRecharge: widget.onRecharge, userId: widget.userId);
  RemoteConfigController get _config => widget.config ?? RemoteConfigController.instance;

  bool get _on => gamesAvailable(_config, isAndroid: widget.isAndroid);

  @override
  void initState() {
    super.initState();
    _config.addListener(_onConfig);
    if (_on) _store.start();
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
    return RefreshIndicator(
      onRefresh: _store.refresh,
      child: GridView.count(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.95,
        children: [
          for (final g in games)
            ValueListenableBuilder<int?>(
              valueListenable: _launcher.launching,
              builder: (context, launching, _) =>
                  GameCard(game: g, busy: launching == g.id, onTap: () => _launcher.play(context, g)),
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
                    Image.network(game.imageUrl!, fit: BoxFit.cover, cacheWidth: 640, errorBuilder: (_, _, _) => const _GameIcon())
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
