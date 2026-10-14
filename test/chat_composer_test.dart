import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/chat_composer.dart';
import 'package:sabalive/features/live/widgets/mentions.dart';

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

  testWidgets('send on an empty box does not close the keyboard', (t) async {
    await t.pumpWidget(host());
    await t.showKeyboard(find.byType(TextField));
    await t.pump();
    expect(focus.hasFocus, isTrue);
    await t.tap(find.byIcon(Icons.send_rounded));
    await t.pump();
    expect(focus.hasFocus, isTrue, reason: 'nothing was sent, so the keyboard stays');
  });

  testWidgets('a person whose chat the host turned off cannot type or send, and is told why', (t) async {
    await t.pumpWidget(host(chatOff: true));
    expect(find.text('The host turned your chat off'), findsOneWidget);
    expect(t.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    await t.tap(find.byIcon(Icons.send_rounded));
    await t.pump();
    expect(sent, 0);
  });

  testWidgets('the buttons given as leading sit in front of the pill', (t) async {
    await t.pumpWidget(host());
    expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);
  });
}
