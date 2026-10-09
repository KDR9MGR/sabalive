import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/utils/fire_and_forget.dart';

/// Behaves like a Supabase builder: the work only happens when something chains on it.
class _LazyCall implements Future<void> {
  int started = 0;
  Future<void> _run() async => started++;
  @override
  Future<R> then<R>(FutureOr<R> Function(void) onValue, {Function? onError}) => _run().then(onValue, onError: onError);
  @override
  Future<void> catchError(Function onError, {bool Function(Object)? test}) => _run().catchError(onError, test: test);
  @override
  Future<void> whenComplete(FutureOr<void> Function() action) => _run().whenComplete(action);
  @override
  Stream<void> asStream() => _run().asStream();
  @override
  Future<void> timeout(Duration timeLimit, {FutureOr<void> Function()? onTimeout}) => _run().timeout(timeLimit, onTimeout: onTimeout);
}

void main() {
  test('unawaited() alone never starts a lazy request (the old bug)', () async {
    final call = _LazyCall();
    unawaited(call);
    await Future<void>.delayed(Duration.zero);
    expect(call.started, 0);
  });

  test('fireAndForget starts the request', () async {
    final call = _LazyCall();
    fireAndForget(call);
    await Future<void>.delayed(Duration.zero);
    expect(call.started, 1);
  });

  test('a failing request is swallowed', () async {
    fireAndForget(Future<void>.error(Exception('network down')));
    await Future<void>.delayed(Duration.zero);
  });
}
