import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/banners_repository.dart';
import 'package:sabalive/features/home/widgets/banner_carousel.dart';

PromoBanner banner(String t) =>
    PromoBanner(id: t, title: t, imageUrl: 'https://x/$t.png');

Widget host(
  List<PromoBanner> banners,
  Future<Duration> Function() load, {
  Duration refresh = const Duration(minutes: 5),
}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 300,
          height: 120,
          child: BannerCarousel(
            banners: banners,
            loadInterval: load,
            refreshEvery: refresh,
            itemBuilder: (_, b) => Center(child: Text(b.title)),
          ),
        ),
      ),
    );

void main() {
  final three = [banner('A'), banner('B'), banner('C')];
  Future<Duration> every(int s) async => Duration(seconds: s);

  testWidgets('slides to the next banner after the interval (20s)', (t) async {
    await t.pumpWidget(host(three, () => every(20)));
    await t.pump();
    expect(find.text('A'), findsOneWidget);

    await t.pump(const Duration(seconds: 19));
    expect(find.text('A'), findsOneWidget, reason: 'not yet — 19s of 20');

    await t.pump(const Duration(seconds: 1));
    await t.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('keeps going and wraps from the last banner back to the first',
      (t) async {
    await t.pumpWidget(host(three, () => every(20)));
    await t.pump();
    for (final expected in ['B', 'C', 'A', 'B']) {
      await t.pump(const Duration(seconds: 20));
      await t.pumpAndSettle();
      expect(find.text(expected), findsOneWidget, reason: 'slid to $expected');
    }
  });

  testWidgets('honours a different interval from the panel', (t) async {
    await t.pumpWidget(host(three, () => every(5)));
    await t.pump();
    await t.pump(const Duration(seconds: 5));
    await t.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('a panel change shows up on the next refresh, without a restart',
      (t) async {
    var seconds = 20;
    await t.pumpWidget(host(three, () => every(seconds),
        refresh: const Duration(minutes: 1)));
    await t.pump();

    seconds = 4; // panel: 20 -> 4
    await t.pump(const Duration(minutes: 1)); // refresh happens here
    await t.pumpAndSettle();
    final before = find.text('A').evaluate().isNotEmpty ? 'A' : 'other';

    await t.pump(const Duration(seconds: 4));
    await t.pumpAndSettle();
    // one more slide within 4s proves the new interval is in force
    expect(find.text(before), findsNothing);
  });

  testWidgets('waits while a finger is on it, then starts a fresh countdown',
      (t) async {
    await t.pumpWidget(host(three, () => every(20)));
    await t.pump();
    await t.pump(const Duration(seconds: 15));

    final finger = await t.startGesture(const Offset(150, 60));
    await t.pump(const Duration(seconds: 10)); // 25s elapsed in total: would have slid
    expect(find.text('A'), findsOneWidget, reason: 'held — must not slide');

    await finger.up();
    await t.pump(const Duration(seconds: 19));
    expect(find.text('A'), findsOneWidget, reason: 'fresh 20s not up yet');
    await t.pump(const Duration(seconds: 1));
    await t.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('one banner never slides; none shows nothing', (t) async {
    await t.pumpWidget(host([banner('Solo')], () => every(5)));
    await t.pump();
    await t.pump(const Duration(seconds: 30));
    await t.pumpAndSettle();
    expect(find.text('Solo'), findsOneWidget);

    await t.pumpWidget(host(const [], () => every(5)));
    await t.pump();
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('if the setting cannot be read it still slides, at 20 seconds',
      (t) async {
    await t.pumpWidget(host(three, () async => defaultBannerInterval));
    await t.pump();
    await t.pump(const Duration(seconds: 20));
    await t.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('disposes cleanly while a slide timer is running', (t) async {
    await t.pumpWidget(host(three, () => every(20)));
    await t.pump();
    await t.pumpWidget(const SizedBox());
    expect(t.takeException(), isNull);
  });

  group('clampBannerInterval', () {
    test('defaults, and keeps the value inside 3..600 seconds', () {
      expect(clampBannerInterval(null), const Duration(seconds: 20));
      expect(clampBannerInterval(20), const Duration(seconds: 20));
      expect(clampBannerInterval(1), const Duration(seconds: 3));
      expect(clampBannerInterval(9999), const Duration(seconds: 600));
    });
  });
}
