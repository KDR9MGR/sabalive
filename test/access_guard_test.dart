import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/restrictions_repository.dart';
import 'package:sabalive/state/access_guard.dart';

const _forever = BanInfo(permanent: true);

AccessGuard _guard({
  Future<Restrictions> Function()? fetch,
  Future<BanInfo?> Function()? register,
  Duration timeout = const Duration(seconds: 2),
}) => AccessGuard(
  fetch: fetch ?? () async => Restrictions.none,
  registerDevice: register ?? () async => null,
  clock: () => DateTime.utc(2026, 10, 3),
  timeout: timeout,
);

void main() {
  test('a user with no bans is let in', () async {
    final check = await _guard().check('u1');
    expect(check.blocked, isFalse);
    expect(check.restrictions, Restrictions.none);
  });

  test('an ID ban blocks, with the reason', () async {
    final check = await _guard(
      fetch: () async => const Restrictions(account: _forever),
    ).check('u1');
    expect(check.blocked, isTrue);
    expect(check.blockedMessage, 'Your account is banned permanently.');
  });

  test('a banned device blocks even when the account is clean', () async {
    final check = await _guard(register: () async => _forever).check('u1');
    expect(check.blockedMessage, 'This device is banned permanently.');
  });

  test('a live ban alone does not block the app, but is reported', () async {
    final live = BanInfo(until: DateTime.utc(2026, 10, 9));
    final check = await _guard(
      fetch: () async => Restrictions(live: live),
    ).check('u1');
    expect(check.blocked, isFalse);
    expect(check.restrictions.live, isNotNull);
    expect(check.restrictions.liveBlockMessage(DateTime.utc(2026, 10, 3)), contains('banned from live'));
  });

  test('a ban that has already run out does not block', () async {
    final expired = BanInfo(until: DateTime.utc(2026, 10, 1));
    final check = await _guard(
      fetch: () async => Restrictions(account: expired),
      register: () async => expired,
    ).check('u1');
    expect(check.blocked, isFalse);
  });

  test('asking again for the same user costs no second round trip', () async {
    var calls = 0;
    final guard = _guard(fetch: () async {
      calls++;
      return Restrictions.none;
    });
    await Future.wait([guard.check('u1'), guard.check('u1')]);
    await guard.check('u1');
    expect(calls, 1);
  });

  test('a different user, or after reset, is checked afresh', () async {
    var calls = 0;
    final guard = _guard(fetch: () async {
      calls++;
      return Restrictions.none;
    });
    await guard.check('u1');
    await guard.check('u2');
    guard.reset();
    await guard.check('u2');
    expect(calls, 3);
  });

  test('fails open when the server cannot be reached — and tries again next time', () async {
    var fail = true;
    var calls = 0;
    final guard = _guard(fetch: () async {
      calls++;
      if (fail) throw Exception('offline');
      return const Restrictions(account: _forever);
    });
    final first = await guard.check('u1');
    expect(first.blocked, isFalse, reason: 'the database still enforces; the app does not lock people out on a blip');
    fail = false;
    final second = await guard.check('u1');
    expect(second.blocked, isTrue);
    expect(calls, 2, reason: 'the failed attempt was not remembered');
  });

  test('fails open when the server is too slow, so sign-in is not held up', () async {
    final never = Completer<Restrictions>();
    final guard = _guard(
      fetch: () => never.future,
      timeout: const Duration(milliseconds: 50),
    );
    final check = await guard.check('u1');
    expect(check.blocked, isFalse);
  });
}
