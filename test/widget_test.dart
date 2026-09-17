import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:sabalive/app.dart';
import 'package:sabalive/config/supabase_config.dart';
import 'package:sabalive/features/splash/splash_screen.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // supabase_flutter's auth listens for deep links via the app_links
    // plugin, which has no native implementation in this headless test
    // environment — without a mock it throws MissingPluginException. Mock
    // it as "no incoming links," matching reality for a test run.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      const EventChannel('com.llfbandit.app_links/events'),
      MockStreamHandler.inline(onListen: (_, events) {}),
    );
    await Supabase.initialize(
      url: SupabaseConfig.url,
      publishableKey: SupabaseConfig.publishableKey,
    );
  });

  testWidgets('App boots to the splash screen', (WidgetTester tester) async {
    await tester.pumpWidget(const SabaLiveApp());
    await tester.pump();

    expect(find.byType(SplashScreen), findsOneWidget);

    // SabaLiveApp's providers (LiveStreamsController, ThemeConfigController,
    // etc.) each hold a real Realtime channel. Unmount the tree ourselves
    // now — each provider's dispose() unsubscribes its channel, which
    // schedules the realtime_client package's own 50s "pending disconnect"
    // timer (its grace period before actually closing the shared socket,
    // in case a new channel subscribes again right away). Left alone, that
    // timer would still be pending when the test framework's own automatic
    // teardown runs after this function returns, tripping the "no pending
    // timers" check. Supabase.instance.dispose() explicitly cancels it —
    // RealtimeClient.disconnect() starts with _cancelPendingDisconnect() —
    // but only if it runs *after* the unsubscribes that scheduled it, so
    // the ordering here matters. Both steps need a real async zone:
    // testWidgets bodies run in a fake-async zone where Timer-based
    // deadlines only advance via explicit pump(), but this is real network
    // I/O with its own real timers — runAsync is flutter_test's documented
    // escape hatch for exactly that mismatch.
    await tester.runAsync(() async {
      // The Realtime websocket connections providers opened during the
      // pump above may still be mid TCP/DNS handshake (dart:io's own
      // staggered-lookup/staggered-connect timers) — those can only
      // resolve on their own once the connection finishes, closing an
      // in-flight connection attempt doesn't cancel them. Give it a beat
      // to settle before unmounting and disposing.
      await Future.delayed(const Duration(milliseconds: 800));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await Supabase.instance.dispose();
    });
  });
}
