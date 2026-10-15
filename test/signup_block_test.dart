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
}
