import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/chat_composer.dart';
import 'package:sabalive/features/live/widgets/mentions.dart';
import 'package:sabalive/theme/app_colors.dart';
import 'package:sabalive/theme/app_theme.dart';

AppUser _u(String id, String name) => AppUser(id: id, name: name, username: '@$id');

void main() {
  late TextEditingController controller;
  late FocusNode focus;
  var sent = 0;

  setUp(() {
    controller = TextEditingController();
    focus = FocusNode();
    sent = 0;
  });
  tearDown(() {
    controller.dispose();
    focus.dispose();
  });

  Widget host({bool chatOff = false, List<AppUser>? people}) => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: LiveChatComposer(
              controller: controller,
              focusNode: focus,
              onSend: () => sent++,
              chatOff: chatOff,
              myId: 'me',
              people: () => people ?? [_u('1', 'Riya'), _u('2', 'Astro Sharma'), _u('me', 'Mohit'), _u('3', 'Rishi')],
              leading: const [Icon(Icons.more_horiz_rounded)],
            ),
          ),
        ),
      );

  testWidgets('a message is cut at 60 characters, and a count shows near the end', (t) async {
    await t.pumpWidget(host());
    await t.enterText(find.byType(TextField), 'x' * 80);
    await t.pump();
    expect(controller.text.length, kLiveChatMaxChars);
    expect(find.text('60/60'), findsOneWidget);
  });

  testWidgets('a short message shows no count', (t) async {
    await t.pumpWidget(host());
    await t.enterText(find.byType(TextField), 'hello');
    await t.pump();
    expect(find.textContaining('/60'), findsNothing);
  });

  testWidgets('typing @ lists people in the room, never yourself', (t) async {
    await t.pumpWidget(host());
    await t.enterText(find.byType(TextField), 'hi @');
    await t.pump();
    expect(find.text('Riya'), findsOneWidget);
    expect(find.text('Astro Sharma'), findsOneWidget);
    expect(find.text('Mohit'), findsNothing, reason: 'that is me');
  });

  testWidgets('what is typed after the @ narrows the list', (t) async {
    await t.pumpWidget(host());
    await t.enterText(find.byType(TextField), 'hi @ri');
    await t.pump();
    expect(find.text('Riya'), findsOneWidget);
    expect(find.text('Rishi'), findsOneWidget);
    expect(find.text('Astro Sharma'), findsNothing);
  });

  testWidgets('picking a name tags them and closes the list', (t) async {
    await t.pumpWidget(host());
    await t.enterText(find.byType(TextField), 'hi @astro');
    await t.pump();
    await t.tap(find.text('Astro Sharma'));
    await t.pump();
    expect(controller.text, 'hi @Astro Sharma ');
    expect(find.text('Astro Sharma'), findsNothing, reason: 'the list is gone');
  });

  testWidgets('no list while not typing a tag', (t) async {
    await t.pumpWidget(host());
    await t.enterText(find.byType(TextField), 'just chatting');
    await t.pump();
    expect(find.text('Riya'), findsNothing);
  });

  testWidgets('the send button and the keyboard send both send', (t) async {
    await t.pumpWidget(host());
    await t.enterText(find.byType(TextField), 'hello');
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    await t.tap(find.byIcon(Icons.send_rounded));
    await t.pump();
    expect(sent, 1);
    // sending closed the keyboard, so type again to bring it back before using the keyboard's own send key
    await t.enterText(find.byType(TextField), 'hello again');
    await t.testTextInput.receiveAction(TextInputAction.send);
    await t.pump();
    expect(sent, 2);
  });

  testWidgets('tapping send sends once and puts the keyboard away', (t) async {
    await t.pumpWidget(host());
    await t.enterText(find.byType(TextField), 'hello');
    await t.pump();
    expect(focus.hasFocus, isTrue, reason: 'typing keeps the keyboard up');
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    await t.tap(find.byIcon(Icons.send_rounded));
    await t.pump();
    expect(sent, 1);
    expect(focus.hasFocus, isFalse, reason: 'sending closes the keyboard');
  });

  testWidgets('the keyboard send key also sends and puts the keyboard away', (t) async {
    await t.pumpWidget(host());
    await t.enterText(find.byType(TextField), 'hello');
    await t.testTextInput.receiveAction(TextInputAction.send);
    await t.pump();
    expect(sent, 1, reason: 'one send, not two');
    expect(focus.hasFocus, isFalse);
  });

  testWidgets('an empty box (or only spaces) has no Send button, so there is nothing to tap and the keyboard stays', (t) async {
    await t.pumpWidget(host());
    await t.showKeyboard(find.byType(TextField));
    await t.pump();
    expect(focus.hasFocus, isTrue);
    expect(find.byIcon(Icons.send_rounded), findsNothing, reason: 'nothing typed: no Send button (owner, 2026-11-07)');
    await t.enterText(find.byType(TextField), '   ');
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    expect(find.byIcon(Icons.send_rounded), findsNothing, reason: 'spaces are not a message');
    expect(focus.hasFocus, isTrue, reason: 'with nothing to send the keyboard simply stays');
  });

  testWidgets('the Send button appears as soon as something is typed and goes again when it is cleared', (t) async {
    await t.pumpWidget(host());
    expect(find.byIcon(Icons.send_rounded), findsNothing);
    await t.enterText(find.byType(TextField), 'h');
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
    await t.enterText(find.byType(TextField), '');
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    await t.pump();
    expect(find.byIcon(Icons.send_rounded), findsNothing);
  });

  testWidgets('one tap on Send sends ONCE even though the button answers through two doors (a tap and a finger lifted on it)', (t) async {
    await t.pumpWidget(host());
    await t.enterText(find.byType(TextField), 'hello');
    await t.pump();
    await t.tap(find.byIcon(Icons.send_rounded));
    await t.pump();
    expect(sent, 1);
  });

  testWidgets('a finger that slides off the button before lifting does not send', (t) async {
    await t.pumpWidget(host());
    await t.enterText(find.byType(TextField), 'hello');
    await t.pump();
    final g = await t.startGesture(t.getCenter(find.byIcon(Icons.send_rounded)));
    await g.moveBy(const Offset(-120, -120));
    await g.up();
    await t.pump();
    expect(sent, 0);
  });

  testWidgets('a gesture on a parent (a double tap, a drag) cannot take the touch away from Send', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onDoubleTap: () {},
          onVerticalDragUpdate: (_) {},
          onLongPress: () {},
          child: Align(
            alignment: Alignment.bottomCenter,
            child: LiveChatComposer(controller: controller, focusNode: focus, onSend: () => sent++, people: () => [], leading: const []),
          ),
        ),
      ),
    ));
    await t.enterText(find.byType(TextField), 'hello');
    await t.pump();
    final g = await t.startGesture(t.getCenter(find.byIcon(Icons.send_rounded)));
    await t.pump(const Duration(milliseconds: 120));
    await g.moveBy(const Offset(2, 3));
    await g.up();
    await t.pump(const Duration(milliseconds: 400));
    expect(sent, 1);
  });

  testWidgets('the Send button is a 48 x 44 target and says "Send" to screen readers', (t) async {
    await t.pumpWidget(host());
    await t.enterText(find.byType(TextField), 'hello');
    await t.pump();
    final box = t.getSize(find.byKey(const ValueKey('live-chat-send')));
    expect((box.width, box.height), (48, 44));
    expect(find.bySemanticsLabel('Send'), findsOneWidget);
  });

  testWidgets('the field is one clean pill: no border, no second filled box inside it, even under the app\'s own theme', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: AppTheme.dark(primary: AppColors.primary, secondary: const Color(0xFFEC4899)),
      home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: LiveChatComposer(controller: controller, focusNode: focus, onSend: () => sent++, people: () => [], leading: const []))),
    ));
    final d = t.widget<TextField>(find.byType(TextField)).decoration!;
    expect(d.filled, isFalse, reason: 'the theme fills every TextField; that drew a second box inside the pill');
    expect(d.enabledBorder, InputBorder.none);
    expect(d.focusedBorder, InputBorder.none);
    expect(d.disabledBorder, InputBorder.none);
    final pill = t.widget<Container>(find.ancestor(of: find.byType(TextField), matching: find.byType(Container)).first);
    expect((pill.decoration as BoxDecoration).border, isNull, reason: 'the pill has no border line');
  });

  testWidgets('a person whose chat the host turned off cannot type, has no Send button, and is told why', (t) async {
    await t.pumpWidget(host(chatOff: true));
    expect(find.text('The host turned your chat off'), findsOneWidget);
    expect(t.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(find.byIcon(Icons.send_rounded), findsNothing);
    expect(sent, 0);
  });

  testWidgets('the buttons given as leading sit in front of the pill', (t) async {
    await t.pumpWidget(host());
    expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);
  });
}
