import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/features/release/update_required_gate.dart';
import 'package:sabalive/state/remote_config_controller.dart';

Map<String, dynamic> row({int android = 0, int ios = 0, String message = '', Object? flags}) => {
      'min_android_version_code': android,
      'min_ios_build': ios,
      'update_message': message,
      'android_store_url': 'https://play.google.com/store/apps/details?id=com.sabalive.in',
      'ios_store_url': '',
      'feature_flags': flags ?? <String, dynamic>{},
    };

RemoteConfigController controller(
  Future<Map<String, dynamic>?> Function() fetch, {
  int build = 7,
  bool ios = false,
  DateTime Function()? clock,
}) =>
    RemoteConfigController(fetch: fetch, buildNumber: () async => build, isIos: ios, clock: clock);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReleaseConfig', () {
    test('reads the numbers, texts and boolean switches (other values are ignored)', () {
      final c = ReleaseConfig.fromRow(row(
        android: 8,
        ios: 12,
        message: ' Please update ',
        flags: {'animated_frames': false, 'speaking_waves': true, 'junk': 'yes', 'n': 3},
      ));
      expect(c.minAndroid, 8);
      expect(c.minIos, 12);
      expect(c.message, 'Please update');
      expect(c.flags, {'animated_frames': false, 'speaking_waves': true});
    });

    test('an empty or broken row means no minimum and no switches', () {
      final c = ReleaseConfig.fromRow({'min_android_version_code': null, 'feature_flags': 'oops'});
      expect(c.minAndroid, 0);
      expect(c.flags, isEmpty);
      expect(c.requiresUpdate(buildNumber: 1, isIos: false), isFalse);
    });

    test('only a build BELOW the minimum is blocked, per platform', () {
      const c = ReleaseConfig(minAndroid: 8, minIos: 20);
      expect(c.requiresUpdate(buildNumber: 7, isIos: false), isTrue);
      expect(c.requiresUpdate(buildNumber: 8, isIos: false), isFalse);
      expect(c.requiresUpdate(buildNumber: 9, isIos: false), isFalse);
      expect(c.requiresUpdate(buildNumber: 19, isIos: true), isTrue);
      expect(c.requiresUpdate(buildNumber: 20, isIos: true), isFalse);
    });

    test('an unreadable build number (0) is never blocked', () {
      expect(const ReleaseConfig(minAndroid: 8).requiresUpdate(buildNumber: 0, isIos: false), isFalse);
    });
  });

  group('RemoteConfigController', () {
    test('a build below the server minimum must update', () async {
      final c = controller(() async => row(android: 8), build: 7);
      await c.start();
      expect(c.updateRequired, isTrue);
      expect(c.storeUrl, contains('play.google.com'));
    });

    test('a current build is left alone', () async {
      final c = controller(() async => row(android: 8), build: 8);
      await c.start();
      expect(c.updateRequired, isFalse);
    });

    test('FAILS OPEN: an unreachable server, or missing columns, block nothing and keep every default', () async {
      final c = controller(() async => throw Exception('network down'), build: 1);
      await c.start();
      expect(c.updateRequired, isFalse);
      expect(c.flag('animated_frames'), isTrue);
      expect(c.flag('something_new', defaultValue: false), isFalse);
    });

    test('a null row (nothing configured) changes nothing', () async {
      final c = controller(() async => null);
      await c.start();
      expect(c.updateRequired, isFalse);
    });

    test('a switch turned off on the server is off in the app', () async {
      final c = controller(() async => row(flags: {'animated_frames': false}));
      await c.start();
      expect(c.flag('animated_frames'), isFalse);
      expect(c.flag('speaking_waves'), isTrue, reason: 'an absent key keeps the default');
    });

    test('listeners hear about a change, not about an identical re-read', () async {
      var now = DateTime(2026, 10, 6, 12);
      var data = row(android: 0);
      final c = controller(() async => data, clock: () => now);
      await c.start();
      var heard = 0;
      c.addListener(() => heard++);

      now = now.add(const Duration(minutes: 6));
      await c.refresh();
      expect(heard, 0, reason: 'same values');

      data = row(android: 9);
      now = now.add(const Duration(minutes: 6));
      await c.refresh();
      expect(heard, 1);
    });

    test('re-reads are throttled (one small read per launch or resume, not a poll)', () async {
      var reads = 0;
      var now = DateTime(2026, 10, 6, 12);
      final c = controller(() async {
        reads++;
        return row();
      }, clock: () => now);
      await c.start();
      expect(reads, 1);
      await c.refresh();
      now = now.add(const Duration(minutes: 1));
      await c.refresh();
      expect(reads, 1, reason: 'inside the 5 minute gap');
      now = now.add(const Duration(minutes: 5));
      await c.refresh();
      expect(reads, 2);
      await c.refresh(force: true);
      expect(reads, 3);
    });
  });

  group('UpdateRequiredGate', () {
    Future<RemoteConfigController> pump(WidgetTester t, Map<String, dynamic> data, {int build = 7, StoreLauncher? launcher}) async {
      final c = controller(() async => data, build: build);
      await t.runAsync(c.start);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: UpdateRequiredGate(
          controller: c,
          launcher: launcher ?? (_) async => true,
          child: const Scaffold(body: Text('the app')),
        ),
      ));
      return c;
    }

    testWidgets('no minimum: the app is just there', (t) async {
      await pump(t, row());
      expect(find.text('the app'), findsOneWidget);
      expect(find.text('Update required'), findsNothing);
    });

    testWidgets('an old build is covered by the update screen with the default text', (t) async {
      await pump(t, row(android: 8));
      expect(find.text('Update required'), findsOneWidget);
      expect(find.text(UpdateRequiredScreen.defaultMessage), findsOneWidget);
      expect(find.text('Update now'), findsOneWidget);
    });

    testWidgets('the Super Admin\'s own message is shown, and the button opens the store', (t) async {
      Uri? opened;
      await pump(t, row(android: 8, message: 'Version 8 fixes live rooms.'), launcher: (u) async {
        opened = u;
        return true;
      });
      expect(find.text('Version 8 fixes live rooms.'), findsOneWidget);
      await t.tap(find.text('Update now'));
      expect(opened.toString(), contains('play.google.com'));
    });

    testWidgets('a current build never sees it', (t) async {
      await pump(t, row(android: 8), build: 8);
      expect(find.text('Update required'), findsNothing);
    });
  });
}
