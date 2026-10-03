import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/state/session_guard.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwt(Map<String, dynamic> claims) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.${part(claims)}.sig';
}

User _user({List<UserIdentity>? identities, Map<String, dynamic>? app}) => User(
  id: 'u1',
  appMetadata: app ?? const {},
  userMetadata: const {},
  aud: 'authenticated',
  createdAt: '2026-10-01T00:00:00Z',
  identities: identities,
);

UserIdentity _identity(String provider, String? lastSignIn) => UserIdentity(
  id: provider,
  userId: 'u1',
  identityData: const {},
  identityId: provider,
  provider: provider,
  createdAt: '2026-10-01T00:00:00Z',
  lastSignInAt: lastSignIn,
);

void main() {
  group('sessionIdOf', () {
    test('reads the session_id claim', () {
      expect(sessionIdOf(_jwt({'sub': 'u1', 'session_id': 'abc-123'})), 'abc-123');
    });

    test('a token without the claim, or a bad token, gives null', () {
      expect(sessionIdOf(_jwt({'sub': 'u1'})), isNull);
      expect(sessionIdOf('not.a.jwt'), isNull);
      expect(sessionIdOf('onlyonepart'), isNull);
      expect(sessionIdOf(''), isNull);
      expect(sessionIdOf(null), isNull);
    });

    test('handles base64 without padding', () {
      // a payload whose length is not a multiple of 4 once encoded
      expect(sessionIdOf(_jwt({'session_id': 'x'})), 'x');
    });
  });

  group('sessionWasReplaced', () {
    test('another sign-in id means another device took over', () {
      expect(sessionWasReplaced({'session_id': 'B', 'device_id': 'phoneB'}, mySessionId: 'A', myDeviceId: 'phoneA'), isTrue);
    });

    test('this device\'s own claim (same sign-in id) is not a takeover', () {
      expect(sessionWasReplaced({'session_id': 'A', 'device_id': 'phoneA'}, mySessionId: 'A', myDeviceId: 'phoneA'), isFalse);
    });

    test('with no sign-in id to compare, a different device is a takeover', () {
      expect(sessionWasReplaced({'session_id': null, 'device_id': 'phoneB'}, mySessionId: null, myDeviceId: 'phoneA'), isTrue);
      expect(sessionWasReplaced({'device_id': 'phoneA'}, myDeviceId: 'phoneA'), isFalse);
    });

    test('never signs anyone out when it cannot tell', () {
      expect(sessionWasReplaced({}), isFalse);
      expect(sessionWasReplaced({'session_id': 'B'}), isFalse);
      expect(sessionWasReplaced({'device_id': 'phoneB'}), isFalse);
    });
  });

  group('loginMethodFor', () {
    test('uses the identity signed in with most recently', () {
      final user = _user(identities: [
        _identity('email', '2026-10-01T10:00:00Z'),
        _identity('google', '2026-10-03T10:00:00Z'),
      ]);
      expect(loginMethodFor(user), 'google');
    });

    test('phone sign-ins are OTP', () {
      expect(loginMethodFor(_user(identities: [_identity('phone', '2026-10-03T10:00:00Z')])), 'phone_otp');
    });

    test('apple and facebook pass through', () {
      expect(loginMethodFor(_user(identities: [_identity('apple', '2026-10-03T10:00:00Z')])), 'apple');
      expect(loginMethodFor(_user(identities: [_identity('facebook', null)])), 'facebook');
    });

    test('falls back to the account provider, then to email', () {
      expect(loginMethodFor(_user(app: {'provider': 'google'})), 'google');
      expect(loginMethodFor(_user()), 'email');
    });

    test('an unknown provider is recorded as it is', () {
      expect(loginMethodFor(_user(identities: [_identity('github', '2026-10-03T10:00:00Z')])), 'github');
    });
  });
}
