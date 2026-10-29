import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/utils/errors.dart';
import '../../data/games_repository.dart';
import '../../router/app_nav.dart';
import '../../state/active_live_session_controller.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';
import 'game_panel.dart';
import 'game_webview_screen.dart';
import 'sud_game_screen.dart';
import 'sud_launch.dart';
import '../../core/i18n/text.dart';

/// Opens a game: gets the session's token and shows the game. Returns why the game closed. Replaced in tests.
typedef OpenGame = Future<GameExit?> Function(BuildContext context, MerchantGame game, GameSession session);

/// Shows the game as a panel at the bottom of the screen (see [showGamePanel]): the live room (usable), or the Games list or Home
/// (dimmed), stays visible above it. `Navigator.of(context)` is the live room's own navigator while a live is on screen, so the live
/// keeps running behind; a plain full-screen route here would replace it.
Future<GameExit?> openGameInWebView(BuildContext context, MerchantGame game, GameSession session) {
  final sud = session.url != null; // a SUD game is described by the address our server gave, at the proportions SUD gave it; a Tulasi game builds its URL here
  if (sud) {
    // SUD's NATIVE SDK (their plugin) plays it in the panel: their web SDK is refused for our app (error 10005) and SUD says the games are for Android and iOS
    final launch = SudLaunch.fromUrl(session.url!);
    if (launch == null) throw Exception('This game is not available right now');
    return showGamePanel<GameExit>(context, page: SudGameScreen(launch: launch, title: game.name, aspect: kSudGameAspect));
  }
  return showGamePanel<GameExit>(
    context,
    page: GameWebViewScreen(
      url: session.url ?? buildGameUrl(game, session.token),
      title: game.name,
      sizeKey: game.identification,
      initialAspect: sud ? (session.aspect ?? game.aspect ?? 1.0) : null,
      measure: !sud,
      allowSubframes: sud,
    ),
  );
}

/// The live the person is in right now (not minimised), or null: SUD plays everyone in the same live at one table.
String? currentLiveRoomId(BuildContext context) {
  try {
    final live = context.read<ActiveLiveSessionController>();
    return live.isActive && !live.isMinimized ? live.roomId : null;
  } catch (_) {
    return null; // no live controller here (a plain page, or a test)
  }
}

/// What happens when someone taps a game, wherever it is shown (the Games tab, the Home strip, a live room's menu): the first-time notice,
/// a launch from the server (which checks age, ghost accounts and the games switch), the game, and, if the game asks for it, the coin shop.
class GameLauncher {
  GameLauncher({this.repo, this.openGame = openGameInWebView, this.onRecharge, this.userId});

  final GamesRepository? repo;
  final OpenGame openGame;

  /// What happens when the game asks for the coin shop (default: open it).
  final Future<void> Function(BuildContext context)? onRecharge;

  /// Who is signed in, for remembering that they accepted the notice (default: the AuthController's user).
  final String? Function(BuildContext context)? userId;

  /// The game being launched right now (a screen shows a spinner on its card), null when idle.
  final ValueNotifier<int?> launching = ValueNotifier<int?>(null);
  bool _disposed = false;

  void _setLaunching(int? id) {
    if (!_disposed) launching.value = id;
  }

  GamesRepository get _repo => repo ?? GamesRepository();

  String _noticeKey(BuildContext context, MerchantGame game) =>
      'games.notice.${game.isSud ? 'sud.' : ''}v1.${(userId ?? (c) => c.read<AuthController>().user?.id)(context) ?? 'anon'}';

  Future<bool> _noticeAccepted(BuildContext context, MerchantGame game) async {
    final key = _noticeKey(context, game);
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(key) == true) return true;
    if (!context.mounted) return false;
    final ok = await showGamesNotice(context, providerDecidesResults: !game.isSud);
    if (ok) await prefs.setBool(key, true);
    return ok;
  }

  Future<void> play(BuildContext context, MerchantGame game) async {
    if (launching.value != null || !game.launchable) return;
    // a SUD party game stakes nothing, so the "bets and coins" notice would be untrue there; every game that stakes coins gets one
    if ((!game.isSud || game.usesCoins) && (!await _noticeAccepted(context, game) || !context.mounted)) return;
    _setLaunching(game.id);
    final messenger = ScaffoldMessenger.maybeOf(context);
    // From a live room's Games list the list is closed when the game opens (the room stays above the panel), so this screen's own
    // context is gone by the time the game closes. The navigator's overlay is not: it is what a coin shop is opened from then.
    final overlayContext = Navigator.maybeOf(context)?.overlay?.context;
    try {
      final session = await _repo.start(
        game,
        roomId: game.isSud ? currentLiveRoomId(context) : null,
        lang: Localizations.maybeLocaleOf(context)?.languageCode ?? 'en',
      );
      // the launch went through: count it (for "Most played"); it never delays or fails the game
      unawaited(_repo.recordPlay(game));
      if (!context.mounted) return;
      final why = await openGame(context, game, session);
      if (why == GameExit.recharge) {
        final ctx = context.mounted ? context : overlayContext;
        if (ctx != null && ctx.mounted) await (onRecharge ?? AppNav.buyCoins)(ctx);
      }
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      _setLaunching(null);
    }
  }

  void dispose() {
    _disposed = true;
    launching.dispose();
  }
}

/// What is said before someone plays for the first time. It states plainly who runs the games, what is staked, that the
/// provider's system decides the results (and may adjust them), and the age limit; the server separately refuses anyone
/// under 18. Returns true when the person accepted.
Future<bool> showGamesNotice(BuildContext context, {bool providerDecidesResults = true}) async {
  var agreed = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => StatefulBuilder(
      builder: (d, set) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('Before you play'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('These games are provided by a third-party game provider.'),
              const SizedBox(height: 8),
              const Text('Bets are paid with your SABALIVE coins, and winnings are paid back in coins.'),
              const SizedBox(height: 8),
              // Tulasi's own guide says its system adjusts outcomes; that sentence is about THEIR games and is not removed. A SUD coin game is played against
              // other players, so the sentence is left out there (nothing is said about SUD's results either way).
              if (providerDecidesResults) ...[
                const Text(
                  "Results are decided by the game provider's system, which may adjust outcomes. They are not guaranteed to be purely random.",
                ),
                const SizedBox(height: 8),
              ],
              const Text('Games are for people aged 18 or over. Only play with what you can afford to lose.'),
              const SizedBox(height: 8),
              CheckboxListTile(
                key: const ValueKey('games-notice-check'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: agreed,
                onChanged: (v) => set(() => agreed = v ?? false),
                title: const Text('I am 18 or over and I understand'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('games-notice-continue'),
            onPressed: agreed ? () => Navigator.pop(d, true) : null,
            child: const Text('Continue'),
          ),
        ],
      ),
    ),
  );
  return ok == true;
}
