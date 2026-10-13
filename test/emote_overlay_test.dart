import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/features/live/widgets/emote_overlay.dart';

void main() {
  group('emoteTextOf (a message that is only emoji)', () {
    test('one to three emoji count as an emote', () {
      expect(emoteTextOf('❤️'), '❤️');
      expect(emoteTextOf('🔥'), '🔥');
      expect(emoteTextOf(' 😂 '), '😂');
      expect(emoteTextOf('😍😍😍'), '😍😍😍');
      expect(emoteTextOf('👍🏽'), '👍🏽', reason: 'a skin tone belongs to its emoji');
      expect(emoteTextOf('👨‍👩‍👧'), '👨‍👩‍👧', reason: 'a joined family is one emoji');
      expect(emoteTextOf('🇮🇳'), '🇮🇳', reason: 'a flag');
      expect(emoteTextOf('1️⃣'), '1️⃣', reason: 'a keycap');
    });

    test('anything with words or numbers is a normal message', () {
      expect(emoteTextOf('hello'), isNull);
      expect(emoteTextOf('hi 😂'), isNull);
      expect(emoteTextOf('😂 lol'), isNull);
      expect(emoteTextOf('123'), isNull);
      expect(emoteTextOf('!'), isNull);
      expect(emoteTextOf(''), isNull);
      expect(emoteTextOf('   '), isNull);
    });

    test('a long run of emoji is chatter, not one emote', () {
      expect(emoteTextOf('😂😂😂😂'), isNull);
      expect(emoteTextOf('🔥🔥🔥🔥🔥🔥🔥🔥'), isNull);
    });
  });

  test('an emote now stays a slow five and a half seconds', () {
    expect(kEmoteHold, const Duration(milliseconds: 5500));
    expect(EmoteController().hold, kEmoteHold);
  });

  group('EmoteController', () {
    Map<String, dynamic> text(String sender, String body) => {'sender_id': sender, 'kind': 'text', 'body': body};

    test('an emoji from someone with a circle plays on it, and the chat line is skipped', () {
      final c = EmoteController();
      final handled = c.handleRow(text('a', '🔥'), hasCircle: (id) => id == 'a');
      expect(handled, isTrue);
      expect(c.of('a')?.emoji, '🔥');
      expect(c.of('b'), isNull);
      c.dispose();
    });

    test('someone without a circle on screen keeps the chat line', () {
      final c = EmoteController();
      expect(c.handleRow(text('v', '🔥'), hasCircle: (_) => false), isFalse);
      expect(c.of('v'), isNull);
      c.dispose();
    });

    test('a normal message is not an emote', () {
      final c = EmoteController();
      expect(c.handleRow(text('a', 'hello there'), hasCircle: (_) => true), isFalse);
      expect(c.of('a'), isNull);
      c.dispose();
    });

    test('an animated emote (a catalog GIF) plays its picture', () {
      final c = EmoteController();
      final row = {'sender_id': 'a', 'kind': 'sticker', 'sticker_url': 'https://x/e.gif', 'body': 'Wow'};
      expect(c.handleRow(row, hasCircle: (_) => true), isTrue);
      expect(c.of('a')?.assetUrl, 'https://x/e.gif');
      expect(c.of('a')?.emoji, isNull);
      c.dispose();
    });

    test('gifts, joins and rows without a sender are ignored', () {
      final c = EmoteController();
      expect(c.handleRow({'sender_id': 'a', 'kind': 'gift', 'body': '🔥'}, hasCircle: (_) => true), isFalse);
      expect(c.handleRow({'sender_id': 'a', 'kind': 'system', 'body': '🔥'}, hasCircle: (_) => true), isFalse);
      expect(c.handleRow({'kind': 'text', 'body': '🔥'}, hasCircle: (_) => true), isFalse);
      expect(c.handleRow({'sender_id': 'a', 'kind': 'sticker'}, hasCircle: (_) => true), isFalse);
      c.dispose();
    });

    testWidgets('it goes away by itself after the hold, and a new emote replaces the old one and restarts the clock', (t) async {
      final c = EmoteController(hold: const Duration(seconds: 3));
      var changes = 0;
      c.addListener(() => changes++);
      c.show('a', emoji: '🔥');
      final first = c.of('a')!.id;
      await t.pump(const Duration(seconds: 2));
      c.show('a', emoji: '😂');
      expect(c.of('a')!.id, isNot(first));
      expect(c.of('a')!.emoji, '😂');
      await t.pump(const Duration(seconds: 2));
      expect(c.of('a'), isNotNull, reason: 'the new emote has its own full hold');
      await t.pump(const Duration(seconds: 2));
      expect(c.of('a'), isNull);
      expect(changes, 3, reason: 'shown, replaced, cleared');
      c.dispose();
    });

    testWidgets('disposing stops the timers (nothing left pending)', (t) async {
      final c = EmoteController()..show('a', emoji: '🔥');
      c.dispose();
      await t.pump(const Duration(seconds: 10));
    });
  });

  group('EmoteOnAvatar', () {
    testWidgets('puts the emote over the avatar, and nothing extra when there is none', (t) async {
      final c = EmoteController();
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: EmoteOnAvatar(
              controller: c,
              userId: 'a',
              size: 40,
              child: const SizedBox.square(dimension: 40, key: ValueKey('avatar')),
            ),
          ),
        ),
      ));
      expect(find.byType(EmoteOverlay), findsNothing);
      c.show('a', emoji: '🔥');
      await t.pump();
      expect(find.byType(EmoteOverlay), findsOneWidget);
      expect(find.text('🔥'), findsOneWidget);
      // centred on the avatar and bigger than it, so it reads
      final avatar = t.getRect(find.byKey(const ValueKey('avatar')));
      final overlay = t.getRect(find.byType(EmoteOverlay));
      expect(overlay.center.dx, closeTo(avatar.center.dx, 0.5));
      expect(overlay.width, greaterThan(avatar.width));
      // someone else's emote does not show here
      c.show('b', emoji: '😂');
      await t.pump();
      expect(find.text('😂'), findsNothing);
      await t.pump(const Duration(seconds: 7));
      expect(find.byType(EmoteOverlay), findsNothing);
      c.dispose();
    });

    testWidgets('without a controller it is just the child', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: EmoteOnAvatar(controller: null, userId: 'a', size: 40, child: SizedBox.square(dimension: 40)),
        ),
      ));
      expect(find.byType(EmoteOverlay), findsNothing);
    });
  });
}
