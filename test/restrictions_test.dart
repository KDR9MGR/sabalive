import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/restrictions_repository.dart';

void main() {
  final now = DateTime.utc(2026, 10, 3, 12);

  group('BanInfo', () {
    test('parses an end date and a permanent flag', () {
      final timed = BanInfo.fromJson({'until': '2026-10-10T12:00:00+00:00', 'permanent': false});
      expect(timed.permanent, isFalse);
      expect(timed.until, DateTime.utc(2026, 10, 10, 12));
      final forever = BanInfo.fromJson({'until': null, 'permanent': true});
      expect(forever.permanent, isTrue);
      expect(forever.until, isNull);
    });

    test('phrase reads "permanently" or "until <date>"', () {
      expect(const BanInfo(permanent: true).phrase, 'permanently');
      expect(BanInfo(until: DateTime.utc(2026, 10, 9, 12)).phrase, 'until 09 Oct 2026');
    });

    test('a ban whose date has passed is no longer active, even before the server says so', () {
      expect(BanInfo(until: now.add(const Duration(days: 1))).isActive(now), isTrue);
      expect(BanInfo(until: now.subtract(const Duration(minutes: 1))).isActive(now), isFalse);
      expect(const BanInfo(permanent: true).isActive(now), isTrue);
    });
  });

  group('formatBanDate', () {
    test('pads the day and names the month', () {
      expect(formatBanDate(DateTime(2026, 1, 5, 12)), '05 Jan 2026');
      expect(formatBanDate(DateTime(2026, 12, 31, 12)), '31 Dec 2026');
    });
  });

  group('Restrictions.fromJson', () {
    test('reads each kind, and null means none', () {
      final r = Restrictions.fromJson({
        'account': null,
        'live': {'until': '2026-10-10T12:00:00+00:00', 'permanent': false},
        'device': {'until': null, 'permanent': true},
      });
      expect(r.account, isNull);
      expect(r.live, isNotNull);
      expect(r.device?.permanent, isTrue);
    });

    test('anything unexpected is treated as no restrictions', () {
      expect(Restrictions.fromJson(null), Restrictions.none);
      expect(Restrictions.fromJson('nope'), Restrictions.none);
      expect(Restrictions.fromJson(<String, dynamic>{}), Restrictions.none);
    });

    test('equal restrictions compare equal (so the UI only rebuilds on a change)', () {
      final a = Restrictions.fromJson({'live': {'until': '2026-10-10T12:00:00+00:00', 'permanent': false}});
      final b = Restrictions.fromJson({'live': {'until': '2026-10-10T12:00:00+00:00', 'permanent': false}});
      expect(a, b);
      expect(a == Restrictions.none, isFalse);
    });
  });

  group('messages', () {
    final until = BanInfo(until: DateTime.utc(2026, 10, 9, 12));
    const forever = BanInfo(permanent: true);

    test('nothing active: no message', () {
      expect(Restrictions.none.appBlockMessage(now), isNull);
      expect(Restrictions.none.liveBlockMessage(now), isNull);
    });

    test('an ID ban closes the app and live', () {
      final r = Restrictions(account: until);
      expect(r.appBlockMessage(now), 'Your account is banned until 09 Oct 2026.');
      expect(r.liveBlockMessage(now), 'Your account is banned until 09 Oct 2026.');
    });

    test('a device ban closes the app and live', () {
      const r = Restrictions(device: forever);
      expect(r.appBlockMessage(now), 'This device is banned permanently.');
      expect(r.liveBlockMessage(now), 'This device is banned permanently.');
    });

    test('a live ban closes live only', () {
      final r = Restrictions(live: until);
      expect(r.appBlockMessage(now), isNull);
      expect(r.liveBlockMessage(now), 'You are banned from live until 09 Oct 2026.');
    });

    test('the account ban is named first when several apply', () {
      final r = Restrictions(account: until, live: forever, device: forever);
      expect(r.appBlockMessage(now), startsWith('Your account'));
    });

    test('an expired ban says nothing', () {
      final r = Restrictions(live: BanInfo(until: now.subtract(const Duration(hours: 1))));
      expect(r.liveBlockMessage(now), isNull);
    });
  });
}
