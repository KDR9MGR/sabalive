import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sabalive/data/system_status_repository.dart';
import 'package:sabalive/features/maintenance/maintenance_banner.dart';
import 'package:sabalive/features/maintenance/maintenance_screen.dart';
import 'package:sabalive/services/maintenance_http_client.dart';
import 'package:sabalive/state/maintenance_controller.dart';
import 'package:sabalive/core/i18n/text.dart' as i18n;

/// Stands in for the server: whatever status it is told to return.
class _FakeRepo extends SystemStatusRepository {
  SystemStatus next = SystemStatus.online;
  bool fail = false;
  int fetches = 0;

  @override
  Future<SystemStatus> fetch() async {
    fetches++;
    if (fail) throw Exception('offline');
    return next;
  }

  @override
  watch(void Function() onChange) => throw UnimplementedError('no realtime in tests');
}

SystemStatus _status(
  String status, {
  DateTime? serverTime,
  DateTime? endsAt,
  DateTime? startsAt,
  bool lockApp = true,
  bool blockLogins = true,
  String title = 'Upgrading',
  String message = 'Back soon',
  int version = 1,
  String? image,
}) => SystemStatus(
  status: status,
  title: title,
  message: message,
  serverTime: serverTime ?? DateTime.utc(2026, 10, 3, 6, 0),
  endsAt: endsAt,
  startsAt: startsAt,
  lockApp: lockApp,
  blockLogins: blockLogins,
  appSessionVersion: version,
  imageUrl: image,
);

void main() {
  final serverNow = DateTime.utc(2026, 10, 3, 6, 0);

  group('SystemStatus', () {
    test('reads what get_system_status returns', () {
      final s = SystemStatus.fromJson({
        'status': 'maintenance', 'title': 'Upgrading', 'message': 'Back soon',
        'image_url': 'https://x.co/m.png', 'starts_at': null, 'ends_at': '2026-10-03T06:30:00+00:00',
        'auto_end': true, 'lock_app': true, 'block_logins': false, 'lock_panel': true,
        'app_session_version': 4, 'server_time': '2026-10-03T06:00:00.123+00:00',
      });
      expect(s.status, 'maintenance');
      expect(s.endsAt, DateTime.utc(2026, 10, 3, 6, 30));
      expect(s.autoEnd, isTrue);
      expect(s.blockLogins, isFalse);
      expect(s.lockPanel, isTrue);
      expect(s.appSessionVersion, 4);
      expect(s.imageUrl, 'https://x.co/m.png');
    });

    test('a blank image means none; a missing field falls back to a safe default', () {
      expect(SystemStatus.fromJson({'status': 'maintenance', 'image_url': '  '}).imageUrl, isNull);
      final s = SystemStatus.fromJson({});
      expect(s.status, 'online');
      expect(s.locksApp, isFalse);
    });

    test('maintenance locks the app; so does a lockdown; online and upcoming do not', () {
      expect(_status('maintenance').locksApp, isTrue);
      expect(_status('lockdown').locksApp, isTrue);
      expect(_status('online').locksApp, isFalse);
      expect(_status('upcoming').locksApp, isFalse);
    });

    test('with lock_app off, maintenance is only a notice (and may still block sign-in)', () {
      final soft = _status('maintenance', lockApp: false, blockLogins: true);
      expect(soft.locksApp, isFalse);
      expect(soft.showsNotice, isTrue);
      expect(soft.blocksLogins, isTrue);
      expect(_status('maintenance', lockApp: false, blockLogins: false).blocksLogins, isFalse);
    });

    test('a scheduled maintenance shows a notice but blocks nothing yet', () {
      final up = _status('upcoming');
      expect(up.showsNotice, isTrue);
      expect(up.blocksLogins, isFalse);
      expect(_status('online').showsNotice, isFalse);
      expect(_status('maintenance').showsNotice, isFalse, reason: 'the full lock shows the screen instead');
    });

    test('the server refusing a request is treated as a full lock', () {
      final s = SystemStatus.fromGateDetails({'status': 'lockdown', 'title': 'Emergency maintenance', 'message': 'Urgent', 'server_time': '2026-10-03T06:00:00Z'});
      expect(s.locksApp, isTrue);
      expect(s.isLockdown, isTrue);
      expect(s.title, 'Emergency maintenance');
    });
  });

  group('countdown runs from the server clock', () {
    test('a phone clock an hour fast still counts down to the server\'s end time', () {
      final repo = _FakeRepo();
      // the phone thinks it is 07:00, the server says it is 06:00
      final c = MaintenanceController(repo: repo, clock: () => DateTime.utc(2026, 10, 3, 7, 0));
      c.apply(_status('maintenance', serverTime: serverNow, endsAt: DateTime.utc(2026, 10, 3, 6, 30)));
      expect(c.remaining(), const Duration(minutes: 30), reason: 'not -30 minutes');
      expect(c.overdue, isFalse);
      c.dispose();
    });

    test('a phone clock behind works the same way', () {
      final c = MaintenanceController(repo: _FakeRepo(), clock: () => DateTime.utc(2026, 10, 3, 5, 0));
      c.apply(_status('maintenance', serverTime: serverNow, endsAt: DateTime.utc(2026, 10, 3, 6, 42, 18)));
      expect(formatCountdown(c.remaining()!), '00:42:18');
      c.dispose();
    });

    test('the countdown moves as time passes', () {
      var now = DateTime.utc(2026, 10, 3, 6, 0);
      final c = MaintenanceController(repo: _FakeRepo(), clock: () => now);
      c.apply(_status('maintenance', serverTime: now, endsAt: DateTime.utc(2026, 10, 3, 6, 1)));
      expect(c.remaining(), const Duration(minutes: 1));
      now = now.add(const Duration(seconds: 45));
      expect(c.remaining(), const Duration(seconds: 15));
      c.dispose();
    });

    test('when the timer reaches zero but maintenance is still on, it says so', () {
      var now = DateTime.utc(2026, 10, 3, 6, 0);
      final c = MaintenanceController(repo: _FakeRepo(), clock: () => now);
      c.apply(_status('maintenance', serverTime: now, endsAt: DateTime.utc(2026, 10, 3, 6, 1)));
      now = now.add(const Duration(minutes: 5));
      expect(c.remaining(), Duration.zero, reason: 'never negative');
      expect(c.overdue, isTrue);
      expect(c.locked, isTrue, reason: 'still locked until the Super Admin ends it');
      c.dispose();
    });

    test('an extended end time is picked up', () {
      final c = MaintenanceController(repo: _FakeRepo(), clock: () => serverNow);
      c.apply(_status('maintenance', serverTime: serverNow, endsAt: DateTime.utc(2026, 10, 3, 6, 5)));
      expect(c.remaining(), const Duration(minutes: 5));
      c.apply(_status('maintenance', serverTime: serverNow, endsAt: DateTime.utc(2026, 10, 3, 7, 0)));
      expect(c.remaining(), const Duration(hours: 1));
      c.dispose();
    });

    test('no end time (or a lockdown) means no countdown', () {
      final c = MaintenanceController(repo: _FakeRepo(), clock: () => serverNow);
      c.apply(_status('maintenance', serverTime: serverNow));
      expect(c.remaining(), isNull);
      c.apply(_status('lockdown', serverTime: serverNow, endsAt: DateTime.utc(2026, 10, 3, 7)));
      expect(c.remaining(), isNull);
      c.dispose();
    });

    test('time until a scheduled start', () {
      final c = MaintenanceController(repo: _FakeRepo(), clock: () => serverNow);
      c.apply(_status('upcoming', serverTime: serverNow, startsAt: DateTime.utc(2026, 10, 3, 6, 15)));
      expect(c.untilStart(), const Duration(minutes: 15));
      expect(c.locked, isFalse);
      c.dispose();
    });
  });

  group('controller', () {
    test('locks and unlocks as the server status changes, telling listeners once each', () async {
      final repo = _FakeRepo();
      final c = MaintenanceController(repo: repo, clock: () => serverNow);
      var notified = 0;
      c.addListener(() => notified++);
      repo.next = _status('maintenance');
      await c.refresh();
      expect(c.locked, isTrue);
      await c.refresh(); // no change
      expect(notified, 1);
      repo.next = _status('online');
      await c.refresh();
      expect(c.locked, isFalse);
      expect(notified, 2);
      c.dispose();
    });

    test('offline: the last known status stays (a locked phone does not unlock itself)', () async {
      final repo = _FakeRepo()..next = _status('maintenance');
      final c = MaintenanceController(repo: repo, clock: () => serverNow);
      await c.refresh();
      repo.fail = true;
      await c.refresh();
      expect(c.locked, isTrue);
      c.dispose();
    });

    test('a request refused by the server locks at once, before any re-read', () async {
      final repo = _FakeRepo(); // still says online
      final c = MaintenanceController(repo: repo, clock: () => serverNow);
      c.reportRefused({'status': 'maintenance', 'title': 'Upgrading', 'message': 'Back soon', 'ends_at': '2026-10-03T06:30:00Z', 'server_time': '2026-10-03T06:00:00Z'});
      expect(c.locked, isTrue);
      expect(c.remaining(), const Duration(minutes: 30));
      c.dispose();
    });

    test('start() reads once, polls on a timer, and re-reads when the app resumes', () async {
      final repo = _FakeRepo();
      final c = MaintenanceController(repo: repo, clock: () => serverNow, pollEvery: const Duration(milliseconds: 40));
      TestWidgetsFlutterBinding.ensureInitialized();
      await c.start();
      expect(repo.fetches, 1);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(repo.fetches, greaterThanOrEqualTo(3), reason: 'polling');
      final before = repo.fetches;
      c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(repo.fetches, greaterThan(before), reason: 'resume re-checks');
      c.dispose();
    });

    test('knows when logins are blocked', () async {
      final repo = _FakeRepo()..next = _status('maintenance', lockApp: false, blockLogins: true);
      final c = MaintenanceController(repo: repo, clock: () => serverNow);
      await c.refresh();
      expect(c.locked, isFalse);
      expect(c.loginsBlocked, isTrue);
      c.dispose();
    });
  });

  group('formatting', () {
    test('countdown is hh:mm:ss and never negative', () {
      expect(formatCountdown(const Duration(hours: 1, minutes: 2, seconds: 3)), '01:02:03');
      expect(formatCountdown(const Duration(seconds: 59)), '00:00:59');
      expect(formatCountdown(Duration.zero), '00:00:00');
      expect(formatCountdown(const Duration(seconds: -5)), '00:00:00');
      expect(formatCountdown(const Duration(hours: 26)), '26:00:00');
    });

    test('expected completion is a clock time today, with the date otherwise', () {
      final now = DateTime(2026, 10, 3, 5, 0);
      expect(formatExpectedCompletion(DateTime(2026, 10, 3, 6, 30), now), '6:30 AM');
      expect(formatExpectedCompletion(DateTime(2026, 10, 3, 14, 5), now), '2:05 PM');
      expect(formatExpectedCompletion(DateTime(2026, 10, 3, 0, 15), now), '12:15 AM');
      expect(formatExpectedCompletion(DateTime(2026, 10, 3, 12, 0), now), '12:00 PM');
      expect(formatExpectedCompletion(DateTime(2026, 10, 4, 6, 30), now), '4 Oct, 6:30 AM');
    });
  });

  group('maintenance-aware HTTP client', () {
    final gateBody = jsonEncode({
      'code': 'PT503',
      'message': 'MAINTENANCE_MODE',
      'hint': 'The system is under maintenance',
      'details': jsonEncode({'status': 'maintenance', 'title': 'Upgrading', 'message': 'Back soon', 'ends_at': '2026-10-03T06:30:00Z'}),
    });

    Future<(http.Response, List<Map<dynamic, dynamic>>)> call(int status, String body) async {
      final refused = <Map<dynamic, dynamic>>[];
      final client = MaintenanceAwareClient(
        MockClient((_) async => http.Response(body, status, headers: {'content-type': 'application/json'})),
        refused.add,
      );
      final res = await http.Response.fromStream(await client.send(http.Request('GET', Uri.parse('https://x.co/rest/v1/profiles'))));
      return (res, refused);
    }

    test('a refusal is reported with its details, and passed on unchanged', () async {
      final (res, refused) = await call(503, gateBody);
      expect(refused, hasLength(1));
      expect(refused.single['status'], 'maintenance');
      expect(refused.single['title'], 'Upgrading');
      expect(res.statusCode, 503);
      expect(res.body, gateBody);
      expect(res.headers['content-type'], 'application/json');
    });

    test('an ordinary 503 is not mistaken for maintenance', () async {
      final (res, refused) = await call(503, '{"message":"upstream down"}');
      expect(refused, isEmpty);
      expect(res.statusCode, 503);
      expect(res.body, '{"message":"upstream down"}');
    });

    test('other responses are untouched', () async {
      final (res, refused) = await call(200, '[{"id":1}]');
      expect(refused, isEmpty);
      expect(res.body, '[{"id":1}]');
    });

    test('parseMaintenanceRefusal copes with every shape', () {
      expect(parseMaintenanceRefusal(gateBody)!['title'], 'Upgrading');
      expect(parseMaintenanceRefusal(jsonEncode({'message': 'MAINTENANCE_MODE', 'details': {'status': 'lockdown'}}))!['status'], 'lockdown');
      expect(parseMaintenanceRefusal(jsonEncode({'message': 'MAINTENANCE_MODE'}))!['status'], 'maintenance',
          reason: 'refused without details is still maintenance');
      expect(parseMaintenanceRefusal('not json'), isNull);
      expect(parseMaintenanceRefusal('[]'), isNull);
      expect(parseMaintenanceRefusal('{"message":"other"}'), isNull);
    });
  });

  group('maintenance screen', () {
    Future<MaintenanceController> pump(WidgetTester t, SystemStatus s, {DateTime? now, _FakeRepo? repo}) async {
      final clock = now ?? serverNow;
      final c = MaintenanceController(repo: repo ?? _FakeRepo(), clock: () => clock);
      c.apply(s);
      await t.pumpWidget(MaterialApp(home: MaintenanceScreen(controller: c)));
      return c;
    }

    testWidgets('shows the title, the message, the countdown and the expected completion', (t) async {
      final c = await pump(t, _status('maintenance', endsAt: DateTime.utc(2026, 10, 3, 6, 42, 18)));
      expect(find.text('Upgrading'), findsOneWidget);
      expect(find.text('Back soon'), findsOneWidget);
      expect(find.byKey(const Key('maintenance-countdown')), findsOneWidget);
      expect(t.widget<i18n.Text>(find.byKey(const Key('maintenance-countdown'))).data, '00:42:18');
      expect(find.textContaining('Expected completion:'), findsOneWidget);
      c.dispose();
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('the countdown ticks down by itself', (t) async {
      var now = serverNow;
      final c = MaintenanceController(repo: _FakeRepo(), clock: () => now);
      c.apply(_status('maintenance', serverTime: now, endsAt: now.add(const Duration(minutes: 10))));
      await t.pumpWidget(MaterialApp(home: MaintenanceScreen(controller: c)));
      expect(t.widget<i18n.Text>(find.byKey(const Key('maintenance-countdown'))).data, '00:10:00');
      now = now.add(const Duration(seconds: 3));
      await t.pump(const Duration(seconds: 1));
      expect(t.widget<i18n.Text>(find.byKey(const Key('maintenance-countdown'))).data, '00:09:57');
      c.dispose();
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('past the end time it says it is taking longer, with no negative timer', (t) async {
      final c = await pump(t, _status('maintenance', endsAt: DateTime.utc(2026, 10, 3, 5, 59)));
      expect(find.byKey(const Key('maintenance-overdue')), findsOneWidget);
      expect(find.byKey(const Key('maintenance-countdown')), findsNothing);
      c.dispose();
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('a lockdown shows no countdown', (t) async {
      final c = await pump(t, _status('lockdown', title: 'Emergency maintenance', message: 'Urgent issue', endsAt: DateTime.utc(2026, 10, 3, 7)));
      expect(find.text('Emergency maintenance'), findsOneWidget);
      expect(find.text('Urgent issue'), findsOneWidget);
      expect(find.byKey(const Key('maintenance-countdown')), findsNothing);
      c.dispose();
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('with no end time there is just the message', (t) async {
      final c = await pump(t, _status('maintenance'));
      expect(find.byKey(const Key('maintenance-countdown')), findsNothing);
      expect(find.byKey(const Key('maintenance-overdue')), findsNothing);
      c.dispose();
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('"Check again" asks the server, and the screen can then go away', (t) async {
      final repo = _FakeRepo()..next = _status('maintenance');
      final c = await pump(t, _status('maintenance'), repo: repo);
      repo.next = _status('online');
      await t.tap(find.text('Check again'));
      await t.pump();
      await t.pump();
      expect(repo.fetches, 1);
      expect(c.locked, isFalse, reason: 'the overlay in app.dart removes the screen when this turns false');
      c.dispose();
      await t.pumpWidget(const SizedBox());
    });
  });

  group('maintenance banner', () {
    Future<MaintenanceController> pump(WidgetTester t, SystemStatus s) async {
      final c = MaintenanceController(repo: _FakeRepo(), clock: () => serverNow);
      c.apply(s);
      await t.pumpWidget(MaterialApp(home: Scaffold(body: MaintenanceBanner(controller: c))));
      return c;
    }

    testWidgets('counts down to a scheduled start', (t) async {
      final c = await pump(t, _status('upcoming', startsAt: DateTime.utc(2026, 10, 3, 6, 14, 32)));
      expect(find.text('Maintenance starts in 00:14:32'), findsOneWidget);
      c.dispose();
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('during a soft maintenance it shows the time left', (t) async {
      final c = await pump(t, _status('maintenance', lockApp: false, endsAt: DateTime.utc(2026, 10, 3, 6, 5)));
      expect(find.text('Maintenance in progress · 00:05:00 left'), findsOneWidget);
      c.dispose();
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('never takes taps', (t) async {
      final c = await pump(t, _status('upcoming', startsAt: DateTime.utc(2026, 10, 3, 7)));
      expect(find.ancestor(of: find.byKey(const Key('maintenance-banner')), matching: find.byType(IgnorePointer)), findsWidgets);
      c.dispose();
      await t.pumpWidget(const SizedBox());
    });
  });
}
