import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/join_banner.dart';

JoinBanner _b(String name) => JoinBanner(imageUrl: 'https://x.co/$name.png', name: name);

void main() {
  group('JoinBannerController', () {
    test('plays one at a time, in order, each in its own turn', () {
      final c = JoinBannerController();
      c.add(_b('A'));
      c.add(_b('B'));
      expect(c.current?.name, 'A');
      c.finish(c.playId);
      expect(c.current?.name, 'B');
      c.finish(c.playId);
      expect(c.current, isNull);
      c.dispose();
    });

    test('a busy room keeps only the latest waiting, and shows them shorter', () {
      final c = JoinBannerController(maxQueued: 3, hurryAt: 1);
      for (final n in ['A', 'B', 'C', 'D', 'E', 'F']) {
        c.add(_b(n));
      }
      expect(c.current?.name, 'A');
      c.finish(c.playId);
      expect(c.current?.name, 'D', reason: 'B and C were dropped, the newest three waited');
      expect(c.currentDuration, c.hold * 0.6, reason: 'with others still waiting each one is shorter');
      c.dispose();
    });

    test('a lone arrival gets the full time', () {
      final c = JoinBannerController();
      c.add(_b('A'));
      expect(c.currentDuration, c.hold);
      c.dispose();
    });

    test('a late finish for an earlier banner is ignored', () {
      final c = JoinBannerController();
      c.add(_b('A'));
      final first = c.playId;
      c.finish(first);
      c.add(_b('B'));
      c.finish(first);
      expect(c.current?.name, 'B');
      c.dispose();
    });
  });

  group('JoinBannerLayer', () {
    Widget host(JoinBannerController c) => MaterialApp(home: Scaffold(body: JoinBannerLayer(controller: c)));

    testWidgets('shows a strip with the name and "joined", far smaller than the screen', (t) async {
      final c = JoinBannerController();
      await t.pumpWidget(host(c));
      expect(find.text('Asha'), findsNothing);
      c.add(JoinBanner(
        imageUrl: 'https://x.co/lv.png',
        name: 'Asha',
        who: AppUser(id: 'u', name: 'Asha', username: '@a', wealthLevel: 5, charmLevel: 2),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 600)); // slid in
      expect(find.text('Asha'), findsOneWidget);
      expect(find.text('joined'), findsOneWidget);
      final strip = t.getRect(find.byType(Container).first);
      final screen = t.view.physicalSize / t.view.devicePixelRatio;
      expect(strip.height, lessThan(screen.height * 0.2), reason: 'a strip, not the whole screen');
      c.dispose();
    });

    testWidgets('slides out and the next one comes', (t) async {
      final c = JoinBannerController(hold: const Duration(milliseconds: 500));
      await t.pumpWidget(host(c));
      c.add(_b('Alice'));
      c.add(_b('Bob'));
      await t.pump();
      expect(find.text('Alice'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 520));
      await t.pump();
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Alice'), findsNothing);
      await t.pump(const Duration(seconds: 2));
      await t.pump();
      expect(c.current, isNull);
      c.dispose();
    });
  });
}
