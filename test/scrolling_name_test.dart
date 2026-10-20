import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/features/live/widgets/seat_speaking.dart';

/// The host's name in the top-left chip of a live: a name that fits just sits there, a longer one is cut to the room it has and
/// scrolls slowly to the end and back, like the seat names do.
void main() {
  const style = TextStyle(fontSize: 12, color: Colors.white);

  /// [width] of room, offered LOOSELY (a chip gives its name "up to this much", never "exactly this much").
  Widget host(Widget child, {double width = 300}) => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: Align(alignment: Alignment.topLeft, child: child)),
      ),
    ),
  );

  testWidgets('a short name takes only its own width, so the chip stays small', (t) async {
    await t.pumpWidget(host(const ScrollingName('Riya', style: style)));
    final w = t.getSize(find.byType(ScrollingName)).width;
    expect(w, lessThan(80), reason: 'four letters, not the 300 the parent offers');
    expect(w, greaterThan(20));
    expect(find.text('Riya'), findsOneWidget);
  });

  testWidgets('a long name is cut to the room it has and scrolls to the end', (t) async {
    const name = 'Pradhyuman Offical Extra Long Name';
    await t.pumpWidget(host(const ScrollingName(name, style: style), width: 90));
    await t.pump(); // the scroll starts after the first frame
    expect(t.getSize(find.byType(ScrollingName)).width, 90, reason: 'never wider than the room it is given');

    double shift() {
      final move = find.descendant(of: find.byType(ScrollingName), matching: find.byType(Transform));
      return t.widget<Transform>(move.first).transform.getTranslation().x;
    }

    expect(shift(), 0, reason: 'it starts at the beginning of the name');
    await t.pump(const Duration(milliseconds: 4500)); // past the pause at the start
    expect(shift(), lessThan(-20), reason: 'it has moved to show the rest of the name');
    await t.pumpWidget(const SizedBox()); // the scroller's animation is stopped with the screen
  });

  testWidgets('maxWidth caps the room even when the parent offers more (the host\'s own chip: 110)', (t) async {
    await t.pumpWidget(host(const ScrollingName('A name that is far too long for a chip', style: style, maxWidth: 110)));
    await t.pump();
    expect(t.getSize(find.byType(ScrollingName)).width, 110);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('beside other parts of a chip it shrinks to what is left instead of overflowing', (t) async {
    await t.pumpWidget(host(
      Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          SizedBox(width: 40, height: 20), // the picture
          Flexible(child: ScrollingName('Pradhyuman Offical Extra Long Name', style: style)),
          SizedBox(width: 70, height: 20), // the Follow button
        ],
      ),
      width: 200,
    ));
    await t.pump();
    expect(t.takeException(), isNull, reason: 'no overflow');
    expect(t.getSize(find.byType(ScrollingName)).width, 90, reason: '200 - 40 - 70');
    await t.pumpWidget(const SizedBox());
  });
}
