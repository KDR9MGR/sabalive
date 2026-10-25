import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/restrictions_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The check before sign-in: `check_login_access_v2` first (finds an ID-banned account by its email / phone, with the end time and the staff reason),
/// the older `check_signup_access` for a new account's network block and on a database that does not have v2.
void main() {
  PostgrestException missing(String fn) => PostgrestException(message: 'Could not find the function public.$fn', code: 'PGRST202');

  group('checkSignup', () {
    test('an ID-banned account is told until when and why', () async {
      final calls = <String>[];
      final repo = RestrictionsRepository(rpc: (fn, params) async {
        calls.add(fn);
        return {'banned': true, 'kind': 'account', 'until': '2030-01-01T10:00:00Z', 'permanent': false, 'note': 'Selling coins'};
      });
      final ban = await repo.checkSignup(deviceIds: ['a'], email: 'x@y.z');
      expect(calls, ['check_login_access_v2'], reason: 'one call is enough');
      expect(ban?.reason, 'account');
      expect(ban?.note, 'Selling coins');
      expect(ban?.until, DateTime.utc(2030, 1, 1, 10));
    });

    test('the email and phone number go to the server as typed, with the phone ids', () async {
      Map<String, dynamic>? sent;
      final repo = RestrictionsRepository(rpc: (fn, params) async {
        sent = params;
        return {'banned': false};
      });
      await repo.checkSignup(deviceIds: ['d1', 'd2'], email: 'a@b.c', phone: '+91 98765 43210');
      expect(sent, {'p_device_ids': ['d1', 'd2'], 'p_email': 'a@b.c', 'p_phone': '+91 98765 43210'});
    });

    test('a sign-in that v2 clears asks nothing more', () async {
      final calls = <String>[];
      final repo = RestrictionsRepository(rpc: (fn, params) async {
        calls.add(fn);
        return {'banned': false};
      });
      expect(await repo.checkSignup(deviceIds: ['a'], email: 'x@y.z'), isNull);
      expect(calls, ['check_login_access_v2']);
    });

    test('a NEW account that v2 clears is still checked against the network block', () async {
      final calls = <String>[];
      final repo = RestrictionsRepository(rpc: (fn, params) async {
        calls.add(fn);
        return fn == 'check_signup_access'
            ? {'banned': true, 'reason': 'ip', 'until': '2030-01-01T00:00:00Z', 'permanent': false}
            : {'banned': false};
      });
      final ban = await repo.checkSignup(deviceIds: ['a'], email: 'x@y.z', newAccount: true);
      expect(calls, ['check_login_access_v2', 'check_signup_access']);
      expect(ban?.reason, 'ip');
    });

    test('a database without v2 falls back to the older check', () async {
      final calls = <String>[];
      final repo = RestrictionsRepository(rpc: (fn, params) async {
        calls.add(fn);
        if (fn == 'check_login_access_v2') throw missing(fn);
        return {'banned': true, 'reason': 'device', 'permanent': true};
      });
      final ban = await repo.checkSignup(deviceIds: ['a']);
      expect(calls, ['check_login_access_v2', 'check_signup_access']);
      expect(ban?.reason, 'device');
      expect(ban?.note, isNull, reason: 'the older answer carries no staff reason');
    });

    test('a database with neither falls back to the single-id check', () async {
      final calls = <String>[];
      final repo = RestrictionsRepository(rpc: (fn, params) async {
        calls.add(fn);
        if (fn == 'check_device_access') return {'banned': true, 'permanent': true};
        throw missing(fn);
      });
      final ban = await repo.checkSignup(deviceIds: ['a']);
      expect(calls, ['check_login_access_v2', 'check_signup_access', 'check_device_access']);
      expect(ban?.permanent, isTrue);
    });

    test('any other server error is raised (the caller fails open)', () async {
      final repo = RestrictionsRepository(rpc: (fn, params) async => throw PostgrestException(message: 'boom', code: '500'));
      expect(() => repo.checkSignup(deviceIds: ['a'], email: 'x@y.z'), throwsA(isA<PostgrestException>()));
    });
  });
}
