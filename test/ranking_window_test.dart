import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/rankings_repository.dart' show RankPeriod;
import 'package:sabalive/features/rankings/ranking_window.dart';

// The Rankings follow INDIA midnight (the database's boards do since migration 20261101020000). These are the same moments its test uses: the instant
// India midnight arrives is 18:30 UTC the evening before.
RankingWindow w(RankPeriod p, DateTime nowUtc) =>
    RankingWindow.of(p, now: nowUtc);

void main() {
  // 1 November 2026, 03:01 India time = 31 October 21:31 UTC: the moment the owner saw the Monthly board still counting October.
  final earlyNov1 = DateTime.utc(2026, 10, 31, 21, 31);

  test(
    'at 03:01 India time on 1 Nov the month, the day and the week have all moved on or are in the right place',
    () {
      expect(w(RankPeriod.monthly, earlyNov1).startLabel, '1 Nov');
      expect(w(RankPeriod.daily, earlyNov1).startLabel, '1 Nov');
      expect(
        w(RankPeriod.weekly, earlyNov1).startLabel,
        '26 Oct',
      ); // 1 Nov 2026 is a Sunday: the week began on Monday 26 Oct
    },
  );

  test(
    'one minute before India midnight is still the old day and month; at India midnight everything rolls over',
    () {
      final before = DateTime.utc(
        2026,
        10,
        31,
        18,
        29,
      ); // 23:59 India time on 31 Oct
      final after = DateTime.utc(
        2026,
        10,
        31,
        18,
        30,
      ); // 00:00 India time on 1 Nov
      expect(w(RankPeriod.monthly, before).startLabel, '1 Oct');
      expect(w(RankPeriod.daily, before).startLabel, '31 Oct');
      expect(w(RankPeriod.monthly, after).startLabel, '1 Nov');
      expect(w(RankPeriod.daily, after).startLabel, '1 Nov');
      expect(
        w(RankPeriod.monthly, before).key,
        isNot(w(RankPeriod.monthly, after).key),
      );
      expect(
        w(RankPeriod.daily, before).key,
        isNot(w(RankPeriod.daily, after).key),
      );
    },
  );

  test(
    'the week rolls over at India midnight into Monday, and not on the other days',
    () {
      final sundayLate = DateTime.utc(
        2026,
        11,
        1,
        18,
        29,
      ); // 23:59 India time, Sunday 1 Nov
      final mondayStart = DateTime.utc(
        2026,
        11,
        1,
        18,
        30,
      ); // 00:00 India time, Monday 2 Nov
      expect(w(RankPeriod.weekly, sundayLate).startLabel, '26 Oct');
      expect(w(RankPeriod.weekly, mondayStart).startLabel, '2 Nov');
      expect(
        w(RankPeriod.weekly, sundayLate).key,
        isNot(w(RankPeriod.weekly, mondayStart).key),
      );
      // Wednesday: still that Monday, and the weekly key does not change from one day to the next
      expect(
        w(RankPeriod.weekly, DateTime.utc(2026, 11, 4, 9)).startLabel,
        '2 Nov',
      );
      expect(
        w(RankPeriod.weekly, DateTime.utc(2026, 11, 4, 9)).key,
        w(RankPeriod.weekly, DateTime.utc(2026, 11, 7, 9)).key,
      );
    },
  );

  test(
    'a year boundary: 1 Jan 2027 00:00 India time starts a new month and the week still began on Monday 28 Dec',
    () {
      final newYear = DateTime.utc(2026, 12, 31, 18, 30);
      expect(w(RankPeriod.monthly, newYear).startLabel, '1 Jan');
      expect(w(RankPeriod.monthly, newYear).startDay.year, 2027);
      expect(w(RankPeriod.weekly, newYear).startLabel, '28 Dec');
      expect(
        w(RankPeriod.monthly, DateTime.utc(2026, 12, 31, 18, 29)).startLabel,
        '1 Dec',
      );
    },
  );

  test(
    'the same instant gives the same board whatever time zone the phone is set to',
    () {
      final utc = DateTime.utc(2026, 10, 31, 21, 31);
      // a local DateTime of the same instant (the test machine decides what "local" is; the answer must not depend on it)
      final local = utc.toLocal();
      for (final p in RankPeriod.values) {
        expect(w(p, local).key, w(p, utc).key);
        expect(w(p, local).startLabel, w(p, utc).startLabel);
      }
    },
  );

  test(
    'the keys tell the periods apart and only change at a rollover (what the screen compares to decide to fetch again)',
    () {
      expect(
        w(RankPeriod.daily, earlyNov1).key,
        isNot(w(RankPeriod.monthly, earlyNov1).key),
      );
      // an hour later, the same day / week / month: the same key, so no extra fetch
      final later = DateTime.utc(2026, 11, 1, 5);
      for (final p in RankPeriod.values) {
        expect(w(p, later).key, w(p, earlyNov1).key);
      }
    },
  );

  test(
    'what the screen says: what the board covers and when it starts again',
    () {
      expect(w(RankPeriod.daily, earlyNov1).coverage, 'Today, 1 Nov');
      expect(w(RankPeriod.weekly, earlyNov1).coverage, 'Since 26 Oct');
      expect(w(RankPeriod.monthly, earlyNov1).coverage, 'Since 1 Nov');
      expect(
        w(RankPeriod.daily, earlyNov1).resets,
        'Resets every day at midnight India time',
      );
      expect(
        w(RankPeriod.weekly, earlyNov1).resets,
        'Resets every Monday at midnight India time',
      );
      expect(
        w(RankPeriod.monthly, earlyNov1).resets,
        'Resets on the 1st of each month at midnight India time',
      );
    },
  );
}
