import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/widgets/keyboard_lift.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/chat_composer.dart';

/// The live screens lay the composer out in a column and PAINT it higher while the keyboard is up (KeyboardLift). The Send button
/// must still take the tap at its painted place, and the first tap must send AND close the keyboard.
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

  void setBars(WidgetTester t, {required double keyboard}) {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(400, 800);
    t.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
    t.view.padding = FakeViewPadding(top: 24, bottom: keyboard > 34 ? 0 : 34 - keyboard);
    t.view.viewInsets = FakeViewPadding(bottom: keyboard);
  }

  // the audio viewer's structure: a stage that takes the rest, the lifted composer, the system bar; and above them in the Stack the
  // overlays the screen has (a hearts lane on the right edge, the effects layer that ignores touches)
  Widget screen() => MaterialApp(
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: Stack(
            children: [
              KeyboardStable(
                restInset: 2 * 34,
                child: SafeArea(
                  child: Column(
                    children: [
                      const Expanded(child: SizedBox.expand()),
                      const SizedBox(height: 10),
                      KeyboardLift(
                        child: LiveChatComposer(
                          controller: controller,
                          focusNode: focus,
                          onSend: () {
                            sent++;
                            controller.clear();
                          },
                          people: () => <AppUser>[],
                          leading: const [Icon(Icons.more_horiz_rounded), Icon(Icons.emoji_emotions_outlined)],
                        ),
                      ),
                      const SizedBox(height: 34 + 6),
                    ],
                  ),
                ),
              ),
              Positioned(right: 6, bottom: 140, width: 60, height: 320, child: Stack(children: const [])),
              const Positioned.fill(child: IgnorePointer(child: SizedBox.expand())),
            ],
          ),
        ),
      );

  testWidgets('with the keyboard up, tapping the lifted Send button sends once and closes the keyboard', (t) async {
    addTearDown(t.view.reset);
    setBars(t, keyboard: 0);
    await t.pumpWidget(screen());
    await t.tap(find.byType(TextField));
    await t.pump();
    setBars(t, keyboard: 300);
    await t.pump();
    await t.enterText(find.byType(TextField), 'hello');
    await t.pump();
    expect(focus.hasFocus, isTrue);
    final restingTop = 800 - 34 - 40 - 42.0; // where the bar sits with no keyboard
    expect(t.getRect(find.byIcon(Icons.send_rounded)).top, lessThan(restingTop - 100), reason: 'the bar really is lifted');

    await t.tap(find.byIcon(Icons.send_rounded));
    await t.pump();
    expect(sent, 1, reason: 'the first tap on the lifted Send button sends');
    expect(focus.hasFocus, isFalse, reason: 'and puts the keyboard away');
  });
}
