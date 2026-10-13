import 'package:flutter/material.dart' hide Text;

import '../../core/widgets/section_header.dart';
import '../../router/app_nav.dart';
import '../../state/games_store.dart';
import '../../state/remote_config_controller.dart';
import 'game_launcher.dart';
import 'games_screen.dart';

/// A row of the platform's games on Home. It shows nothing at all (no header, no gap) while games are switched off, on a phone
/// that is not Android, or while the list is empty, so a Home without games looks exactly as before. Tapping a game plays it
/// at once (same notice and checks as the Games tab); "See All" opens the Games tab.
class GamesStrip extends StatefulWidget {
  const GamesStrip({super.key, this.store, this.config, this.launcher, this.isAndroid, this.onSeeAll});

  final GamesStore? store;
  final RemoteConfigController? config;
  final GameLauncher? launcher;
  final bool? isAndroid;
  final void Function(BuildContext context)? onSeeAll;

  @override
  State<GamesStrip> createState() => _GamesStripState();
}

class _GamesStripState extends State<GamesStrip> {
  late final GamesStore _store = widget.store ?? GamesStore.instance;
  late final GameLauncher _launcher = widget.launcher ?? GameLauncher();
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
    if (widget.launcher == null) _launcher.dispose();
    super.dispose();
  }

  void _onConfig() {
    if (!mounted) return;
    if (_on) _store.start();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!_on) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final games = _store.games;
        if (games == null || games.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(title: 'Games', onAction: () => (widget.onSeeAll ?? AppNav.games)(context)),
              const SizedBox(height: 12),
              SizedBox(
                height: 128,
                child: ValueListenableBuilder<int?>(
                  valueListenable: _launcher.launching,
                  builder: (context, launching, _) => ListView.separated(
                    key: const ValueKey('games-strip-list'),
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: games.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, i) => SizedBox(
                      width: 112,
                      child: GameCard(
                        game: games[i],
                        busy: launching == games[i].id,
                        onTap: () => _launcher.play(context, games[i]),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
