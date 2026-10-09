import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/lucky_box_repository.dart';
import 'package:sabalive/features/live/widgets/lucky_box_badge.dart';

class _FakeRepo extends Fake implements LuckyBoxRepository {
  _FakeRepo({this.startedAt, this.failConfig = false});
  LuckyBoxConfig config0 =
      const LuckyBoxConfig(durationMinutes: 40, rewardDiamonds: 3000, cooldownHours: 24);
  DateTime? startedAt;
  int? reward;
  LuckyBoxStatus? status0;
  bool failConfig;
  int rewardChecks = 0;

  @override
  Future<LuckyBoxConfig> config() async {
    if (failConfig) throw Exception('offline');
    return config0;
  }

  @override
  Future<DateTime?> streamStartedAt(String streamId) async => startedAt;

  @override
  Future<LuckyBoxStatus?> status(String streamId) async => status0;

  @override
  Future<int?> rewardGranted(String streamId) async {
    rewardChecks++;
    return reward;
  }
}

void main() {
  final start = DateTime.utc(2026, 10, 1, 12, 0, 0);

  group('luckyBoxProgress', () {
    test('counts down to the configured duration', () {
      final p = luckyBoxProgress(
        startedAt: start,
        duration: const Duration(minutes: 40),
        now: start.add(const Duration(minutes: 10)),
      );
      expect(p.phase, LuckyBoxPhase.counting);
      expect(p.remaining, const Duration(minutes: 30));
    });

    test('at the deadline it is "opening" until the server pays', () {
      final p = luckyBoxProgress(
        startedAt: start,
        duration: const Duration(minutes: 40),
        now: start.add(const Duration(minutes: 40)),
      );
      expect(p.phase, LuckyBoxPhase.opening);
      expect(p.remaining, Duration.zero);
    });

    test('long past the deadline and still unpaid stays "opening", never negative',
        () {
      final p = luckyBoxProgress(
        startedAt: start,
        duration: const Duration(minutes: 40),
        now: start.add(const Duration(hours: 3)),
      );
      expect(p.phase, LuckyBoxPhase.opening);
      expect(p.remaining, Duration.zero);
    });

    test('once paid it is "opened" with the amount, even if time is not up by '
        'this device\'s clock', () {
      final p = luckyBoxProgress(
        startedAt: start,
        duration: const Duration(minutes: 40),
        now: start.add(const Duration(minutes: 5)),
        rewardPaid: 3000,
      );
      expect(p.phase, LuckyBoxPhase.opened);
      expect(p.reward, 3000);
    });

    test('a changed duration from the panel moves the deadline', () {
      DateTime now() => start.add(const Duration(minutes: 20));
      expect(
          luckyBoxProgress(
                  startedAt: start,
                  duration: const Duration(minutes: 40),
                  now: now())
              .remaining,
          const Duration(minutes: 20));
      expect(
          luckyBoxProgress(
                  startedAt: start,
                  duration: const Duration(minutes: 15),
                  now: now())
              .phase,
          LuckyBoxPhase.opening);
    });
  });

  group('luckyBoxClock', () {
    test('formats mm:ss and h:mm:ss', () {
      expect(luckyBoxClock(const Duration(minutes: 12, seconds: 5)), '12:05');
      expect(luckyBoxClock(const Duration(seconds: 9)), '00:09');
      expect(luckyBoxClock(const Duration(hours: 1, minutes: 2, seconds: 5)),
          '1:02:05');
      expect(luckyBoxClock(const Duration(seconds: -4)), '00:00');
    });
  });

  group('LuckyBoxBadge', () {
    late DateTime clock;
    Widget host(_FakeRepo repo, {Duration refresh = const Duration(minutes: 1)}) =>
        MaterialApp(
          home: Scaffold(
            body: LuckyBoxBadge(
              streamId: 's1',
              repo: repo,
              now: () => clock,
              configRefresh: refresh,
              rewardCheck: const Duration(seconds: 10),
            ),
          ),
        );

    testWidgets('shows the box with a countdown under it', (t) async {
      clock = start.add(const Duration(minutes: 10));
      await t.pumpWidget(host(_FakeRepo(startedAt: start)));
      await t.pump();
      expect(find.byIcon(Icons.card_giftcard_rounded), findsOneWidget);
      expect(find.text('30:00'), findsOneWidget);
    });

    testWidgets('the countdown ticks, then shows Opening… at zero', (t) async {
      clock = start.add(const Duration(minutes: 39, seconds: 58));
      await t.pumpWidget(host(_FakeRepo(startedAt: start)));
      await t.pump();
      expect(find.text('00:02'), findsOneWidget);

      clock = start.add(const Duration(minutes: 40, seconds: 1));
      await t.pump(const Duration(seconds: 1));
      expect(find.text('Opening…'), findsOneWidget);
    });

    testWidgets('shows what was won once the server has paid', (t) async {
      clock = start.add(const Duration(minutes: 41));
      final repo = _FakeRepo(startedAt: start);
      await t.pumpWidget(host(repo));
      await t.pump();
      expect(find.text('Opening…'), findsOneWidget);

      repo.reward = 3000; // the cron job paid out
      await t.pump(const Duration(seconds: 10)); // next reward check
      await t.pump();
      expect(find.text('+3,000'), findsOneWidget);
      expect(find.byIcon(Icons.celebration_rounded), findsOneWidget);
    });

    testWidgets('does not ask for a reward while still counting down', (t) async {
      clock = start.add(const Duration(minutes: 5));
      final repo = _FakeRepo(startedAt: start);
      await t.pumpWidget(host(repo));
      await t.pump();
      final before = repo.rewardChecks; // the one at load
      await t.pump(const Duration(seconds: 30));
      expect(repo.rewardChecks, before);
    });

    testWidgets('a panel change to the duration shows up on the next refresh',
        (t) async {
      clock = start.add(const Duration(minutes: 10));
      final repo = _FakeRepo(startedAt: start);
      await t.pumpWidget(host(repo));
      await t.pump();
      expect(find.text('30:00'), findsOneWidget);

      // admin panel: duration 40 -> 25
      repo.config0 =
          const LuckyBoxConfig(durationMinutes: 25, rewardDiamonds: 3000);
      await t.pump(const Duration(minutes: 1));
      await t.pump();
      expect(find.text('15:00'), findsOneWidget); // 25 min total, clock fixed at 10 min in
    });

    testWidgets('tapping explains the rules using the panel values', (t) async {
      clock = start.add(const Duration(minutes: 10));
      await t.pumpWidget(host(_FakeRepo(startedAt: start)));
      await t.pump();
      await t.tap(find.byIcon(Icons.card_giftcard_rounded));
      await t.pumpAndSettle();
      expect(find.textContaining('40 minutes'), findsOneWidget);
      expect(find.textContaining('3,000 diamonds'), findsOneWidget);
    });

    testWidgets('shows nothing if the settings cannot be read', (t) async {
      clock = start;
      await t.pumpWidget(host(_FakeRepo(startedAt: start, failConfig: true)));
      await t.pump();
      expect(find.byIcon(Icons.card_giftcard_rounded), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('shows nothing if the stream has no start time', (t) async {
      clock = start;
      await t.pumpWidget(host(_FakeRepo(startedAt: null)));
      await t.pump();
      expect(find.byIcon(Icons.card_giftcard_rounded), findsNothing);
    });

    testWidgets('a first load that failed is tried again and the box then appears', (t) async {
      clock = start.add(const Duration(minutes: 10));
      final repo = _FakeRepo(startedAt: start, failConfig: true);
      await t.pumpWidget(host(repo));
      await t.pump();
      expect(find.byIcon(Icons.card_giftcard_rounded), findsNothing);

      repo.failConfig = false; // the network came up
      await t.pump(const Duration(seconds: 15));
      await t.pump();
      expect(find.byIcon(Icons.card_giftcard_rounded), findsOneWidget);
      expect(find.text('30:00'), findsOneWidget);
    });
  });

  group('the cooldown', () {
    late DateTime clock;
    Widget host(_FakeRepo repo, {bool viewer = false}) => MaterialApp(
          home: Scaffold(
            body: LuckyBoxBadge(streamId: 's1', forViewer: viewer, repo: repo, now: () => clock),
          ),
        );

    test('LuckyBoxStatus reads the server answer, with or without a rest period', () {
      final s = LuckyBoxStatus.fromJson({'paid': false, 'rest_until': '2026-10-11T08:00:00+00:00', 'opens_at': 'x'});
      expect(s.paid, isFalse);
      expect(s.restUntil, DateTime.utc(2026, 10, 11, 8));
      final t = LuckyBoxStatus.fromJson({'paid': true, 'rest_until': null});
      expect(t.paid, isTrue);
      expect(t.restUntil, isNull);
    });

    test('the wait is written as hours and minutes', () {
      expect(luckyBoxRestLabel(const Duration(hours: 23, minutes: 12)), '23h 12m');
      expect(luckyBoxRestLabel(const Duration(hours: 5)), '5h');
      expect(luckyBoxRestLabel(const Duration(minutes: 45)), '45m');
      expect(luckyBoxRestLabel(const Duration(seconds: 20)), '1m');
      expect(luckyBoxRestLabel(Duration.zero), 'now');
      expect(luckyBoxRestLabel(const Duration(minutes: -3)), 'now');
    });

    testWidgets('a resting host sees a grey box and when a new live can earn, not a countdown to nothing', (t) async {
      clock = start.add(const Duration(minutes: 10));
      final repo = _FakeRepo(startedAt: start)
        ..status0 = LuckyBoxStatus(restUntil: clock.add(const Duration(hours: 23, minutes: 12)));
      await t.pumpWidget(host(repo));
      await t.pump();
      expect(find.text('Next in 23h 12m'), findsOneWidget);
      expect(find.text('30:00'), findsNothing);
      await t.tap(find.byIcon(Icons.card_giftcard_rounded));
      await t.pumpAndSettle();
      expect(find.textContaining('last 24 hours'), findsOneWidget);
      expect(find.textContaining('40 minutes'), findsOneWidget);
    });

    testWidgets('once the rest is over the host is told to start a new live', (t) async {
      clock = start.add(const Duration(minutes: 10));
      final repo = _FakeRepo(startedAt: start)..status0 = LuckyBoxStatus(restUntil: clock.subtract(const Duration(minutes: 1)));
      await t.pumpWidget(host(repo));
      await t.pump();
      expect(find.text('New live'), findsOneWidget);
    });

    testWidgets('a viewer is shown no box at all while the host is resting', (t) async {
      clock = start.add(const Duration(minutes: 10));
      final repo = _FakeRepo(startedAt: start)..status0 = LuckyBoxStatus(restUntil: clock.add(const Duration(hours: 20)));
      await t.pumpWidget(host(repo, viewer: true));
      await t.pump();
      expect(find.byIcon(Icons.card_giftcard_rounded), findsNothing);
    });

    testWidgets('a live that already paid shows the opened box, even though the host is resting for the next one', (t) async {
      clock = start.add(const Duration(minutes: 50));
      final repo = _FakeRepo(startedAt: start)
        ..reward = 3000
        ..status0 = LuckyBoxStatus(paid: true, restUntil: clock.add(const Duration(hours: 23)));
      await t.pumpWidget(host(repo));
      await t.pump();
      expect(find.text('+3,000'), findsOneWidget);
    });

    testWidgets('a viewer sees Opened as soon as the server says it was paid, before the timer would', (t) async {
      clock = start.add(const Duration(minutes: 30));
      final repo = _FakeRepo(startedAt: start)..status0 = const LuckyBoxStatus(paid: true);
      await t.pumpWidget(host(repo, viewer: true));
      await t.pump();
      expect(find.text('Opened'), findsOneWidget);
    });

    testWidgets('an older database with no status function behaves exactly as before', (t) async {
      clock = start.add(const Duration(minutes: 10));
      await t.pumpWidget(host(_FakeRepo(startedAt: start))); // status0 null
      await t.pump();
      expect(find.text('30:00'), findsOneWidget);
    });
  });

  group('LuckyBoxBadge for a viewer', () {
    late DateTime clock;
    Widget host(_FakeRepo repo) => MaterialApp(
          home: Scaffold(
            body: LuckyBoxBadge(streamId: 's1', forViewer: true, repo: repo, now: () => clock),
          ),
        );

    testWidgets('sees the box and the countdown, and never looks at a wallet', (t) async {
      clock = start.add(const Duration(minutes: 10));
      final repo = _FakeRepo(startedAt: start);
      await t.pumpWidget(host(repo));
      await t.pump();
      expect(find.text('30:00'), findsOneWidget);
      await t.pump(const Duration(seconds: 30));
      expect(repo.rewardChecks, 0);
    });

    testWidgets('when the time is up the box shows Opened, without an amount', (t) async {
      clock = start.add(const Duration(minutes: 41));
      await t.pumpWidget(host(_FakeRepo(startedAt: start)));
      await t.pump();
      expect(find.text('Opened'), findsOneWidget);
      expect(find.text('Opening…'), findsNothing);
      expect(find.byIcon(Icons.diamond_rounded), findsNothing);
    });

    testWidgets('tapping explains it is the host who wins', (t) async {
      clock = start.add(const Duration(minutes: 10));
      await t.pumpWidget(host(_FakeRepo(startedAt: start)));
      await t.pump();
      await t.tap(find.byIcon(Icons.card_giftcard_rounded));
      await t.pumpAndSettle();
      expect(find.textContaining('The host wins 3,000 diamonds'), findsOneWidget);
      expect(find.textContaining('40 minutes'), findsOneWidget);
    });
  });
}
