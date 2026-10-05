import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sabalive/features/live/widgets/live_back_guard.dart';
import 'package:sabalive/state/active_live_session_controller.dart';

void main() {
  // What Flutter tells Android about back: `true` = "send back gestures to the app".
  // Android 16 lets the system handle back itself (leaving the app) unless this is true.
  late List<bool> told;

  setUp(() {
    told = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
          told.add(call.arguments as bool);
        }
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<ActiveLiveSessionController> pumpApp(WidgetTester t) async {
    final session = ActiveLiveSessionController();
    await t.pumpWidget(
      ChangeNotifierProvider.value(
        value: session,
        child: const MaterialApp(home: LiveBackGuard(child: Scaffold(body: Text('home')))),
      ),
    );
    // the app only reports to the platform once it is running in the foreground
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    return session;
  }

  void startLive(ActiveLiveSessionController s) =>
      s.start(roomId: 'room', builder: (_) => const SizedBox(), hostName: 'Host');

  testWidgets('with no live, back is left to the system (the app can exit normally)', (t) async {
    final session = await pumpApp(t);
    startLive(session);
    await t.pump();
    session.end();
    await t.pump();
    expect(told.last, isFalse);
  });

  testWidgets('a full-screen live makes the app claim back, so the gesture reaches the live', (t) async {
    final session = await pumpApp(t);
    startLive(session);
    await t.pump();
    expect(told.last, isTrue);
  });

  testWidgets('a minimized live no longer claims back', (t) async {
    final session = await pumpApp(t);
    startLive(session);
    await t.pump();
    expect(told.last, isTrue);
    session.minimize();
    await t.pump();
    expect(told.last, isFalse);
    session.restore();
    await t.pump();
    expect(told.last, isTrue);
  });
}
