import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:sabalive/config/supabase_config.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/watch_audio_room_screen.dart';
import 'package:sabalive/features/live/watch_live_screen.dart';
import 'package:sabalive/features/live/watch_pk_battle_screen.dart';
import 'package:sabalive/router/app_nav.dart';
import 'package:sabalive/state/active_live_session_controller.dart';
import 'package:sabalive/state/session_controller.dart';
import 'package:sabalive/theme/app_theme.dart';

/// Regression coverage for the bug where every stream mode (video, audio,
/// pk) landed on the same video-only watch screen. Uses non-UUID stream ids
/// so isRealId() is false and each screen falls back to its mock/offline
/// path — no network needed, this is purely "does AppNav.watchLive route to
/// the right screen, and does that screen build without throwing."
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: SupabaseConfig.url,
      publishableKey: SupabaseConfig.publishableKey,
    );
  });

  AppUser host(String id) =>
      AppUser(id: id, name: 'Test Host', username: '@host');

  LiveStream stream(String id, LiveMode mode) => LiveStream(
    id: id,
    host: host('host-$id'),
    title: 'Test stream',
    category: 'Chatting',
    viewers: 0,
    mode: mode,
  );

  // Video/audio watch screens are no longer pushed as a Navigator route —
  // AppNav.watchLive registers them with ActiveLiveSessionController
  // instead, and app.dart's own MaterialApp.builder is what actually
  // mounts the active session above everything else (see app.dart's own
  // doc comment on why: a root-level overlay, not tied to any one route's
  // position in the stack). This harness mirrors that same wiring — both
  // providers, and the same builder shape — so "does watchLive route to
  // the right widget type" stays meaningful for all 3 modes; PK still
  // goes through a real Navigator.push (unaffected by any of this).
  Future<void> pumpWatch(WidgetTester tester, LiveStream s) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => SessionController()),
          ChangeNotifierProvider(create: (_) => ActiveLiveSessionController()),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => AppNav.watchLive(context, s),
              child: const Text('go'),
            ),
          ),
          builder: (context, child) => Stack(
            children: [
              ?child,
              Consumer<ActiveLiveSessionController>(
                builder: (context, session, _) => session.isActive
                    ? session.buildActive(context)
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  testWidgets('video mode routes to WatchLiveScreen', (tester) async {
    await pumpWatch(tester, stream('test-video', LiveMode.video));
    expect(find.byType(WatchLiveScreen), findsOneWidget);
  });

  testWidgets(
    'audio mode routes to WatchAudioRoomScreen, not the video screen',
    (tester) async {
      await pumpWatch(tester, stream('test-audio', LiveMode.audio));
      expect(find.byType(WatchAudioRoomScreen), findsOneWidget);
      expect(find.byType(WatchLiveScreen), findsNothing);
    },
  );

  testWidgets('pk mode routes to WatchPkBattleScreen, not the video screen', (
    tester,
  ) async {
    await pumpWatch(tester, stream('test-pk', LiveMode.pk));
    expect(find.byType(WatchPkBattleScreen), findsOneWidget);
    expect(find.byType(WatchLiveScreen), findsNothing);
  });
}
