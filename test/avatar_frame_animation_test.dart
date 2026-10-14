import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/widgets/app_avatar.dart';
import 'package:sabalive/core/widgets/remote_media.dart';
import 'package:sabalive/features/live/widgets/seat_room.dart';

void main() {
  Future<RemoteMedia> frameFor(WidgetTester t, double size) async {
    await t.pumpWidget(MaterialApp(
      home: Center(
        child: AppAvatar(name: 'Sam', size: size, frameUrl: 'https://example.test/frame.png'),
      ),
    ));
    return t.widget<RemoteMedia>(find.byType(RemoteMedia));
  }

  testWidgets('a small avatar (list row, chat chip, name pill) shows its plain picture, no frame', (t) async {
    // the picture sits at 57% of a framed box, so below kFrameMinSize it would be a speck inside a smudge of frame
    for (final size in [kFrameMinSize - 1, 44.0, 32.0]) {
      await t.pumpWidget(MaterialApp(
        home: Center(child: AppAvatar(name: 'Sam', size: size, frameUrl: 'https://example.test/frame.png')),
      ));
      expect(find.byType(RemoteMedia), findsNothing, reason: 'size $size');
    }
  });

  testWidgets('every avatar that does show a frame plays it', (t) async {
    expect(kFrameMinSize, lessThanOrEqualTo(kAnimatedFrameMinSize), reason: 'no frame is drawn as a mere still');
    expect((await frameFor(t, kFrameMinSize)).animate, isTrue);
    expect((await frameFor(t, kAnimatedFrameMinSize)).animate, isTrue);
    expect((await frameFor(t, 72)).animate, isTrue);
  });

  testWidgets('an audio-room seat keeps its animated frame', (t) async {
    // a seat's avatar + frame take about 76 px of its cell
    final footprint = SeatCircle.footprintOf(plain: 56, framed: true, slot: 76);
    expect(footprint, greaterThanOrEqualTo(kAnimatedFrameMinSize));
    expect((await frameFor(t, footprint)).animate, isTrue);
  });
}
