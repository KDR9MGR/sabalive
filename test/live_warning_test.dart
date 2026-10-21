import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/arrival_lines.dart';
import 'package:sabalive/features/live/widgets/live_chat_bubble.dart';
import 'package:sabalive/state/live_warning_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The welcome warning a new arrival sees in their own chat in a video live and video PK: what the panel can say about it (on / off, the
/// text), the lines it adds in the right order and to the right person only, and how it looks.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final me = AppUser(id: 'me', name: 'Xyz', username: '@xyz');
  final ghost = AppUser(id: 'g', name: 'Ghost', username: '@g', isGhost: true);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
  });

  group('LiveWarning (what the panel says)', () {
    test('nothing saved, or a database without the columns: on, with the built-in text', () {
      for (final row in [null, <String, dynamic>{}, {'video_warning_enabled': null, 'video_warning_text': null}]) {
        final w = LiveWarning.fromRow(row);
        expect(w.enabled, isTrue);
        expect(w.text, isNull);
        expect(w.shown, kDefaultVideoWarning);
        final a = LiveWarning.fromRow(row, kind: LiveWarningKind.audio);
        expect(a.enabled, isTrue);
        expect(a.shown, kDefaultAudioWarning, reason: 'the audio warning has its own built-in wording');
      }
    });

    test('the panel can switch it off and write its own text', () {
      final off = LiveWarning.fromRow({'video_warning_enabled': false, 'video_warning_text': null});
      expect(off.enabled, isFalse);
      final custom = LiveWarning.fromRow({'video_warning_enabled': true, 'video_warning_text': '  Be kind. No abuse.  '});
      expect(custom.text, 'Be kind. No abuse.', reason: 'trimmed');
      expect(custom.shown, 'Be kind. No abuse.');
    });

    test('a blank, an over-long or an unreadable text falls back to the built-in one; a non-boolean switch stays on', () {
      expect(LiveWarning.fromRow({'video_warning_text': '   '}).text, isNull);
      expect(LiveWarning.fromRow({'video_warning_text': 'x' * (kLiveWarningMaxChars + 1)}).text, isNull);
      expect(LiveWarning.fromRow({'video_warning_text': 'x' * kLiveWarningMaxChars}).text, isNotNull);
      expect(LiveWarning.fromRow({'video_warning_text': 5}).text, isNull);
      expect(LiveWarning.fromRow({'video_warning_enabled': 'no'}).enabled, isTrue);
    });
  });

  group('LiveWarningStore', () {
    test('it applies what the panel saved for each kind and tells listeners only on a change', () async {
      var server = <String, dynamic>{'video_warning_enabled': false, 'audio_warning_text': 'Audio rules.'};
      final store = LiveWarningStore(fetch: () async => server);
      var told = 0;
      store.addListener(() => told++);
      await store.refresh();
      expect(store.video.enabled, isFalse);
      expect(store.audio.enabled, isTrue, reason: 'the audio warning is its own setting');
      expect(store.audio.text, 'Audio rules.');
      expect(store.audio.kind, LiveWarningKind.audio);
      expect(told, 1);
      await store.refresh();
      expect(told, 1, reason: 'the same value is not a change');
      server = {'video_warning_enabled': true, 'video_warning_text': 'Hello', 'audio_warning_enabled': false};
      await store.refresh();
      expect(store.video, const LiveWarning(enabled: true, text: 'Hello'));
      expect(store.audio.enabled, isFalse);
      expect(store.audio.text, isNull);
      expect(store.warningFor(LiveWarningKind.video), store.video);
      expect(store.warningFor(LiveWarningKind.audio), store.audio);
    });

    test('a failed read keeps what is showing, and both default to ON with their own built-in text', () async {
      var fail = false;
      final store = LiveWarningStore(fetch: () async => fail ? throw Exception('offline') : {'video_warning_text': 'Custom', 'audio_warning_text': 'Custom audio'});
      expect(store.video.enabled, isTrue);
      expect(store.audio.enabled, isTrue);
      expect(store.video.shown, kDefaultVideoWarning);
      expect(store.audio.shown, kDefaultAudioWarning);
      await store.refresh();
      expect(store.video.text, 'Custom');
      expect(store.audio.text, 'Custom audio');
      fail = true;
      await store.refresh();
      expect(store.video.text, 'Custom');
      expect(store.audio.text, 'Custom audio');
    });

    test('both are kept on the phone for the next launch', () async {
      final a = LiveWarningStore(
        fetch: () async => {'video_warning_enabled': false, 'video_warning_text': 'Saved video', 'audio_warning_enabled': true, 'audio_warning_text': 'Saved audio'},
      );
      await a.refresh();
      await Future<void>.delayed(Duration.zero);
      final b = LiveWarningStore(fetch: () async => throw Exception('no network yet'));
      await b.restore();
      expect(b.video, const LiveWarning(enabled: false, text: 'Saved video'));
      expect(b.audio, const LiveWarning(text: 'Saved audio', kind: LiveWarningKind.audio));
    });

    test('a damaged saved copy is ignored', () async {
      SharedPreferences.setMockInitialValues({'live.warning.v2': '[not an object'});
      final store = LiveWarningStore(fetch: () async => null);
      await store.restore();
      expect(store.video, const LiveWarning());
      expect(store.audio, const LiveWarning(kind: LiveWarningKind.audio));
    });
  });

  group('arrivalLines', () {
    test('my own "joined" notice first, then the warning under it', () {
      final lines = arrivalLines(me: me, warning: const LiveWarning());
      expect(lines, hasLength(2));
      expect(lines[0].isJoin, isTrue);
      expect(lines[0].user, me, reason: 'the notice is mine');
      expect(lines[0].notice, isFalse);
      expect(lines[1].notice, isTrue);
      expect(lines[1].system, isTrue);
      expect(lines[1].text, kDefaultVideoWarning);
    });

    test('an audio live gets the audio wording, with its own join line first', () {
      final lines = arrivalLines(me: me, warning: const LiveWarning(kind: LiveWarningKind.audio));
      expect(lines, hasLength(2));
      expect(lines[0].isJoin, isTrue);
      expect(lines[1].notice, isTrue);
      expect(lines[1].text, kDefaultAudioWarning);
      expect(lines[1].text, isNot(kDefaultVideoWarning), reason: 'a different message than the video one');
    });

    test('the panel\'s own text is what shows', () {
      final lines = arrivalLines(me: me, warning: const LiveWarning(text: 'Respect everyone.'));
      expect(lines.last.text, 'Respect everyone.');
    });

    test('nothing when the panel switched it off, for a ghost, and with nobody signed in', () {
      expect(arrivalLines(me: me, warning: const LiveWarning(enabled: false)), isEmpty);
      expect(arrivalLines(me: ghost, warning: const LiveWarning()), isEmpty, reason: 'a ghost watches without leaving a trace');
      expect(arrivalLines(me: null, warning: const LiveWarning()), isEmpty);
    });
  });

  group('how it looks and reads', () {
    Future<void> show(WidgetTester t, LiveChatLine line) =>
        t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 300, child: LiveChatLineBubble(line: line))))));

    testWidgets('the warning is a paragraph in the chat with no name in front of it', (t) async {
      await show(t, LiveChatLine(me, kDefaultVideoWarning, system: true, notice: true));
      expect(find.byKey(const ValueKey('live-warning')), findsOneWidget);
      expect(find.textContaining('Welcome to SABALIVE Live!'), findsOneWidget);
      expect(find.textContaining('Warning:'), findsOneWidget);
      expect(find.textContaining('Xyz'), findsNothing, reason: 'it is the house talking, not the user');
    });

    testWidgets('a text from the panel is shown as written', (t) async {
      await show(t, LiveChatLine(me, 'Be kind. No abuse.', system: true, notice: true));
      expect(find.text('Be kind. No abuse.'), findsOneWidget);
    });

    testWidgets('the built-in text follows the app language', (t) async {
      await I18n.set(languageByCode('hi'));
      await show(t, LiveChatLine(me, kDefaultVideoWarning, system: true, notice: true));
      expect(find.textContaining('SABALIVE Live में आपका स्वागत है'), findsOneWidget);
      expect(find.textContaining('Welcome to SABALIVE Live!'), findsNothing);
    });

    test('both built-in warnings have a translation in every language', () async {
      for (final l in kLanguages.where((l) => !const {'en', 'en_NG'}.contains(l.code))) {
        await I18n.set(l);
        for (final text in [kDefaultVideoWarning, kDefaultAudioWarning]) {
          expect(tr(text), isNot(text), reason: '${l.code} has no translation of: $text');
          expect(tr(text), contains('SABALIVE'), reason: l.code);
        }
        expect(tr(kDefaultAudioWarning), isNot(tr(kDefaultVideoWarning)), reason: '${l.code}: two different messages');
      }
    });
  });
}
