import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/features/games/game_webview_screen.dart' show GameExit;
import 'package:sabalive/features/games/sud_bridge.dart';
import 'package:sabalive/features/games/sud_game_screen.dart';
import 'package:sabalive/features/games/sud_launch.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SUD games run in SUD's NATIVE SDK now (their web SDK is refused for our app: error 10005 for every game). The values come from the launch address our server already
/// answers with; the screen is driven here by a fake SDK.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
  });

  const api = 'https://abc123.supabase.co/functions/v1/sud';
  String address({Map<String, String> change = const {}, Iterable<String> drop = const []}) {
    final q = {
      'appId': '1234567890123456789',
      'appKey': 'client-key',
      'gameId': '1468180338417074177',
      'roomId': 'live-123',
      'userId': 'b1000000-0000-0000-0000-0000000000b2',
      'code': 'a.b.c',
      't': 'x.y.z',
      'api': api,
      'test': '1',
      'lang': 'en-US',
      ...change,
    }..removeWhere((k, _) => drop.contains(k));
    return Uri.https('www.sabalive.in', '/sud/play', q).toString();
  }

  group('SudLaunch', () {
    test('reads the values the server put in the launch address', () {
      final l = SudLaunch.fromUrl(Uri.parse(address()))!;
      expect(l.appId, '1234567890123456789');
      expect(l.appKey, 'client-key');
      expect(l.gameId, '1468180338417074177', reason: 'a 19 digit id, kept as text');
      expect((l.roomId, l.userId, l.code, l.launchToken), ('live-123', 'b1000000-0000-0000-0000-0000000000b2', 'a.b.c', 'x.y.z'));
      expect((l.testEnv, l.language), (true, 'en-US'));
      expect(l.refreshUrl.toString(), '$api/refresh');
      expect(jsonDecode(l.refreshBody), {'t': 'x.y.z'});
    });

    test('test=0 means SUD\'s production environment, anything else the test one', () {
      expect(SudLaunch.fromUrl(Uri.parse(address(change: {'test': '0'})))!.testEnv, isFalse);
      expect(SudLaunch.fromUrl(Uri.parse(address(drop: ['test'])))!.testEnv, isTrue);
    });

    test('every missing or odd piece is refused (the game says it is not available instead of starting something half-made)', () {
      for (final key in ['appId', 'appKey', 'gameId', 'roomId', 'userId', 'code', 't', 'api']) {
        expect(SudLaunch.fromUrl(Uri.parse(address(drop: [key]))), isNull, reason: key);
      }
      expect(SudLaunch.fromUrl(Uri.parse(address(change: {'gameId': '12ab'}))), isNull);
      expect(SudLaunch.fromUrl(Uri.parse(address(change: {'roomId': 'a b&c'}))), isNull);
    });

    test('the code is only ever renewed from OUR function: no other address is trusted', () {
      for (final bad in ['http://abc123.supabase.co/functions/v1/sud', 'https://evil.example/functions/v1/sud', 'https://abc123.supabase.co/functions/v1/other', 'https://abc123.supabase.co.evil.com/functions/v1/sud']) {
        expect(SudLaunch.fromUrl(Uri.parse(address(change: {'api': bad}))), isNull, reason: bad);
      }
      expect(SudLaunch.trustedApi('$api/')?.toString(), api, reason: 'a trailing slash is fine');
    });

    test('an odd language falls back to English', () {
      expect(SudLaunch.fromUrl(Uri.parse(address(change: {'lang': 'not a language!'})))!.language, 'en-US');
      expect(SudLaunch.fromUrl(Uri.parse(address(change: {'lang': 'ar-SA'})))!.language, 'ar-SA');
    });
  });

  group('what the SDK is told', () {
    test('the view size is in device pixels and takes no margin from the game', () {
      final v = jsonDecode(sudViewInfoJson(1080, 1620)) as Map;
      expect(v['ret_code'], 0);
      expect(v['view_size'], {'width': 1080, 'height': 1620});
      expect(v['view_game_rect'], {'left': 0, 'top': 0, 'right': 0, 'bottom': 0});
      expect((jsonDecode(sudViewInfoJson(0, -5)) as Map)['view_size'], {'width': 1, 'height': 1}, reason: 'never zero');
    });

    test('the game config keeps SUD\'s defaults and hides the ping and version labels', () {
      final c = jsonDecode(sudGameConfigJson()) as Map;
      expect((c['gameMode'], c['gameSoundVolume']), (1, 100));
      expect((c['ui'] as Map)['ping'], {'hide': true});
    });

    test('a failure shows SUD\'s number and nothing of the SDK\'s own text', () {
      expect(sudStartFailure(10005), 'The game could not start (10005). Please close it and try again.');
      expect(sudStartFailure(null), 'The game could not start. Please close it and try again.');
      expect(sudStartFailure('<b>x</b> 123'), isNot(contains('<')));
    });
  });

  group('the panel size', () {
    test('a SUD game\'s panel is 1080 x 1669 (the owner\'s screenshot): 1.545 times as tall as it is wide', () {
      expect(kSudGameAspect, closeTo(1669 / 1080, 1e-9));
      expect(kSudGameAspect, closeTo(1.5454, 0.0001));
    });

    testWidgets('the screen draws the panel at that proportion', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: SudGameScreen(
          launch: SudLaunch.fromUrl(Uri.parse(address()))!,
          title: 'Ludo',
          aspect: kSudGameAspect,
          bridge: _FakeBridge(),
          renewCode: (_) async => null,
        ),
      ));
      await t.pump();
      final size = t.getSize(find.byKey(const ValueKey('game-panel')));
      expect(size.width, 1080);
      expect(size.height, closeTo(1669, 1.5), reason: 'the game gets 1080 x 1669 px on a 1080 px wide phone (plus the system bar\'s inset, none here)');
      await t.pumpWidget(const SizedBox());
    });
  });

  group('the game screen', () {
    late _FakeBridge bridge;
    SudLaunch launch() => SudLaunch.fromUrl(Uri.parse(address()))!;
    GameExit? closedWith;

    Future<void> open(WidgetTester t, {Future<String?> Function(SudLaunch)? renew, Duration timeout = const Duration(seconds: 90)}) async {
      t.view.physicalSize = const Size(400, 800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      closedWith = null;
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  closedWith = await Navigator.of(context).push<GameExit>(MaterialPageRoute(
                    builder: (_) => SudGameScreen(launch: launch(), title: 'Ludo', aspect: 1.0, bridge: bridge, renewCode: renew ?? (_) async => 'new.code', loadTimeout: timeout),
                  ));
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pump();
      await t.pump(); // the native view exists, then the game is loaded after the first frame
      await t.pump();
      await t.pump(const Duration(milliseconds: 500)); // the page is in place (the spinner never settles, so no pumpAndSettle)
    }

    testWidgets('creates the view, starts SUD with the launch values at the view\'s pixel size, and shows the progress until the game has started', (t) async {
      bridge = _FakeBridge();
      await open(t);
      expect(bridge.calls.first, startsWith('init 1234567890123456789 '));
      expect(bridge.calls.first, contains('b1000000-0000-0000-0000-0000000000b2'));
      expect(bridge.calls.first, endsWith('test=true'));
      expect(bridge.loaded, hasLength(1));
      expect(bridge.loaded.single.gameId, '1468180338417074177');
      final info = jsonDecode(bridge.viewInfo!) as Map;
      expect((info['view_size'] as Map)['width'], greaterThan(0));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      bridge.events!.onLoading!(37, 0);
      await t.pump();
      expect(find.text('37%'), findsOneWidget);
      bridge.events!.onLoading!(80, 5);
      await t.pump();
      expect(find.text('37%'), findsOneWidget, reason: 'a step that reports a problem does not move the bar');
      bridge.events!.onStarted!();
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('SUD refusing the start (10005) says so with the number and Retry tries again from a destroyed game', (t) async {
      bridge = _FakeBridge()..initResult = const SudResult(10005, 'Invalid app platform information');
      await open(t);
      expect(find.byKey(const ValueKey('sud-failure')), findsOneWidget);
      expect(find.textContaining('(10005)'), findsOneWidget);
      expect(find.textContaining('Invalid app platform'), findsNothing, reason: 'the SDK\'s own words are not shown');
      expect(bridge.loaded, isEmpty);
      bridge.initResult = const SudResult(0);
      await t.tap(find.text('Retry'));
      await t.pump();
      await t.pump();
      expect(bridge.calls, contains('destroy 7'));
      expect(bridge.loaded, hasLength(1));
      expect(find.byKey(const ValueKey('sud-failure')), findsNothing);
    });

    testWidgets('a game that cannot be loaded says so too', (t) async {
      bridge = _FakeBridge()..loadResult = const SudResult(1, 'bad params');
      await open(t);
      expect(find.byKey(const ValueKey('sud-failure')), findsOneWidget);
      expect(find.textContaining('(1)'), findsOneWidget);
    });

    testWidgets('a game that never starts is given up on after the time limit, and says why', (t) async {
      bridge = _FakeBridge()..initGate = Completer<void>();
      await open(t, timeout: const Duration(seconds: 5));
      expect(find.byKey(const ValueKey('sud-failure')), findsNothing);
      await t.pump(const Duration(seconds: 6));
      await t.pump();
      expect(find.text(kSudTimeoutMessage), findsOneWidget);
    });

    testWidgets('when the login code expires a new one is fetched from our server and handed to the game', (t) async {
      bridge = _FakeBridge();
      final asked = <String>[];
      await open(t, renew: (l) async {
        asked.add(l.launchToken);
        return 'fresh.code';
      });
      bridge.events!.onStarted!();
      bridge.events!.onExpireCode!();
      await t.pump();
      await t.pump();
      expect(asked, ['x.y.z']);
      expect(bridge.calls, contains('updateCode 7 fresh.code'));
    });

    testWidgets('a code that cannot be renewed is not handed over (the game carries on until SUD refuses it)', (t) async {
      bridge = _FakeBridge();
      await open(t, renew: (_) async => null);
      bridge.events!.onStarted!();
      bridge.events!.onExpireCode!();
      await t.pump();
      await t.pump();
      expect(bridge.calls.any((c) => c.startsWith('updateCode')), isFalse);
    });

    testWidgets('the game\'s "back to lobby" closes the panel', (t) async {
      bridge = _FakeBridge();
      await open(t);
      bridge.events!.onStarted!();
      bridge.events!.onState!('mg_common_game_state', '{}');
      await t.pump();
      expect(find.byType(SudGameScreen), findsOneWidget, reason: 'other states change nothing');
      bridge.events!.onState!(kSudBackLobbyState, '{}');
      await t.pumpAndSettle();
      expect(find.byType(SudGameScreen), findsNothing);
      expect(closedWith, GameExit.closed);
    });

    testWidgets('the game pauses in the background and resumes in front, only while it is running', (t) async {
      bridge = _FakeBridge();
      await open(t);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump();
      expect(bridge.calls.any((c) => c.startsWith('pause')), isFalse, reason: 'not started yet');
      bridge.events!.onStarted!();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump();
      expect(bridge.calls, contains('pause 7'));
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      expect(bridge.calls, contains('resume 7'));
    });

    testWidgets('closing the panel destroys the game and frees the native view', (t) async {
      bridge = _FakeBridge();
      await open(t);
      bridge.events!.onStarted!();
      await t.tap(find.byKey(const ValueKey('game-panel-close')));
      await t.pumpAndSettle();
      expect(bridge.calls, contains('release 7'));
      expect(closedWith, GameExit.closed);
    });
  });
}

/// A stand-in for SUD's SDK: records what the screen asks and lets a test answer.
class _FakeBridge implements SudBridge {
  final List<String> calls = [];
  final List<SudLaunch> loaded = [];
  String? viewInfo;
  SudGameEvents? events;
  SudResult initResult = const SudResult(0);
  SudResult loadResult = const SudResult(0);
  Completer<void>? initGate;

  @override
  Widget buildView(void Function(int viewId) onCreated) => _FakeView(onCreated);

  @override
  Future<SudResult> init({required String appId, required String appKey, required String userId, required bool testEnv}) async {
    calls.add('init $appId $userId test=$testEnv');
    await initGate?.future;
    return initResult;
  }

  @override
  Future<SudResult> load(int viewId, SudLaunch launch, {required String viewInfoJson, required String configJson, required SudGameEvents events}) async {
    calls.add('load $viewId');
    loaded.add(launch);
    viewInfo = viewInfoJson;
    this.events = events;
    return loadResult;
  }

  @override
  Future<void> updateCode(int viewId, String code) async => calls.add('updateCode $viewId $code');
  @override
  Future<void> pause(int viewId) async => calls.add('pause $viewId');
  @override
  Future<void> resume(int viewId) async => calls.add('resume $viewId');
  @override
  Future<void> destroy(int viewId) async => calls.add('destroy $viewId');
  @override
  Future<void> release(int viewId) async => calls.add('release $viewId');
}

class _FakeView extends StatefulWidget {
  const _FakeView(this.onCreated);
  final void Function(int) onCreated;
  @override
  State<_FakeView> createState() => _FakeViewState();
}

class _FakeViewState extends State<_FakeView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onCreated(7));
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.green);
}
