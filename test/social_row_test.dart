import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/features/auth/widgets/auth_scaffold.dart';

void main() {
  Future<List<String>> pump(WidgetTester t) async {
    final taps = <String>[];
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Padding(padding: const EdgeInsets.all(24), child: SocialRow(onTap: taps.add)),
      ),
    ));
    return taps;
  }

  testWidgets('Google and Apple are full-width banners, each with its name', (t) async {
    await pump(t);
    expect(find.text('Google'), findsOneWidget);
    expect(find.text('Apple'), findsOneWidget);
    final screen = t.view.physicalSize / t.view.devicePixelRatio;
    for (final p in ['Google', 'Apple']) {
      final rect = t.getRect(find.byKey(ValueKey('social-$p')));
      expect(rect.width, closeTo(screen.width - 48, 0.5), reason: '$p spans the whole width');
      expect(rect.height, greaterThanOrEqualTo(48), reason: 'a comfortable tap target');
    }
    // stacked, Google first
    expect(t.getRect(find.byKey(const ValueKey('social-Apple'))).top, greaterThan(t.getRect(find.byKey(const ValueKey('social-Google'))).bottom));
  });

  testWidgets('tapping a banner reports its provider', (t) async {
    final taps = await pump(t);
    await t.tap(find.text('Google'));
    await t.tap(find.text('Apple'));
    expect(taps, ['Google', 'Apple']);
  });
}
