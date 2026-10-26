import 'package:flutter/material.dart' hide Text;

import '../../core/widgets/over_live_route.dart';
import '../../core/i18n/text.dart';

/// A game opens as a panel at the bottom of the screen, the way it does in other live apps: the live room (or the Games list)
/// stays visible, dimmed, above it. The platform's games are Cocos canvases that keep the screen's WIDTH and hang from the bottom
/// edge, so the space they need is width x (design height / design width) and anything taller is just empty. That ratio is
/// different per game (square for most; Fruit Machine 1.4; Greedy and Roulette 1.6), so the panel reads it from the page and
/// follows it, which also covers games the platform adds later.
///
/// Nothing of ours limits the game: no header strip over it, no rounded corners cutting its edges, no clamp on its proportions, and it
/// always gets the full screen width and the height its own layout asks for. The close button sits just ABOVE the panel, outside the game
/// (owner, 2026-10-26: it used to float over the game's top right, on top of the game's own controls), in the room that shows through above it.
/// The one exception to "the height its own layout asks for" is a game that cannot fit in the screen below that button and the status bar
/// (a rotated phone, an old short phone): it is then narrowed, not cropped.

/// A panel is never shorter than this (only a nonsense reading could ask for less).
const double kGamePanelMinHeight = 96;

/// The close button's size, and its distance from the panel's top edge and from the screen's right edge. The button's row above the panel is
/// [kGameCloseRow] tall.
const double kGameCloseSize = 34;
const double kGameCloseMargin = 6;
const double kGameCloseRow = kGameCloseSize + 2 * kGameCloseMargin;

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

/// The proportions (height / width) a reading may have to be believed. A real game is between a wide slot machine and a tall phone screen; a reading outside this is
/// the engine still starting up or a page that is not a game, and is ignored (the panel keeps its size) instead of being squeezed into a range.
const double kMinGameAspect = 0.25;
const double kMaxGameAspect = 4.0;

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
  final aspect = h / w;
  return aspect < kMinGameAspect || aspect > kMaxGameAspect ? null : aspect;
}

/// The script that asks a loaded game for its design size.
const String kDesignSizeScript =
    "(function(){try{var s=cc.view.getDesignResolutionSize();var p='';"
    "try{p=cc.view.getResolutionPolicy()._contentStrategy.name}catch(e){}"
    "return s.width+'x'+s.height+'x'+p}catch(e){return ''}})()";

/// How tall the panel is: the game at the screen's width x [aspect], plus the system bar's inset. A game gets exactly the height its own layout asks for, with no
/// header above it. The panel is never taller than what is left of the screen under the status bar ([topInset]) and the close button's row above it ([kGameCloseRow]),
/// and never so short that it is a sliver. A tall game designed for a full phone screen (750 x 1334) fits on a normal phone; when it does not (see
/// [gamePanelGameWidth]) the game is narrowed instead of cropped.
double gamePanelHeight({required Size screen, required double bottomInset, required double aspect, double topInset = 0}) {
  final wanted = screen.width * aspect + bottomInset;
  final room = screen.height - topInset - kGameCloseRow;
  return wanted.clamp(kGamePanelMinHeight, room < kGamePanelMinHeight ? kGamePanelMinHeight : room).toDouble();
}

/// How wide the game is drawn: the full screen width. These games keep the width they are given and hang from the bottom edge, so a panel shorter than width x [aspect]
/// would cut the TOP of the game off. That happens only when the game cannot fit even on the whole screen (a phone turned sideways, say); then, and only then, the game
/// is made narrower, centred with black sides, so its full layout stays on screen at its own proportions.
double gamePanelGameWidth({required double screenWidth, required double panelHeight, required double bottomInset, required double aspect}) {
  final room = panelHeight - bottomInset;
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

/// The panel itself: the game ([child]) filling it edge to edge, with the close button in a row just above it, outside the game (the game's own exit button sits at its top
/// left, and its own controls may be anywhere inside it). Its height follows [aspect] (animated, so a correction after the page answers is smooth). Everything above the
/// panel is empty except that button, so the route's dimmed barrier shows the room through.
class GamePanelFrame extends StatelessWidget {
  const GamePanelFrame({super.key, required this.title, required this.aspect, required this.child, required this.onClose});

  /// The game's name: what the close button says to a screen reader.
  final String title;
  final double aspect;
  final Widget child;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final height = gamePanelHeight(screen: mq.size, bottomInset: mq.viewPadding.bottom, topInset: mq.viewPadding.top, aspect: aspect);
    final gameWidth = gamePanelGameWidth(screenWidth: mq.size.width, panelHeight: height, bottomInset: mq.viewPadding.bottom, aspect: aspect);
    return Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              key: const ValueKey('game-close-row'),
              height: kGameCloseRow,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Semantics(
                    label: '${tr('Close')} $title',
                    button: true,
                    child: SizedBox(
                      width: kGameCloseSize,
                      height: kGameCloseSize,
                      child: IconButton(
                        key: const ValueKey('game-panel-close'),
                        tooltip: tr('Close'),
                        padding: EdgeInsets.zero,
                        // over the dimmed room, whatever colour that is: a dark disc with a light rim
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black.withValues(alpha: 0.6),
                          shape: CircleBorder(side: BorderSide(color: Colors.white.withValues(alpha: 0.75), width: 1.2)),
                        ),
                        icon: const Icon(Icons.close_rounded, color: Colors.white, size: 20),
                        onPressed: onClose,
                      ),
                    ),
                  ),
                  const SizedBox(width: kGameCloseMargin + 4),
                ],
              ),
            ),
            AnimatedContainer(
              key: const ValueKey('game-panel'),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: double.infinity,
              height: height,
              color: Colors.black,
              child: Padding(
                padding: EdgeInsets.only(bottom: mq.viewPadding.bottom),
                child: Center(child: SizedBox(key: const ValueKey('game-area'), width: gameWidth, height: double.infinity, child: child)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
