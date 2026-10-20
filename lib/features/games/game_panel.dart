import 'package:flutter/material.dart' hide Text;

import '../../core/widgets/over_live_route.dart';
import '../../theme/app_colors.dart';
import '../../core/i18n/text.dart';

/// A game opens as a panel at the bottom of the screen, the way it does in other live apps: the live room (or the Games list)
/// stays visible, dimmed, above it. The platform's games are Cocos canvases that keep the screen's WIDTH and hang from the bottom
/// edge, so the space they need is width x (design height / design width) and anything taller is just empty. That ratio is
/// different per game (square for most; Fruit Machine 1.4; Greedy and Roulette 1.6), so the panel reads it from the page and
/// follows it, which also covers games the platform adds later.

/// The strip above the game: its name and the close button. The game's own exit button sits at its top left, so ours is on the right.
const double kGamePanelHeader = 44;

/// What the games looked like on a measuring run (1.0 = a square), as a first guess before the page answers; the page's own
/// answer replaces it a moment later.
const Map<String, double> _knownAspect = {
  'kingdoms': 1.0,
  'kingdoms2': 1.0,
  'lucky77': 1.0,
  'lucky99': 1.0,
  'fruitLoops': 1.0,
  'dragonTigerBattle': 1.0,
  'fruitMachine': 1.4,
  'greedy': 1.6,
  'roulette': 1.6,
};

/// The engine's template size (750 x 1334): every game reports it from the moment its page starts, and switches to its own size
/// once its assets have loaded (Lucky99: a square, about a minute in on a slow line). Treated as "not decided yet".
const double kEngineDefaultAspect = 1334 / 750;

/// How long that starting value is ignored after the page loaded, so a square game is not drawn as a tall panel with a big empty
/// top while it loads. A game that really is that tall is still followed, after this.
const Duration kEngineDefaultGrace = Duration(seconds: 90);

/// An unknown game starts tall: a panel that is too short cuts the game off, one that is too tall only leaves some empty space.
const double kUnknownGameAspect = kEngineDefaultAspect;
final Map<String, double> _measured = {};

bool isEngineDefaultAspect(double aspect) => (aspect - kEngineDefaultAspect).abs() < 0.01;

/// Whether a reading from the page should move the panel (see [kEngineDefaultAspect]).
bool acceptAspectReading(double aspect, Duration sincePageLoaded) =>
    !isEngineDefaultAspect(aspect) || sincePageLoaded >= kEngineDefaultGrace;

/// The height ratio to start a game's panel with: what the page itself said last time, else the table above, else tall.
double gameAspectGuess(String? identification) =>
    (identification == null ? null : _measured[identification]) ??
    (identification == null ? null : _knownAspect[identification]) ??
    kUnknownGameAspect;

void rememberGameAspect(String? identification, double aspect) {
  if (identification != null) _measured[identification] = aspect;
}

/// Reads the answer of the measuring script (`<design width>x<design height>x<policy name>`, possibly wrapped in quotes) and
/// returns height / width. Null when it is not usable: nothing yet (the engine is still starting), no sensible numbers, or a
/// game that is not scaled by width (then the panel's size is a guess and stays so).
double? parseDesignAspect(Object? raw) {
  if (raw == null) return null;
  final m = RegExp(r'(\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)x(\w*)').firstMatch(raw.toString());
  if (m == null) return null;
  final w = double.tryParse(m.group(1)!);
  final h = double.tryParse(m.group(2)!);
  if (w == null || h == null || w <= 0 || h <= 0) return null;
  if (m.group(3) != 'FixedWidth') return null;
  return (h / w).clamp(0.5, 2.5).toDouble();
}

/// The script that asks a loaded game for its design size.
const String kDesignSizeScript =
    "(function(){try{var s=cc.view.getDesignResolutionSize();var p='';"
    "try{p=cc.view.getResolutionPolicy()._contentStrategy.name}catch(e){}"
    "return s.width+'x'+s.height+'x'+p}catch(e){return ''}})()";

/// How tall the panel is: the header, the game at the screen's width x [aspect], and the system bar's inset. A game gets the
/// height its own layout asks for, up to the whole screen below the status bar (a tall game designed for a full phone screen, such as
/// 750 x 1334, must not have its top, where its table, info and buttons sit, cut off by an arbitrary cap); never so short that nothing
/// is usable. When even the whole screen is not tall enough, see [gamePanelGameWidth].
double gamePanelHeight({required Size screen, required double bottomInset, required double aspect, double topInset = 0}) {
  final wanted = kGamePanelHeader + screen.width * aspect + bottomInset;
  final room = screen.height - topInset;
  return wanted.clamp(kGamePanelHeader + 160, room < kGamePanelHeader + 160 ? kGamePanelHeader + 160 : room).toDouble();
}

/// How wide the game is drawn. These games keep the width they are given and hang from the bottom edge, so a panel shorter than
/// width x [aspect] would cut the TOP of the game off. On a short or wide screen where even [gamePanelHeight]'s whole-screen height is
/// not enough, the game is made narrower instead, centred with black sides, so its full layout stays on screen at its own proportions.
double gamePanelGameWidth({required double screenWidth, required double panelHeight, required double bottomInset, required double aspect}) {
  final room = panelHeight - kGamePanelHeader - bottomInset;
  if (aspect <= 0 || room <= 0) return screenWidth;
  final fit = room / aspect;
  return fit < screenWidth ? fit : screenWidth;
}

/// The route a game panel is shown with. It is an [OverlayRoute], not a ModalRoute, so it can leave everything above the panel
/// usable:
///  * `modal: false` (a game opened from a live room): nothing dims or blocks the room, so the room stays visible AND usable above the
///    panel (seats, chat, viewers); only the panel's own area takes touches.
///  * `modal: true` (the Games tab, Home): a light dim over what is behind, which blocks touches to it, so a second game cannot be
///    opened on top of the first.
/// It does not close on a tap outside (a stray tap should not drop someone out of a round): the close button, the game's own exit or
/// the system back button does (back reaches it through `Navigator.maybePop`, like any route above a live). It works in the root
/// navigator and in the live room's own navigator, where it keeps a live behind it running.
class GamePanelRoute<T> extends OverlayRoute<T> {
  GamePanelRoute({required this.page, this.modal = true});

  final Widget page;
  final bool modal;

  @override
  Iterable<OverlayEntry> createOverlayEntries() => [
        if (modal) OverlayEntry(builder: (_) => const ModalBarrier(color: Colors.black26, dismissible: false)),
        OverlayEntry(builder: (_) => _SlideUp(child: page)),
      ];
}

/// Slides its child up from the bottom when it first appears.
class _SlideUp extends StatefulWidget {
  const _SlideUp({required this.child});
  final Widget child;

  @override
  State<_SlideUp> createState() => _SlideUpState();
}

class _SlideUpState extends State<_SlideUp> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 260))..forward();
  late final Animation<Offset> _offset =
      Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SlideTransition(position: _offset, child: widget.child);
}

/// Shows [page] (a [GamePanelFrame]) as the game panel. From the Games list that a live room's menu opened (a sheet over the room,
/// an [OverLiveRoute]) that list is closed first, so the ROOM is what stays above the panel, and the panel does not block it.
Future<T?> showGamePanel<T>(BuildContext context, {required Widget page}) {
  final nav = Navigator.of(context);
  final here = ModalRoute.of(context);
  final fromLive = here is OverLiveRoute;
  if (fromLive) nav.removeRoute(here);
  return nav.push<T>(GamePanelRoute<T>(page: page, modal: !fromLive));
}

/// The panel itself: rounded top, a header with the game's name and a close button, and [child] (the game) filling the rest.
/// Its height follows [aspect] (animated, so a correction after the page answers is smooth). Everything above it is empty, so the
/// route's dimmed barrier shows the room through.
class GamePanelFrame extends StatelessWidget {
  const GamePanelFrame({super.key, required this.title, required this.aspect, required this.child, required this.onClose});

  final String title;
  final double aspect;
  final Widget child;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final height = gamePanelHeight(screen: mq.size, bottomInset: mq.viewPadding.bottom, aspect: aspect, topInset: mq.viewPadding.top);
    final gameWidth = gamePanelGameWidth(screenWidth: mq.size.width, panelHeight: height, bottomInset: mq.viewPadding.bottom, aspect: aspect);
    return Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: AnimatedContainer(
          key: const ValueKey('game-panel'),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: double.infinity,
          height: height,
          clipBehavior: Clip.antiAlias,
          decoration: const BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: Column(
            children: [
              Container(
                height: kGamePanelHeader,
                color: AppColors.bgElevated,
                padding: const EdgeInsets.only(left: 18, right: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 14, color: AppColors.textPrimary),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('game-panel-close'),
                      tooltip: tr('Close'),
                      icon: const Icon(Icons.close_rounded, color: AppColors.textPrimary),
                      onPressed: onClose,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(bottom: mq.viewPadding.bottom),
                  child: Center(child: SizedBox(key: const ValueKey('game-area'), width: gameWidth, height: double.infinity, child: child)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
