import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/widgets/app_avatar.dart';
import 'package:sabalive/core/widgets/remote_media.dart';

void main() {
  Future<RemoteMedia> frameFor(WidgetTester t, double size) async {
    await t.pumpWidget(MaterialApp(
      home: Center(
        child: AppAvatar(name: 'Sam', size: size, frameUrl: 'https://example.test/frame.png'),
      ),
    ));
    return t.widget<RemoteMedia>(find.byType(RemoteMedia));
  }

  testWidgets('a small avatar (chat row, list) shows its frame as a still', (t) async {
    expect((await frameFor(t, 28)).animate, isFalse);
    expect((await frameFor(t, 40)).animate, isFalse);
  });

  testWidgets('a large avatar (seat, profile) still plays its frame', (t) async {
    expect((await frameFor(t, kAnimatedFrameMinSize)).animate, isTrue);
    expect((await frameFor(t, 72)).animate, isTrue);
  });

  testWidgets('an audio-room seat (a 58 px circle, 54 px avatar) keeps its animated frame', (t) async {
    expect(58 - 4, greaterThanOrEqualTo(kAnimatedFrameMinSize));
    expect((await frameFor(t, 58 - 4)).animate, isTrue);
  });
}
