import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/live_card.dart';
import 'package:sabalive/features/live/widgets/live_type_label.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Audio / Video / PK label on a live card and a live row.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
  });

  LiveStream live(LiveMode mode, {bool inBattle = false}) =>
      LiveStream(id: 's-${mode.name}', host: AppUser(id: 'h', name: 'Host', username: '@h'), title: 'Hello', category: 'Chat', viewers: 12, mode: mode)..inBattle = inBattle;

  group('what kind of live it is', () {
    test('an audio room is Audio, a video live is Video', () {
      expect(liveKindOf(live(LiveMode.audio)), LiveKind.audio);
      expect(liveKindOf(live(LiveMode.video)), LiveKind.video);
    });

    test('an old PK-mode live and any live in a battle right now are PK', () {
      expect(liveKindOf(live(LiveMode.pk)), LiveKind.pk);
      expect(liveKindOf(live(LiveMode.audio, inBattle: true)), LiveKind.pk, reason: 'an audio room in a PK battle');
      expect(liveKindOf(live(LiveMode.video, inBattle: true)), LiveKind.pk, reason: 'a video live in a PK battle');
    });
  });

  group('the label', () {
    Future<void> show(WidgetTester t, Widget child) => t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: child))));

    testWidgets('Audio has the mic, Video the camera, PK the bolt, each with its word', (t) async {
      await show(t, const LiveTypeLabel(kind: LiveKind.audio));
      expect(find.text('Audio'), findsOneWidget);
      expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
      await show(t, const LiveTypeLabel(kind: LiveKind.video));
      expect(find.text('Video'), findsOneWidget);
      expect(find.byIcon(Icons.videocam_rounded), findsOneWidget);
      await show(t, const LiveTypeLabel(kind: LiveKind.pk));
      expect(find.text('PK'), findsOneWidget);
      expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);
    });

    testWidgets('the small one for rows is smaller', (t) async {
      await show(t, const LiveTypeLabel(kind: LiveKind.audio));
      final normal = t.getSize(find.byKey(const ValueKey('live-type-audio')));
      await show(t, const LiveTypeLabel(kind: LiveKind.audio, dense: true));
      final small = t.getSize(find.byKey(const ValueKey('live-type-audio')));
      expect(small.height, lessThan(normal.height));
      expect(small.width, lessThan(normal.width));
    });

    testWidgets('the words follow the app language', (t) async {
      await I18n.set(languageByCode('hi'));
      await show(t, const LiveTypeLabel(kind: LiveKind.audio));
      expect(find.text('Audio'), findsNothing);
      await show(t, const LiveTypeLabel(kind: LiveKind.video));
      expect(find.text('Video'), findsNothing);
    });
  });

  group('on the cards', () {
    Future<void> card(WidgetTester t, LiveStream s) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 173, child: LiveCard(stream: s, onTap: () {})))));
    }

    testWidgets('an audio live card says Audio, not Video or PK', (t) async {
      await card(t, live(LiveMode.audio));
      expect(find.byKey(const ValueKey('live-type-audio')), findsOneWidget);
      expect(find.byKey(const ValueKey('live-type-video')), findsNothing);
      expect(find.byKey(const ValueKey('live-type-pk')), findsNothing);
    });

    testWidgets('a video live card says Video', (t) async {
      await card(t, live(LiveMode.video));
      expect(find.byKey(const ValueKey('live-type-video')), findsOneWidget);
    });

    testWidgets('a card in a battle says PK instead of Audio / Video', (t) async {
      await card(t, live(LiveMode.audio, inBattle: true));
      expect(find.byKey(const ValueKey('live-type-pk')), findsOneWidget);
      expect(find.byKey(const ValueKey('live-type-audio')), findsNothing);
    });

    testWidgets('the label and the viewer count fit side by side on a half-width card', (t) async {
      await card(t, live(LiveMode.audio));
      expect(t.takeException(), isNull, reason: 'no overflow');
      expect(find.text('12'), findsOneWidget);
    });

    testWidgets('the list row has the small label too', (t) async {
      await t.pumpWidget(MaterialApp(home: Scaffold(body: LiveListTile(stream: live(LiveMode.video), onTap: () {}))));
      expect(find.byKey(const ValueKey('live-type-video')), findsOneWidget);
    });
  });
}
