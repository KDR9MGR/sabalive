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

  testWidgets('a mid-sized avatar (list row) shows its frame as a still', (t) async {
    expect((await frameFor(t, kFrameMinSize)).animate, isFalse);
    expect((await frameFor(t, 44)).animate, isFalse);
  });

  testWidgets('a tiny avatar (chat chip, name pill) shows no frame at all', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Center(child: AppAvatar(name: 'Sam', size: 32, frameUrl: 'https://example.test/frame.png')),
    ));
    expect(find.byType(RemoteMedia), findsNothing);
  });

  testWidgets('a large avatar (seat, profile) still plays its frame', (t) async {
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
