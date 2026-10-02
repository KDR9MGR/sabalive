import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/utils/errors.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('friendlyError', () {
    test('a database error shows its message', () {
      expect(
        friendlyError(const PostgrestException(message: 'You are banned from live permanently.', code: 'BN001')),
        'You are banned from live permanently.',
      );
    });

    test('an edge-function error shows the {error} it returned', () {
      expect(
        friendlyError(const FunctionException(status: 403, details: {'error': 'This device is banned permanently.', 'code': 'BN001'})),
        'This device is banned permanently.',
      );
    });

    test('an edge-function error with a text body shows that', () {
      expect(friendlyError(const FunctionException(status: 500, details: 'Boom')), 'Boom');
    });

    test('an edge-function error with nothing useful still says something', () {
      expect(friendlyError(const FunctionException(status: 502)), contains('502'));
    });

    test('a banned sign-in reads clearly', () {
      expect(friendlyError(AuthException('User is banned')), 'This account has been banned.');
      expect(friendlyError(AuthException('Invalid login credentials')), 'Invalid login credentials');
    });

    test('a plain Exception loses its prefix', () {
      expect(friendlyError(Exception('Nope')), 'Nope');
    });
  });

  group('isLiveAccessError', () {
    test('a ban or a removal from the live counts', () {
      expect(isLiveAccessError(const PostgrestException(message: 'x', code: 'BN001')), isTrue);
      expect(isLiveAccessError(const PostgrestException(message: 'x', code: 'BN002')), isTrue);
      expect(isLiveAccessError(const FunctionException(status: 403, details: {'code': 'BN001'})), isTrue);
    });

    test('ordinary failures do not', () {
      expect(isLiveAccessError(const PostgrestException(message: 'x', code: '23505')), isFalse);
      expect(isLiveAccessError(const FunctionException(status: 500, details: 'Boom')), isFalse);
      expect(isLiveAccessError(Exception('offline')), isFalse);
    });

    test("being blocked from messaging is not a live error", () {
      const blocked = PostgrestException(message: "You can't message this user.", code: 'BN003');
      expect(isLiveAccessError(blocked), isFalse);
      expect(friendlyError(blocked), "You can't message this user.");
    });
  });
}
