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

  AppUser host(String id) => AppUser(id: id, name: 'Test Host', username: '@host');

  LiveStream stream(String id, LiveMode mode) => LiveStream(
        id: id,
        host: host('host-$id'),
        title: 'Test stream',
        category: 'Chatting',
        viewers: 0,
        mode: mode,
      );

  Future<void> pumpWatch(WidgetTester tester, LiveStream s) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SessionController(),
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => AppNav.watchLive(context, s),
              child: const Text('go'),
            ),
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

  testWidgets('audio mode routes to WatchAudioRoomScreen, not the video screen',
      (tester) async {
    await pumpWatch(tester, stream('test-audio', LiveMode.audio));
    expect(find.byType(WatchAudioRoomScreen), findsOneWidget);
    expect(find.byType(WatchLiveScreen), findsNothing);
  });

  testWidgets('pk mode routes to WatchPkBattleScreen, not the video screen',
      (tester) async {
    await pumpWatch(tester, stream('test-pk', LiveMode.pk));
    expect(find.byType(WatchPkBattleScreen), findsOneWidget);
    expect(find.byType(WatchLiveScreen), findsNothing);
  });
}
