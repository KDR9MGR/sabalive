import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/restrictions_repository.dart';
import 'package:sabalive/state/auth_controller.dart';

void main() {
  group('what the sign-in / sign-up check says when it turns someone away', () {
    test('a banned phone keeps the old wording', () {
      expect(
        AuthController.signupBlockedMessage(const BanInfo(permanent: true, reason: 'device')),
        'This device is banned permanently.',
      );
      // an answer from an older database has no reason at all
      expect(
        AuthController.signupBlockedMessage(const BanInfo(permanent: true)),
        'This device is banned permanently.',
      );
    });

    test('a banned identity (Google / email / phone number) cannot create an account', () {
      expect(
        AuthController.signupBlockedMessage(const BanInfo(permanent: true, reason: 'identity')),
        'This account cannot be created.',
      );
    });

    test('an ID-banned account says until when, and the reason staff wrote on a second line', () {
      final ends = DateTime(2026, 10, 27, 14, 30).toUtc();
      expect(
        AuthController.signupBlockedMessage(BanInfo(until: ends, reason: 'account')),
        'Your account is banned until 27 Oct 2026, 14:30.',
      );
      expect(
        AuthController.signupBlockedMessage(BanInfo(until: ends, reason: 'account', note: 'Selling coins outside the app')),
        'Your account is banned until 27 Oct 2026, 14:30.\nReason: Selling coins outside the app',
      );
      expect(
        AuthController.signupBlockedMessage(const BanInfo(permanent: true, reason: 'account', note: 'Chargeback abuse')),
        'Your account is banned permanently.\nReason: Chargeback abuse',
      );
    });

    test('a banned phone and a blocked identity carry the reason too', () {
      expect(
        AuthController.signupBlockedMessage(const BanInfo(permanent: true, reason: 'device', note: 'Fake gifts')),
        'This device is banned permanently.\nReason: Fake gifts',
      );
      expect(
        AuthController.signupBlockedMessage(const BanInfo(permanent: true, reason: 'identity', note: 'Chargeback abuse')),
        'This account cannot be created.\nReason: Chargeback abuse',
      );
    });

    test('a briefly blocked network never shows a reason', () {
      final msg = AuthController.signupBlockedMessage(BanInfo(until: DateTime.utc(2030), reason: 'ip', note: 'x'));
      expect(msg, isNot(contains('Reason')));
    });

    test('a briefly blocked network says to try again later', () {
      final msg = AuthController.signupBlockedMessage(BanInfo(until: DateTime.utc(2030), reason: 'ip'));
      expect(msg, contains('try again later'));
    });
  });

  test('BanInfo reads the reason the server gives', () {
    final ban = BanInfo.fromJson({'banned': true, 'reason': 'ip', 'until': '2030-01-01T00:00:00Z', 'permanent': false});
    expect(ban.reason, 'ip');
    expect(ban.isActive(DateTime.utc(2029)), isTrue);
    expect(ban.isActive(DateTime.utc(2031)), isFalse);
    expect(BanInfo.fromJson({'banned': true, 'permanent': true}).reason, isNull);
  });

  test('BanInfo reads the kind and the staff note of check_login_access_v2', () {
    final ban = BanInfo.fromJson({
      'banned': true, 'kind': 'account', 'until': '2030-01-01T00:00:00Z', 'permanent': false, 'note': '  Spam  ',
    });
    expect(ban.reason, 'account', reason: 'the kind is the reason code');
    expect(ban.note, 'Spam', reason: 'trimmed');
    expect(BanInfo.fromJson({'banned': true, 'kind': 'device', 'permanent': true, 'note': null}).note, isNull);
    expect(BanInfo.fromJson({'banned': true, 'kind': 'device', 'permanent': true, 'note': '   '}).note, isNull);
    expect(BanInfo.fromJson({'banned': true, 'reason': 'ip', 'kind': 'device', 'permanent': true}).reason, 'ip', reason: 'the older field wins');
  });
}
