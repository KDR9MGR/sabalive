import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/services/crash_reporting.dart';

PreviousExit exit({int reason = 3, int importance = 100, int timestamp = 1000, int rssKb = 0, String description = '', int status = 0}) =>
    PreviousExit(reason: reason, status: status, importance: importance, timestamp: timestamp, rssKb: rssKb, description: description);

void main() {
  group('which endings are worth a report', () {
    test('the phone killing the app while it was in use is', () {
      expect(exit(reason: 3, importance: 100).worthReporting, isTrue); // LOW_MEMORY, foreground
      expect(exit(reason: 3, importance: 200).worthReporting, isTrue); // visible
    });

    test('the phone tidying up an app nobody was using is not', () {
      expect(exit(reason: 3, importance: 400).worthReporting, isFalse); // LOW_MEMORY, cached
      expect(exit(reason: 2, importance: 400).worthReporting, isFalse); // SIGNALED, cached
    });

    test('a crash, a native crash and a freeze are, whatever the app was doing', () {
      for (final reason in [4, 5, 6]) {
        expect(exit(reason: reason, importance: 400).worthReporting, isTrue, reason: 'reason $reason');
      }
    });

    test('the person closing the app, an update and the app quitting itself are not', () {
      for (final reason in [1, 10, 11, 14, 15, 16, 8]) {
        expect(exit(reason: reason, importance: 100).worthReporting, isFalse, reason: 'reason $reason');
      }
    });
  });

  group('what is reported once', () {
    test('only endings newer than the last look, oldest first', () {
      final all = [
        exit(reason: 3, timestamp: 300),
        exit(reason: 3, timestamp: 100),
        exit(reason: 3, timestamp: 200),
      ];
      expect(PreviousExits.toReport(all, seenUpTo: 150).map((e) => e.timestamp), [200, 300]);
      expect(PreviousExits.toReport(all, seenUpTo: 300), isEmpty);
    });

    test('a quiet ending is looked at (so it is not seen again) but not reported', () {
      final all = [exit(reason: 10, timestamp: 500), exit(reason: 3, timestamp: 400)];
      expect(PreviousExits.toReport(all, seenUpTo: 0).map((e) => e.timestamp), [400]);
      expect(PreviousExits.newestSeen(all, seenUpTo: 0), 500);
    });

    test('with nothing new the mark stays where it was', () {
      expect(PreviousExits.newestSeen(const [], seenUpTo: 700), 700);
    });
  });

  group('the words in a report', () {
    test('names the reason, what the app was doing, its size and the signal', () {
      final e = exit(reason: 5, importance: 100, rssKb: 512 * 1024, status: 11, description: 'signal 11');
      expect(e.summary, 'The app ended: CRASH_NATIVE, while FOREGROUND, 512 MB in memory, status 11 (signal 11)');
    });

    test('leaves out what it does not know', () {
      expect(exit(reason: 3).summary, 'The app ended: LOW_MEMORY, while FOREGROUND, status 0');
    });

    test('an unknown reason still has a name', () {
      expect(exit(reason: 99).reasonName, 'REASON_99');
    });

    test('importance numbers read as words', () {
      expect(exit(importance: 100).importanceName, 'FOREGROUND');
      expect(exit(importance: 200).importanceName, 'VISIBLE');
      expect(exit(importance: 400).importanceName, 'CACHED');
      expect(exit(importance: 1000).importanceName, 'GONE');
    });

    test('the same kind of ending has the same stack, so Crashlytics gathers them in one issue', () {
      expect(exit(reason: 3, timestamp: 1).stack.toString(), exit(reason: 3, timestamp: 2).stack.toString());
      expect(exit(reason: 3).stack.toString(), isNot(exit(reason: 6).stack.toString()));
    });
  });

  test('an entry from the phone, with odd or missing values, never throws', () {
    final e = PreviousExit.fromMap({'reason': 3, 'rssKb': 2048.0, 'description': null, 'timestamp': 5});
    expect(e.reason, 3);
    expect(e.rssKb, 2048);
    expect(e.description, '');
    expect(e.importance, 1000);
    expect(PreviousExit.fromMap(const {}).reasonName, 'UNKNOWN');
  });

  test('every call is a quiet no-op when reporting is off (tests, iPhone)', () async {
    expect(CrashReporting.isOn, isFalse);
    CrashReporting.log('x');
    CrashReporting.key('k', 1);
    CrashReporting.setUser('2222');
    CrashReporting.startMemoryTrail();
    await CrashReporting.reportPreviousExits();
    await CrashReporting.start(firebaseReady: true); // there is no Firebase app in a test: it fails quietly and stays off
    expect(CrashReporting.isOn, isFalse);
  });
}
