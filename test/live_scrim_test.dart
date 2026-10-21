import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/features/live/widgets/live_scrim.dart';

/// The viewer's tap on the other host's frame in a PK battle never arrived: a plain DecoratedBox gradient over the video caught it. The
/// scrim is paint only.
void main() {
  Future<int> tapUnder(WidgetTester t, Widget scrim) async {
    var taps = 0;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(key: const ValueKey('frame'), behavior: HitTestBehavior.opaque, onTap: () => taps++, child: const ColoredBox(color: Colors.blue)),
            scrim,
          ],
        ),
      ),
    ));
    await t.tapAt(const Offset(200, 300));
    return taps;
  }

  testWidgets('a tap goes through the scrim to what is under it', (t) async {
    expect(await tapUnder(t, const LiveScrim()), 1);
  });

  testWidgets('(why it exists) a plain decorated gradient in its place catches the tap', (t) async {
    const plain = DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.black54, Colors.transparent])));
    expect(await tapUnder(t, plain), 0);
  });

  testWidgets('it still paints the gradient', (t) async {
    await tapUnder(t, const LiveScrim());
    final box = t.widget<DecoratedBox>(find.descendant(of: find.byType(LiveScrim), matching: find.byType(DecoratedBox)));
    expect((box.decoration as BoxDecoration).gradient, isA<LinearGradient>());
  });
}
