import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabalive/core/widgets/over_live_route.dart';
import 'package:sabalive/data/games_repository.dart';
import 'package:sabalive/features/games/game_launcher.dart';
import 'package:sabalive/features/games/game_panel.dart';
import 'package:sabalive/features/games/game_webview_screen.dart';

void main() {
  group('what the page reports about its size', () {
    test('a width-scaled game gives height / width, quotes or not (Android wraps a string result in quotes)', () {
      expect(parseDesignAspect('750x1200xFixedWidth'), closeTo(1.6, 0.0001));
      expect(parseDesignAspect('"750x750xFixedWidth"'), closeTo(1.0, 0.0001));
      expect(parseDesignAspect('"750x1050xFixedWidth"'), closeTo(1.4, 0.0001));
    });

    test('nothing yet, nonsense, or a game that is not scaled by width gives no answer (the first guess stays)', () {
      expect(parseDesignAspect(null), isNull);
      expect(parseDesignAspect(''), isNull);
      expect(parseDesignAspect('""'), isNull);
      expect(parseDesignAspect('0x0xFixedWidth'), isNull);
      expect(parseDesignAspect('750x1200xShowAll'), isNull);
      expect(parseDesignAspect('750x1200x'), isNull);
      expect(parseDesignAspect('undefined'), isNull);
    });

    test('an absurd ratio is kept within bounds', () {
      expect(parseDesignAspect('750x75xFixedWidth'), 0.5);
      expect(parseDesignAspect('750x9000xFixedWidth'), 2.5);
    });

    test('the script asks the engine for the design size and the policy, and never throws', () {
      expect(kDesignSizeScript, contains('getDesignResolutionSize'));
      expect(kDesignSizeScript, contains('_contentStrategy.name'));
      expect('try'.allMatches(kDesignSizeScript).length, greaterThanOrEqualTo(2));
    });
  });

  group('the first guess for a game', () {
    test('the known games start at their measured size; an unknown game starts tall', () {
      expect(gameAspectGuess('kingdoms'), 1.0);
      expect(gameAspectGuess('roulette'), 1.6);
      expect(gameAspectGuess('greedy'), 1.6);
      expect(gameAspectGuess('fruitMachine'), 1.4);
      expect(gameAspectGuess('somethingNew'), kUnknownGameAspect);
      expect(gameAspectGuess(null), kUnknownGameAspect);
      expect(kUnknownGameAspect, kEngineDefaultAspect); // unknown = as tall as the engine's template, never cut off
    });

    test('what the page itself said wins next time', () {
      rememberGameAspect('somethingNew', 1.25);
      expect(gameAspectGuess('somethingNew'), 1.25);
      rememberGameAspect(null, 3); // no key: nothing remembered, nothing breaks
    });
  });

  group('the engine\'s starting size is not an answer', () {
    test('750 x 1334 is recognised, and nothing else is', () {
      expect(isEngineDefaultAspect(parseDesignAspect('750x1334xFixedWidth')!), isTrue);
      expect(isEngineDefaultAspect(1.0), isFalse);
      expect(isEngineDefaultAspect(1.6), isFalse);
    });

    test('a real size moves the panel at once; the template size only after the grace period', () {
      expect(acceptAspectReading(1.0, Duration.zero), isTrue);
      expect(acceptAspectReading(1.6, const Duration(seconds: 1)), isTrue);
      expect(acceptAspectReading(kEngineDefaultAspect, Duration.zero), isFalse);
      expect(acceptAspectReading(kEngineDefaultAspect, const Duration(seconds: 89)), isFalse);
      expect(acceptAspectReading(kEngineDefaultAspect, kEngineDefaultGrace), isTrue);
    });
  });

  group('panel height', () {
    test('header + screen width x ratio + the system bar', () {
      expect(gamePanelHeight(screen: const Size(400, 900), bottomInset: 0, aspect: 1.0), kGamePanelHeader + 400);
      expect(gamePanelHeight(screen: const Size(400, 900), bottomInset: 20, aspect: 1.6), kGamePanelHeader + 640 + 20);
    });

    test('never more than 90% of the screen (a room is always visible), never uselessly short', () {
      expect(gamePanelHeight(screen: const Size(400, 700), bottomInset: 0, aspect: 2.5), 700 * kGamePanelMaxShare);
      expect(gamePanelHeight(screen: const Size(400, 900), bottomInset: 0, aspect: 0.1), kGamePanelHeader + 160);
    });
  });

  group('the panel over a room', () {
    Future<void> open(WidgetTester t, {required double aspect, required void Function(GameExit?) onResult}) async {
      t.view.physicalSize = const Size(400, 800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      late BuildContext ctx;
      await t.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const Scaffold(body: Align(alignment: Alignment.topCenter, child: Padding(padding: EdgeInsets.only(top: 80), child: Text('THE LIVE ROOM'))));
        }),
      ));
      Navigator.of(ctx)
          .push<GameExit>(GamePanelRoute<GameExit>(
            page: Builder(
              builder: (c) => GamePanelFrame(
                title: 'Teen Patti Gold',
                aspect: aspect,
                onClose: () => Navigator.of(c).pop(GameExit.closed),
                child: const ColoredBox(color: Colors.green),
              ),
            ),
          ))
          .then(onResult);
      await t.pumpAndSettle();
    }

    testWidgets('a square game takes the bottom of the screen only; the room stays on screen above it, not covered by black', (t) async {
      await open(t, aspect: 1.0, onResult: (_) {});
      final panel = find.byKey(const ValueKey('game-panel'));
      expect(t.getSize(panel).height, kGamePanelHeader + 400); // 44 + the 400 px screen width
      expect(t.getBottomLeft(panel).dy, 800);
      expect(t.getTopLeft(panel).dy, 800 - (kGamePanelHeader + 400));
      expect(find.text('THE LIVE ROOM'), findsOneWidget); // still built and visible behind the panel
      expect(find.text('Teen Patti Gold'), findsOneWidget);
      // the room is above the panel, not under it
      expect(t.getCenter(find.text('THE LIVE ROOM')).dy, lessThan(t.getTopLeft(panel).dy));
    });

    testWidgets('a taller game gets a taller panel, and a correction animates (the page answers after the first guess)', (t) async {
      late StateSetter set;
      var aspect = 1.0;
      t.view.physicalSize = const Size(400, 800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: StatefulBuilder(builder: (c, s) {
          set = s;
          return GamePanelFrame(title: 'Roulette', aspect: aspect, onClose: () {}, child: const SizedBox());
        }),
      ));
      final panel = find.byKey(const ValueKey('game-panel'));
      expect(t.getSize(panel).height, kGamePanelHeader + 400);
      set(() => aspect = 1.6);
      await t.pump(); // the animation starts on this frame
      await t.pump(const Duration(milliseconds: 100));
      final mid = t.getSize(panel).height;
      expect(mid, greaterThan(kGamePanelHeader + 400));
      expect(mid, lessThan(kGamePanelHeader + 640));
      await t.pumpAndSettle();
      expect(t.getSize(panel).height, kGamePanelHeader + 640);
    });

    testWidgets('a tap on the room above does not close the game; the close button does, and says it was closed', (t) async {
      GameExit? result;
      var done = false;
      await open(t, aspect: 1.0, onResult: (r) {
        result = r;
        done = true;
      });
      await t.tapAt(const Offset(200, 60)); // on the room, well above the panel
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('game-panel')), findsOneWidget);
      expect(done, isFalse);

      await t.tap(find.byKey(const ValueKey('game-panel-close')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('game-panel')), findsNothing);
      expect(done, isTrue);
      expect(result, GameExit.closed);
    });
  });

  group('opened from a live room', () {
    // The room: a button near the top that counts taps. A "live" here is just the app's first route.
    Widget room({required void Function() onTap, required Widget Function(BuildContext) listPage, bool overLive = true}) {
      return MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 60),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  ElevatedButton(key: const ValueKey('room-button'), onPressed: onTap, child: const Text('ROOM BUTTON')),
                  TextButton(
                    key: const ValueKey('open-list'),
                    onPressed: () => Navigator.of(context).push(
                      overLive
                          ? OverLiveRoute<void>(Builder(builder: listPage))
                          : MaterialPageRoute<void>(builder: listPage),
                    ),
                    child: const Text('OPEN LIST'),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
    }

    Widget list(BuildContext context, {GameExit? result, void Function(Object?)? onResult}) {
      return Scaffold(
        body: Center(
          child: TextButton(
            key: const ValueKey('play'),
            onPressed: () async {
              final r = await showGamePanel<GameExit>(
                context,
                page: Builder(
                  builder: (c) => GamePanelFrame(
                    title: 'Teen Patti Gold',
                    aspect: 1.0,
                    onClose: () => Navigator.of(c).pop(result ?? GameExit.closed),
                    child: const ColoredBox(color: Colors.green),
                  ),
                ),
              );
              onResult?.call(r);
            },
            child: const Text('THE GAMES LIST'),
          ),
        ),
      );
    }

    testWidgets('the Games list is closed when a game opens, and the room above the panel stays usable', (t) async {
      t.view.physicalSize = const Size(400, 800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      var taps = 0;
      await t.pumpWidget(room(onTap: () => taps++, listPage: list));
      await t.tap(find.byKey(const ValueKey('open-list')));
      await t.pumpAndSettle();
      expect(find.text('THE GAMES LIST'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('play')));
      await t.pumpAndSettle();
      expect(find.text('THE GAMES LIST'), findsNothing); // not left behind the panel
      expect(find.byKey(const ValueKey('game-panel')), findsOneWidget);
      expect(find.byType(ModalBarrier).evaluate().where((e) => (e.widget as ModalBarrier).color == Colors.black26), isEmpty); // nothing dims or blocks the room

      await t.tap(find.byKey(const ValueKey('room-button'))); // the room above the panel still takes taps
      expect(taps, 1);
      expect(find.byKey(const ValueKey('game-panel')), findsOneWidget); // and that did not close the game
    });

    testWidgets('the system back button closes the panel and leaves the room', (t) async {
      t.view.physicalSize = const Size(400, 800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(room(onTap: () {}, listPage: list));
      await t.tap(find.byKey(const ValueKey('open-list')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('play')));
      await t.pumpAndSettle();
      final nav = t.state<NavigatorState>(find.byType(Navigator));
      expect(await nav.maybePop(), isTrue);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('game-panel')), findsNothing);
      expect(find.text('ROOM BUTTON'), findsOneWidget);
    });

    testWidgets('outside a live (a normal page) the page stays behind the panel, dimmed and not usable', (t) async {
      t.view.physicalSize = const Size(400, 800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      var behind = 0;
      await t.pumpWidget(room(
        overLive: false,
        onTap: () {},
        listPage: (c) => Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 60),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ElevatedButton(key: const ValueKey('behind'), onPressed: () => behind++, child: const Text('BEHIND')),
                TextButton(
                  key: const ValueKey('play'),
                  onPressed: () => showGamePanel<GameExit>(
                    c,
                    page: GamePanelFrame(title: 'Roulette', aspect: 1.6, onClose: () {}, child: const SizedBox()),
                  ),
                  child: const Text('PLAY'),
                ),
              ]),
            ),
          ),
        ),
      ));
      await t.tap(find.byKey(const ValueKey('open-list')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('play')));
      await t.pumpAndSettle();
      expect(find.text('BEHIND'), findsOneWidget); // still there behind the panel
      await t.tap(find.byKey(const ValueKey('behind')), warnIfMissed: false);
      expect(behind, 0); // the dim layer blocks it, so a second game cannot be opened on top of the first
    });

    testWidgets('a game that asks for the coin shop still gets it after its Games list was removed; nothing breaks', (t) async {
      SharedPreferences.setMockInitialValues({'games.notice.v1.u1': true});
      t.view.physicalSize = const Size(400, 800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      var shop = 0;
      var shopContextMounted = false;
      final launcher = GameLauncher(
        repo: _FakeGames(),
        userId: (_) => 'u1',
        onRecharge: (c) async {
          shop++;
          shopContextMounted = c.mounted;
        },
        openGame: (c, g, s) => showGamePanel<GameExit>(
          c,
          page: Builder(
            builder: (c2) => GamePanelFrame(
              title: g.name,
              aspect: 1.0,
              onClose: () => Navigator.of(c2).pop(GameExit.recharge),
              child: const SizedBox(),
            ),
          ),
        ),
      );
      await t.pumpWidget(room(
        onTap: () {},
        listPage: (c) => _ListThatOwns(launcher: launcher),
      ));
      await t.tap(find.byKey(const ValueKey('open-list')));
      await t.pumpAndSettle();
      await t.tap(find.text('PLAY ROULETTE'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('game-panel')), findsOneWidget);
      expect(find.text('PLAY ROULETTE'), findsNothing); // the list is gone

      await t.tap(find.byKey(const ValueKey('game-panel-close')));
      await t.pumpAndSettle();
      expect(shop, 1);
      expect(shopContextMounted, isTrue);
      expect(t.takeException(), isNull);
    });
  });
}

class _FakeGames extends GamesRepository {
  @override
  Future<GameSession> start(MerchantGame game) async => GameSession(token: 'T', uid: 1);
}

/// A Games list that owns its launcher and disposes it with itself, as the real Games screen does.
class _ListThatOwns extends StatefulWidget {
  const _ListThatOwns({required this.launcher});
  final GameLauncher launcher;

  @override
  State<_ListThatOwns> createState() => _ListThatOwnsState();
}

class _ListThatOwnsState extends State<_ListThatOwns> {
  @override
  void dispose() {
    widget.launcher.dispose(); // while its play() is still waiting for the game to close
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => widget.launcher.play(context, const MerchantGame(id: 2875, name: 'Roulette', identification: 'roulette')),
            child: const Text('PLAY ROULETTE'),
          ),
        ),
      );
}
