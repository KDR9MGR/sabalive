import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/widgets/keyboard_lift.dart';

void main() {
  const stageKey = Key('stage');
  const chatKey = Key('chat');
  const inputKey = Key('input');

  // a live screen in miniature: top bar, stage that takes the rest, chat, input bar, then the system bar
  Widget screen() => MaterialApp(
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: KeyboardStable(
            child: SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 40),
                  const Expanded(child: SizedBox.expand(key: stageKey)),
                  const KeyboardLift(child: SizedBox(key: chatKey, height: 120, width: 200)),
                  const SizedBox(height: 10),
                  KeyboardLift(
                    child: SizedBox(
                      key: inputKey,
                      height: 44,
                      child: const TextField(),
                    ),
                  ),
                  Builder(builder: (context) => SizedBox(height: MediaQuery.viewPaddingOf(context).bottom + 6)),
                ],
              ),
            ),
          ),
        ),
      );

  void setBars(WidgetTester tester, {required double keyboard}) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
    // like Android: while the keyboard is up, `padding` loses the part the keyboard covers
    tester.view.padding = FakeViewPadding(top: 24, bottom: keyboard > 34 ? 0 : 34 - keyboard);
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  }

  testWidgets('the stage and top bar do not move when the keyboard opens', (tester) async {
    addTearDown(tester.view.reset);
    setBars(tester, keyboard: 0);
    await tester.pumpWidget(screen());
    final stageBefore = tester.getRect(find.byKey(stageKey));

    setBars(tester, keyboard: 300);
    await tester.pump();
    expect(tester.getRect(find.byKey(stageKey)), stageBefore);
  });

  testWidgets('the chat and the input bar rise to sit just above the keyboard', (tester) async {
    addTearDown(tester.view.reset);
    setBars(tester, keyboard: 0);
    await tester.pumpWidget(screen());
    final inputBefore = tester.getRect(find.byKey(inputKey));
    final chatBefore = tester.getRect(find.byKey(chatKey));

    setBars(tester, keyboard: 300);
    await tester.pump();
    const lift = 300.0 - 34;
    expect(tester.getRect(find.byKey(inputKey)), inputBefore.shift(Offset(0, -lift)));
    expect(tester.getRect(find.byKey(chatKey)), chatBefore.shift(Offset(0, -lift)));
    // the bar's bottom edge keeps its 6 px gap to the keyboard's top edge (800 - 300)
    expect(tester.getRect(find.byKey(inputKey)).bottom, 800 - 300 - 6);
  });

  testWidgets('the lifted input still takes focus and typing, and keeps it when the keyboard opens', (tester) async {
    addTearDown(tester.view.reset);
    setBars(tester, keyboard: 0);
    await tester.pumpWidget(screen());
    await tester.tap(find.byType(TextField));
    await tester.pump();
    setBars(tester, keyboard: 300);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'hello');
    expect(find.text('hello'), findsOneWidget);
    // tapping where it is painted now (lifted) still reaches it
    await tester.tapAt(tester.getCenter(find.byKey(inputKey)));
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);
  });

  test('keyboardLiftFor is the keyboard minus the system bar, never negative', () {
    MediaQueryData mq(double keyboard, double bar) => MediaQueryData(
          viewInsets: EdgeInsets.only(bottom: keyboard),
          viewPadding: EdgeInsets.only(bottom: bar),
        );
    expect(keyboardLiftFor(mq(0, 34)), 0);
    expect(keyboardLiftFor(mq(20, 34)), 0);
    expect(keyboardLiftFor(mq(300, 34)), 266);
    expect(keyboardLiftFor(mq(300, 0)), 300);
  });

  test('a screen that leaves more room under its input bar says so', () {
    final mq = MediaQueryData(viewInsets: const EdgeInsets.only(bottom: 300), viewPadding: const EdgeInsets.only(bottom: 34));
    expect(keyboardLiftFor(mq, restInset: 68), 232);
    expect(keyboardLiftFor(mq, restInset: 400), 0);
  });

  testWidgets('with restInset the input bar still lands just above the keyboard', (tester) async {
    addTearDown(tester.view.reset);
    // a bar that rests 2 x the system bar + 6 above the bottom, like the watch screens
    Widget screen2() => MaterialApp(
          home: Scaffold(
            resizeToAvoidBottomInset: false,
            body: Builder(builder: (context) {
              final vp = MediaQuery.viewPaddingOf(context).bottom;
              return KeyboardStable(
                restInset: 2 * vp,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 2 * vp + 6),
                    child: const KeyboardLift(child: SizedBox(key: inputKey, height: 44, width: 100)),
                  ),
                ),
              );
            }),
          ),
        );
    setBars(tester, keyboard: 0);
    await tester.pumpWidget(screen2());
    expect(tester.getRect(find.byKey(inputKey)).bottom, 800 - 68 - 6);
    setBars(tester, keyboard: 300);
    await tester.pump();
    expect(tester.getRect(find.byKey(inputKey)).bottom, 800 - 300 - 6);
  });
}
