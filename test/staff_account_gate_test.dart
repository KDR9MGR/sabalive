import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/state/staff_account_gate.dart';

class _MemoryCache implements VerifiedUserCache {
  String? who;
  @override
  Future<bool> isVerified(String userId) async => who == userId;
  @override
  Future<void> markVerified(String userId) async => who = userId;
  @override
  Future<void> clear() async => who = null;
}

void main() {
  late _MemoryCache cache;
  late int lookups;

  StaffAccountGate gate(Future<bool> Function(String) fn) => StaffAccountGate(
        lookup: (id) {
          lookups++;
          return fn(id);
        },
        cache: cache,
      );

  setUp(() {
    cache = _MemoryCache();
    lookups = 0;
  });

  group('a panel account is refused', () {
    test('by the is_staff flag on the session alone — no query needed',
        () async {
      final v = await gate((_) async => false)
          .check('u1', appMetadata: {'is_staff': true, 'provider': 'email'});
      expect(v, StaffGateVerdict.staff);
      expect(lookups, 0, reason: 'the flag is enough; nothing to fail');
    });

    test('even when the network is down, if the flag says staff', () async {
      final v = await gate((_) async => throw Exception('offline'))
          .check('u1', appMetadata: {'is_staff': true});
      expect(v, StaffGateVerdict.staff);
    });

    test('by the staff_roles lookup when the session has no flag yet (an '
        'older session, or a role granted since)', () async {
      final v = await gate((_) async => true).check('u1', appMetadata: {});
      expect(v, StaffGateVerdict.staff);
      expect(lookups, 1);
    });

    test('and a refused account is never remembered as verified', () async {
      cache.who = 'u1'; // was a normal user, has since been made staff
      await gate((_) async => true).check('u1');
      expect(cache.who, isNull);
    });
  });

  group('a staff account with the server-set app-access exception', () {
    test('is let in even though is_staff is set — no query needed', () async {
      final v = await gate((_) async => true).check('u1',
          appMetadata: {'is_staff': true, 'staff_app_access': true});
      expect(v, StaffGateVerdict.allowed);
      expect(lookups, 0);
    });

    test('and the exception alone does not let a plain staff account in',
        () async {
      final v = await gate((_) async => true)
          .check('u1', appMetadata: {'is_staff': true, 'staff_app_access': false});
      expect(v, StaffGateVerdict.staff);
    });
  });

  group('a normal user is let in', () {
    test('when the lookup says they are not staff — and is remembered',
        () async {
      final v = await gate((_) async => false).check('u1', appMetadata: {});
      expect(v, StaffGateVerdict.allowed);
      expect(cache.who, 'u1');
    });

    test('with no app_metadata at all', () async {
      expect(await gate((_) async => false).check('u1'),
          StaffGateVerdict.allowed);
    });

    test('is_staff: false does not block', () async {
      expect(
          await gate((_) async => false)
              .check('u1', appMetadata: {'is_staff': false}),
          StaffGateVerdict.allowed);
    });
  });

  group('when the lookup cannot be made', () {
    test('an account never verified before is NOT let in (fails closed)',
        () async {
      final v = await gate((_) async => throw Exception('offline')).check('u1');
      expect(v, StaffGateVerdict.unverified);
    });

    test('an account already verified on this device stays usable offline',
        () async {
      cache.who = 'u1';
      final v = await gate((_) async => throw Exception('offline')).check('u1');
      expect(v, StaffGateVerdict.allowed);
    });

    test('but another account is not covered by someone else\'s verification',
        () async {
      cache.who = 'u1';
      final v = await gate((_) async => throw Exception('offline')).check('u2');
      expect(v, StaffGateVerdict.unverified);
    });
  });

  test('messages: a panel account and an unverifiable one get clear wording',
      () {
    expect(StaffAccountGate.messageFor(StaffGateVerdict.allowed), isNull);
    expect(StaffAccountGate.messageFor(StaffGateVerdict.staff),
        contains('admin-panel account'));
    expect(StaffAccountGate.messageFor(StaffGateVerdict.unverified),
        contains('connection'));
  });
}
