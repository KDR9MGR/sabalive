import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/state/blocks_controller.dart';

void main() {
  test('refresh loads who is blocked', () async {
    final c = BlocksController.test(() async => {'a', 'b'});
    expect(c.isBlocked('a'), isFalse);
    await c.refresh();
    expect(c.isBlocked('a'), isTrue);
    expect(c.isBlocked('c'), isFalse);
    expect(c.isBlocked(null), isFalse);
  });

  test('blocking and unblocking update at once and tell listeners', () {
    final c = BlocksController.test(() async => {});
    var notified = 0;
    c.addListener(() => notified++);
    c.markBlocked('a');
    expect(c.isBlocked('a'), isTrue);
    c.markBlocked('a'); // no change, no notification
    c.markUnblocked('a');
    expect(c.isBlocked('a'), isFalse);
    c.markUnblocked('a');
    expect(notified, 2);
  });

  test('a failed refresh never un-hides anyone', () async {
    var fail = false;
    final c = BlocksController.test(() async {
      if (fail) throw Exception('offline');
      return {'a'};
    });
    await c.refresh();
    fail = true;
    await c.refresh();
    expect(c.isBlocked('a'), isTrue);
  });

  test('withoutBlocked drops only blocked people, keeping order', () async {
    final c = BlocksController.test(() async => {'b'});
    await c.refresh();
    final people = [('a', 1), ('b', 2), ('c', 3)];
    expect(c.withoutBlocked(people, (p) => p.$1), [('a', 1), ('c', 3)]);
  });

  test('refresh only notifies when something changed', () async {
    final c = BlocksController.test(() async => {'a'});
    var notified = 0;
    c.addListener(() => notified++);
    await c.refresh();
    await c.refresh();
    expect(notified, 1);
  });
}
