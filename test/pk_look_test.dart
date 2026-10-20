import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svga/flutter_svga.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/widgets/remote_media.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/pk_battle_widgets.dart';
import 'package:sabalive/features/live/widgets/pk_score_bar.dart';
import 'package:sabalive/features/live/widgets/pk_svga.dart';
import 'package:sabalive/features/live/widgets/pk_tug_bar.dart';
import 'package:sabalive/state/pk_battle_controller.dart';
import 'package:sabalive/state/pk_theme_store.dart';
import 'package:sabalive/theme/app_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/pk_fakes.dart';

/// The PK look the panel controls: the theme model and store, the animation widget's fallback rules, the score bar, and the moments of a
/// battle that play an animation (setup, invite, 3-2-1, the bell, the result). The animation files are never loaded here (a loader that
/// does not finish, or fails, stands in): what is tested is WHEN and WHERE each one plays and what shows instead.
void main() {
  late SvgaLoader savedLoader;

  setUp(() {
    savedLoader = PkSvga.loader;
    PkThemeStore.instance.use(const PkTheme());
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    PkSvga.loader = savedLoader;
    PkThemeStore.instance.use(const PkTheme());
  });

  /// A loader whose file never arrives: the animation is "still loading".
  void loadingForever() => PkSvga.loader = (_) => Completer<MovieEntity>().future;

  /// A loader whose file is broken.
  void broken() => PkSvga.loader = (_) async => throw Exception('not a file');

  // ------------------------------------------------------------------------------------------------------------ the theme
  group('PkTheme', () {
    test('the default IS the look the app had before the panel could change it', () {
      const t = PkTheme();
      expect(t.mine, const Color(0xFFFF2D55));
      expect(t.theirs, const Color(0xFF2D6BFF));
      expect(t.accent, AppColors.gold);
      expect(t.animations, isTrue);
      expect(t.heroIntro, isFalse, reason: 'the big full-screen intro is opt-in');
      expect(t.loseStyle, PkLoseStyle.shield);
      expect(t.halfColors(PkTeam.mine), const [Color(0xFFB1122B), Color(0xFF3A0A16)]);
      expect(t.halfColors(PkTeam.theirs), const [Color(0xFF11489B), Color(0xFF0A1B3A)]);
      expect(t.barColors(PkTeam.mine), const [Color(0xFFFF2D55), Color(0xFFFF7A9C)]);
      expect(t.barColors(PkTeam.theirs), const [Color(0xFF9CC6FF), Color(0xFF2D6BFF)]);
      expect(identical(t.accentGradient, AppColors.goldGradient), isTrue);
      expect(t.hueShift(PkTeam.mine), 0, reason: 'the animations are shown as they are');
      expect(t.hueShift(PkTeam.theirs), 0);
    });

    test('a saved look is read; anything that cannot be read keeps the default', () {
      final t = PkTheme.fromJson({
        'mine': '#00ff00',
        'theirs': '#2D6BFF',
        'accent': '#abcdef',
        'animations': false,
        'hero_intro': true,
        'lose_style': 'emoji',
      });
      expect(t.mine, const Color(0xFF00FF00));
      expect(t.theirs, const Color(0xFF2D6BFF));
      expect(t.accent, const Color(0xFFABCDEF));
      expect(t.animations, isFalse);
      expect(t.heroIntro, isTrue);
      expect(t.loseStyle, PkLoseStyle.emoji);

      expect(PkTheme.fromJson({'mine': 'red', 'theirs': 5, 'accent': '#12', 'animations': 'yes', 'hero_intro': 1, 'lose_style': 'sad'}), const PkTheme());
      expect(PkTheme.fromJson({'mine': '#zzzzzz'}), const PkTheme());
      expect(PkTheme.fromJson(null), const PkTheme());
      expect(PkTheme.fromJson('x'), const PkTheme());
      expect(PkTheme.fromJson([1]), const PkTheme());
      expect(PkTheme.fromJson({'mine': '#00ff00'}).theirs, PkTheme.defaultTheirs, reason: 'a partial value keeps the rest');
    });

    test('it survives a round trip through the JSON the panel stores', () {
      const t = PkTheme(
        mine: Color(0xFF123456),
        theirs: Color(0xFFABCDEF),
        accent: Color(0xFF010203),
        bgTop: Color(0xFF111111),
        bgBottom: Color(0xFF222222),
        animations: false,
        heroIntro: true,
        loseStyle: PkLoseStyle.emoji,
      );
      expect(PkTheme.fromJson(t.toJson()), t);
      expect(t.toJson()['mine'], '#123456');
      expect(t.toJson()['bg_top'], '#111111');
      expect(t.toJson()['bg_bottom'], '#222222');
    });

    test('the video stage has a gradient behind it, violet into navy by default, and the panel can change both ends', () {
      const t = PkTheme();
      expect(t.bgTop, const Color(0xFF33104F));
      expect(t.bgBottom, const Color(0xFF0B1636));
      expect(t.backdrop.colors, [t.bgTop, t.bgBottom]);
      expect(t.backdrop.begin, Alignment.topCenter);
      expect(t.backdrop.end, Alignment.bottomCenter);
      final custom = PkTheme.fromJson({'bg_top': '#112233', 'bg_bottom': '#445566'});
      expect(custom.bgTop, const Color(0xFF112233));
      expect(custom.bgBottom, const Color(0xFF445566));
      expect(PkTheme.fromJson({'bg_top': 'blue', 'bg_bottom': 7}).bgTop, PkTheme.defaultBgTop, reason: 'unreadable = the default');
      expect(PkTheme.fromJson({'bg_top': 'blue', 'bg_bottom': 7}).bgBottom, PkTheme.defaultBgBottom);
      expect(PkTheme.fromJson({'mine': '#00ff00'}).bgTop, PkTheme.defaultBgTop, reason: 'a saved look from before the backdrop existed keeps the default');
    });

    test('a chosen colour has halves, bars and an accent of its own; the built-in ones are untouched', () {
      const t = PkTheme(mine: Color(0xFF00C853), accent: Color(0xFFAA00FF));
      final half = t.halfColors(PkTeam.mine);
      expect(half, isNot(const PkTheme().halfColors(PkTeam.mine)));
      expect(HSLColor.fromColor(half[0]).lightness, greaterThan(HSLColor.fromColor(half[1]).lightness), reason: 'light at the top, dark below');
      expect(HSVColor.fromColor(half[0]).hue, closeTo(HSVColor.fromColor(t.mine).hue, 6));
      expect(t.halfColors(PkTeam.theirs), const [Color(0xFF11489B), Color(0xFF0A1B3A)]);
      expect(t.barColors(PkTeam.mine).first, t.mine);
      expect(identical(t.accentGradient, AppColors.goldGradient), isFalse);
    });

    test('the animation art is turned to the chosen colour, the short way round and close to it', () {
      List<double> apply(List<double> m, Color c) => [
        for (var row = 0; row < 3; row++) (m[row * 5] * c.r + m[row * 5 + 1] * c.g + m[row * 5 + 2] * c.b).clamp(0.0, 1.0),
      ];
      double hue(List<double> rgb) => HSVColor.fromColor(Color.from(alpha: 1, red: rgb[0], green: rgb[1], blue: rgb[2])).hue;
      double gap(double a, double b) => ((a - b + 540) % 360 - 180).abs();

      for (final (team, target) in [
        (PkTeam.mine, const Color(0xFF00C853)),
        (PkTeam.mine, const Color(0xFF9C27B0)),
        (PkTeam.mine, const Color(0xFF2D6BFF)),
        (PkTeam.theirs, const Color(0xFFFF2D55)),
        (PkTeam.theirs, const Color(0xFF00C853)),
        (PkTeam.theirs, const Color(0xFFFF9800)),
      ]) {
        final theme = team == PkTeam.mine ? PkTheme(mine: target) : PkTheme(theirs: target);
        final shift = theme.hueShift(team);
        expect(shift.abs(), lessThanOrEqualTo(180));
        final art = HSVColor.fromAHSV(1, team == PkTeam.mine ? PkTheme.mineArtHue : PkTheme.theirsArtHue, 0.85, 0.9).toColor();
        final got = hue(apply(pkHueMatrix(shift), art));
        expect(gap(got, HSVColor.fromColor(target).hue), lessThan(25), reason: '$team -> $target gave hue $got');
      }
    });

    test('no turn at all leaves a colour alone', () {
      final m = pkHueMatrix(0);
      const c = Color(0xFFE6325A);
      expect(m[0] * c.r + m[1] * c.g + m[2] * c.b, closeTo(c.r, 0.001));
      expect(m[5] * c.r + m[6] * c.g + m[7] * c.b, closeTo(c.g, 0.001));
      expect(m[10] * c.r + m[11] * c.g + m[12] * c.b, closeTo(c.b, 0.001));
    });
  });

  // ------------------------------------------------------------------------------------------------------------- the store
  group('PkThemeStore', () {
    test('it tells listeners only when the look really changed', () {
      final store = PkThemeStore(fetch: () async => null);
      var told = 0;
      store.addListener(() => told++);
      expect(store.use(const PkTheme()), isFalse);
      expect(store.use(const PkTheme(animations: false)), isTrue);
      expect(store.use(const PkTheme(animations: false)), isFalse);
      expect(told, 1);
    });

    test('refresh applies what the panel saved, goes back to the built-in look when it is cleared, and keeps the look when it fails', () async {
      Object? server = {'mine': '#00ff00', 'animations': false};
      var fail = false;
      final store = PkThemeStore(fetch: () async => fail ? throw Exception('offline') : server);

      await store.refresh();
      expect(store.theme.mine, const Color(0xFF00FF00));
      expect(store.theme.animations, isFalse);

      fail = true;
      await store.refresh();
      expect(store.theme.mine, const Color(0xFF00FF00), reason: 'a failed read never changes the look');

      fail = false;
      server = null;
      await store.refresh();
      expect(store.theme, const PkTheme(), reason: 'nothing saved = the built-in look');
    });

    test('the look is kept on the phone and applied before the first frame of the next run', () async {
      final a = PkThemeStore(fetch: () async => {'theirs': '#ff0000', 'lose_style': 'emoji'});
      await a.refresh();
      await Future<void>.delayed(Duration.zero); // the write is not awaited by refresh
      final b = PkThemeStore(fetch: () async => throw Exception('no network yet'));
      await b.restore();
      expect(b.theme.theirs, const Color(0xFFFF0000));
      expect(b.theme.loseStyle, PkLoseStyle.emoji);
    });

    test('a damaged saved look is ignored', () async {
      SharedPreferences.setMockInitialValues({'pk.theme.v1': '{not json'});
      final store = PkThemeStore(fetch: () async => null);
      await store.restore();
      expect(store.theme, const PkTheme());
    });
  });

  // ------------------------------------------------------------------------------------------------------------ PkSvga
  group('PkSvga', () {
    Future<void> mount(WidgetTester t, Widget w) => t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 100, height: 100, child: w)))));

    testWidgets('animations off: the plain visual shows at once, nothing is loaded, a one-shot is finished', (t) async {
      PkSvga.loader = (_) => fail('the file must not be read');
      PkThemeStore.instance.use(const PkTheme(animations: false));
      var done = 0;
      await mount(t, PkSvga(PkAsset.win, fallback: const Text('plain'), onFinished: () => done++));
      await t.pump();
      expect(find.text('plain'), findsOneWidget);
      expect(done, greaterThan(0));
    });

    testWidgets('while the file loads nothing shows (the plain visual would flash first); when it fails the plain visual takes over', (t) async {
      loadingForever();
      await mount(t, const PkSvga(PkAsset.win, fallback: Text('plain')));
      await t.pump();
      expect(find.text('plain'), findsNothing);

      broken();
      var done = 0;
      await mount(t, PkSvga(PkAsset.lose, fallback: const Text('plain'), onFinished: () => done++));
      await t.pump();
      await t.pump();
      expect(find.text('plain'), findsOneWidget);
      expect(done, 1, reason: 'a one-shot that cannot play reports done, so nothing waits on it');
    });

    testWidgets('switching the animations off in the panel takes effect on a screen that is already showing', (t) async {
      loadingForever();
      await mount(t, const PkSvga(PkAsset.win, fallback: Text('plain')));
      await t.pump();
      expect(find.text('plain'), findsNothing);
      PkThemeStore.instance.use(const PkTheme(animations: false));
      await t.pump();
      expect(find.text('plain'), findsOneWidget);
    });

    testWidgets('a side with its own colour has its hue turned; the built-in colour is shown as it is, with no filter at all', (t) async {
      loadingForever();
      await mount(t, PkSvga(PkAsset.sword(PkTeam.mine), team: PkTeam.mine));
      expect(find.byType(ColorFiltered), findsNothing);
      PkThemeStore.instance.use(const PkTheme(mine: Color(0xFF00C853)));
      await t.pump();
      expect(find.byType(ColorFiltered), findsOneWidget);
      PkThemeStore.instance.use(const PkTheme(mine: Color(0xFFFF0C00))); // within a few degrees of the art's own hue: not worth a filter
      await t.pump();
      expect(find.byType(ColorFiltered), findsNothing);
    });
  });

  // ------------------------------------------------------------------------------------------------------------- the bar
  group('PkTugBar', () {
    Future<void> mountBar(WidgetTester t, int a, int b, {TextDirection dir = TextDirection.ltr}) => t.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: dir,
          child: Scaffold(body: Center(child: SizedBox(width: 360, child: PkTugBar(scoreA: a, scoreB: b)))),
        ),
      ),
    );

    /// Where the meeting point is, as a share of the bar from its left edge.
    double meeting(WidgetTester t) {
      final bar = t.getRect(find.byKey(const ValueKey('pk-tug')));
      return (t.getCenter(find.byKey(const ValueKey('pk-tug-badge'))).dx - bar.left) / bar.width;
    }

    testWidgets('the meeting point follows the scores; equal scores (and none yet) put it in the middle', (t) async {
      PkThemeStore.instance.use(const PkTheme(animations: false));
      await mountBar(t, 0, 0);
      expect(meeting(t), closeTo(0.5, 0.01));
      await mountBar(t, 9, 1);
      await t.pumpAndSettle(); // the bar slides to a new share
      expect(meeting(t), closeTo(0.9, 0.02));
      await mountBar(t, 1, 9);
      await t.pumpAndSettle();
      expect(meeting(t), closeTo(0.1, 0.02));
      await mountBar(t, 4, 4);
      await t.pumpAndSettle();
      expect(meeting(t), closeTo(0.5, 0.01));
    });

    testWidgets('right to left: my side starts at the right, so the meeting point mirrors', (t) async {
      PkThemeStore.instance.use(const PkTheme(animations: false));
      await mountBar(t, 9, 1, dir: TextDirection.rtl);
      expect(meeting(t), closeTo(0.1, 0.02));
    });

    testWidgets('a gift slides the bar to its new share instead of jumping', (t) async {
      PkThemeStore.instance.use(const PkTheme(animations: false));
      await mountBar(t, 5, 5);
      await t.pumpAndSettle();
      await mountBar(t, 9, 1);
      await t.pump(const Duration(milliseconds: 100));
      final mid = meeting(t);
      expect(mid, greaterThan(0.5));
      expect(mid, lessThan(0.9));
      await t.pumpAndSettle();
      expect(meeting(t), closeTo(0.9, 0.02));
    });

    testWidgets('with the animations on, both bars, the shield and both swords are there (loading)', (t) async {
      loadingForever();
      await mountBar(t, 7, 3);
      expect(find.byType(PkSvga), findsNWidgets(5), reason: 'my bar, their bar, the shield and a sword at each end');
    });

    testWidgets('the score bar and the thin bar of the video stage are the same bar', (t) async {
      PkThemeStore.instance.use(const PkTheme(animations: false));
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: Column(children: [PkScoreBar(scoreA: 3, scoreB: 1, secondsLeft: 60), PkThinBar(scoreA: 3, scoreB: 1)]))));
      expect(find.byType(PkTugBar), findsNWidgets(2));
    });
  });

  // ---------------------------------------------------------------------------------------------- the video stage
  group('the video PK stage: the VS between the frames and the gradient behind', () {
    late DateTime now;
    late PkFakeApi api;
    late PkBattleController c;
    final me = AppUser(id: pkMe, name: 'Me Host', username: '@me');
    var taps = 0;

    Future<void> mountStage(WidgetTester t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      now = DateTime.utc(2026, 10, 20, 12);
      api = PkFakeApi(() => now);
      c = PkBattleController(api: api, streamId: pkMyStream, myHostId: pkMe, clock: () => now);
      c.start();
      await t.pump(); // the controller subscribes first: a row emitted before that is lost
      api.emit(pkRow(status: 'live', scoreA: 5, scoreB: 9, startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
      await t.pump();
      taps = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => PkVideoBackdrop(
              child: Padding(
                padding: pkVideoStagePadding(context),
                child: PkVideoStage(
                  controller: c,
                  me: me,
                  left: const ColoredBox(color: Colors.red),
                  right: const ColoredBox(color: Colors.blue),
                  onTapTheirs: () => taps++,
                ),
              ),
            ),
          ),
        ),
      ));
      await t.pump();
    }

    Future<void> unmount(WidgetTester t) async {
      await t.pumpWidget(const SizedBox());
      c.dispose();
    }

    testWidgets('the VS sits on the gap between the two frames, level with their middle, and never takes a tap', (t) async {
      loadingForever();
      await mountStage(t);
      final left = t.getRect(find.byKey(const ValueKey('pk-pane-left')));
      final right = t.getRect(find.byKey(const ValueKey('pk-pane-right')));
      final vs = t.getRect(find.byKey(const ValueKey('pk-vs')));
      expect((vs.center.dx - (left.right + right.left) / 2).abs(), lessThan(1.5), reason: 'centred on the gap');
      expect((vs.center.dy - left.center.dy).abs(), lessThan(1.5), reason: 'at the height of the frames\' middle');
      expect(vs.width, 160, reason: 'the animation is laid out 160 wide: its letters come to about 60');
      expect(find.ancestor(of: find.byKey(const ValueKey('pk-vs')), matching: find.byType(IgnorePointer)), findsWidgets);
      // a tap right next to the middle goes through to the frame under it
      await t.tapAt(vs.center + const Offset(24, 0));
      expect(taps, 1, reason: 'the VS does not catch the viewer\'s tap on the other host\'s frame');
      await unmount(t);
    });

    testWidgets('with the animations off the VS is a small gold pill with the letters', (t) async {
      PkThemeStore.instance.use(const PkTheme(animations: false));
      await mountStage(t);
      final vs = find.byKey(const ValueKey('pk-vs'));
      expect(vs, findsOneWidget);
      expect(find.descendant(of: vs, matching: find.text('VS')), findsOneWidget);
      final left = t.getRect(find.byKey(const ValueKey('pk-pane-left')));
      final right = t.getRect(find.byKey(const ValueKey('pk-pane-right')));
      expect((t.getCenter(vs).dx - (left.right + right.left) / 2).abs(), lessThan(1.5));
      expect(t.getSize(vs).width, lessThan(70), reason: 'small');
      await unmount(t);
    });

    testWidgets('if the VS file cannot be played the pill takes its place', (t) async {
      broken();
      await mountStage(t);
      await t.pump();
      await t.pump();
      expect(find.text('VS'), findsWidgets);
      await unmount(t);
    });

    testWidgets('the space around the frames is the panel\'s gradient, not black, and follows a change at once', (t) async {
      loadingForever();
      await mountStage(t);
      BoxDecoration decoration() => t.widget<DecoratedBox>(find.byKey(const ValueKey('pk-backdrop'))).decoration as BoxDecoration;
      expect((decoration().gradient! as LinearGradient).colors, [PkTheme.defaultBgTop, PkTheme.defaultBgBottom]);
      expect(t.getSize(find.byKey(const ValueKey('pk-backdrop'))), const Size(390, 844), reason: 'it fills the whole screen');
      PkThemeStore.instance.use(const PkTheme(bgTop: Color(0xFF004400), bgBottom: Color(0xFF440000)));
      await t.pump();
      expect((decoration().gradient! as LinearGradient).colors, [const Color(0xFF004400), const Color(0xFF440000)]);
      await unmount(t);
    });
  });

  // ---------------------------------------------------------------------------------------------- the moments of a battle
  group('animations in the moments of a battle', () {
    late DateTime now;
    late PkFakeApi api;
    late PkBattleController c;
    final me = AppUser(id: pkMe, name: 'Me Host', username: '@me');

    Future<void> unmount(WidgetTester t) async {
      await t.pumpWidget(const SizedBox());
      c.dispose();
    }

    Future<void> mount(WidgetTester t) async {
      now = DateTime.utc(2026, 10, 20, 12);
      api = PkFakeApi(() => now);
      c = PkBattleController(api: api, streamId: pkMyStream, myHostId: pkMe, clock: () => now);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(child: PkBattleEvents(controller: c)),
              Align(alignment: Alignment.topCenter, child: PkBattleHeader(controller: c, me: me)),
            ],
          ),
        ),
      ));
      c.start();
      await t.pump();
    }

    testWidgets('looking for an opponent plays the matching animation above the strip; with the animations off it is just the strip', (t) async {
      loadingForever();
      await mount(t);
      c.searchRandom();
      await t.pump();
      expect(find.byKey(const ValueKey('pk-matching')), findsOneWidget);
      expect(find.byKey(const ValueKey('pk-status')), findsOneWidget);
      await unmount(t);

      PkThemeStore.instance.use(const PkTheme(animations: false));
      await mount(t);
      c.searchRandom();
      await t.pump();
      expect(find.byKey(const ValueKey('pk-matching')), findsNothing);
      expect(find.byKey(const ValueKey('pk-status')), findsOneWidget);
      await unmount(t);
    });

    testWidgets('the countdown dims the room and plays the gloves and the 3-2-1; the plain number only shows if the animation fails', (t) async {
      loadingForever();
      await mount(t);
      api.emit(pkRow(status: 'accepted', seconds: 600));
      await t.pump();
      expect(find.byKey(const ValueKey('pk-dim')), findsOneWidget);
      expect(find.byKey(const ValueKey('pk-count')), findsOneWidget);
      expect(find.byKey(const ValueKey('pk-countdown')), findsNothing, reason: 'not flashed while the animation loads');
      expect(find.byKey(const ValueKey('pk-hero')), findsNothing, reason: 'the big intro is opt-in');
      await unmount(t);

      broken();
      await mount(t);
      api.emit(pkRow(status: 'accepted', seconds: 600));
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('pk-countdown')), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      await unmount(t);
    });

    testWidgets('the bell: the "VS" burst opens a battle whose countdown just ended, and nobody else', (t) async {
      loadingForever();
      await mount(t);
      api.emit(pkRow(status: 'accepted', seconds: 600));
      await t.pump();
      api.emit(pkRow(status: 'live', seconds: 600, startedAt: now, endsAt: now.add(const Duration(seconds: 600))));
      await t.pump();
      expect(find.byKey(const ValueKey('pk-burst')), findsOneWidget);
      expect(find.byKey(const ValueKey('pk-count')), findsNothing, reason: 'the countdown art goes at the bell, the burst takes its place');
      await unmount(t);

      // someone who joins a battle that is already under way sees no burst
      await mount(t);
      api.emit(pkRow(status: 'live', seconds: 600, startedAt: now, endsAt: now.add(const Duration(seconds: 600))));
      await t.pump();
      expect(find.byKey(const ValueKey('pk-burst')), findsNothing);
      await unmount(t);
    });

    testWidgets('with the big intro on it plays behind the countdown and the burst steps aside; off by default', (t) async {
      loadingForever();
      PkThemeStore.instance.use(const PkTheme(heroIntro: true));
      await mount(t);
      api.emit(pkRow(status: 'accepted', seconds: 600));
      await t.pump();
      expect(find.byKey(const ValueKey('pk-hero')), findsOneWidget);
      api.emit(pkRow(status: 'live', seconds: 600, startedAt: now, endsAt: now.add(const Duration(seconds: 600))));
      await t.pump();
      expect(find.byKey(const ValueKey('pk-burst')), findsNothing, reason: 'the intro has its own finish');
      await unmount(t);
    });

    testWidgets('with the animations off none of it plays: the old plain countdown number, nothing else', (t) async {
      PkThemeStore.instance.use(const PkTheme(animations: false, heroIntro: true));
      await mount(t);
      api.emit(pkRow(status: 'accepted', seconds: 600));
      await t.pump();
      expect(find.byKey(const ValueKey('pk-countdown')), findsOneWidget);
      expect(find.byKey(const ValueKey('pk-dim')), findsNothing);
      expect(find.byKey(const ValueKey('pk-hero')), findsNothing);
      api.emit(pkRow(status: 'live', seconds: 600, startedAt: now, endsAt: now.add(const Duration(seconds: 600))));
      await t.pump();
      expect(find.byKey(const ValueKey('pk-burst')), findsNothing);
      await unmount(t);
    });

    testWidgets('an invite to me shows the crossed swords on its card', (t) async {
      loadingForever();
      await mount(t);
      api.emit(pkRow(status: 'invited', iAmA: false));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('pk-invite-art')), findsOneWidget);
      expect(find.text('PK invite'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('pk-decline')));
      await t.pumpAndSettle();
      await unmount(t);
    });

    Future<void> finishWith(WidgetTester t, {required int a, required int b, required String winner}) async {
      api.emit(pkRow(status: 'live', startedAt: now, endsAt: now.add(const Duration(seconds: 300))));
      await t.pump();
      api.emit(pkRow(status: 'finished', scoreA: a, scoreB: b, winner: winner));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
    }

    double? artRatio(WidgetTester t) {
      final art = find.byKey(const ValueKey('pk-result-art'));
      if (art.evaluate().isEmpty) return null;
      return t.widget<AspectRatio>(find.descendant(of: art, matching: find.byType(AspectRatio))).aspectRatio;
    }

    testWidgets('the result card carries the WIN / LOSE / DRAW badge, and the win needs no separate confetti', (t) async {
      loadingForever();
      for (final (a, b, winner, title) in [(9, 1, 'a', 'You won!'), (1, 9, 'b', 'You lost'), (5, 5, 'draw', "It's a draw")]) {
        await mount(t);
        await finishWith(t, a: a, b: b, winner: winner);
        expect(find.text(title), findsOneWidget);
        expect(artRatio(t), closeTo(360 / 450, 0.001), reason: title);
        expect(find.byKey(const ValueKey('pk-confetti')), findsNothing);
        await t.tap(find.byKey(const ValueKey('pk-result-ok')));
        await t.pumpAndSettle();
        await unmount(t);
      }
    });

    testWidgets("the panel's lose style: the crying face for a loss only", (t) async {
      loadingForever();
      PkThemeStore.instance.use(const PkTheme(loseStyle: PkLoseStyle.emoji));
      await mount(t);
      await finishWith(t, a: 1, b: 9, winner: 'b');
      expect(artRatio(t), 1.0, reason: 'the emoji ribbon is square');
      await t.tap(find.byKey(const ValueKey('pk-result-ok')));
      await t.pumpAndSettle();
      await unmount(t);

      await mount(t);
      await finishWith(t, a: 9, b: 1, winner: 'a');
      expect(artRatio(t), closeTo(360 / 450, 0.001), reason: 'a win still gets the WIN badge');
      await t.tap(find.byKey(const ValueKey('pk-result-ok')));
      await t.pumpAndSettle();
      await unmount(t);
    });

    testWidgets('with the animations off the result is text, and a win still throws confetti', (t) async {
      PkThemeStore.instance.use(const PkTheme(animations: false));
      await mount(t);
      await finishWith(t, a: 9, b: 1, winner: 'a');
      expect(artRatio(t), isNull);
      expect(find.byKey(const ValueKey('pk-confetti')), findsOneWidget);
      expect(find.text('You won!'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('pk-result-ok')));
      await t.pumpAndSettle();
      await unmount(t);
    });

    testWidgets('the invite sheet shows the PK logo with the animations on, and not without', (t) async {
      loadingForever();
      await mount(t);
      late BuildContext inner;
      await t.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) {
        inner = context;
        return const SizedBox();
      }))));
      unawaited(showPkInviteSheet(inner, c));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('pk-sheet-logo')), findsOneWidget);
      Navigator.of(inner).pop();
      await t.pumpAndSettle();

      PkThemeStore.instance.use(const PkTheme(animations: false));
      unawaited(showPkInviteSheet(inner, c));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('pk-sheet-logo')), findsNothing);
      Navigator.of(inner).pop();
      await t.pumpAndSettle();
      c.dispose();
    });
  });
}
