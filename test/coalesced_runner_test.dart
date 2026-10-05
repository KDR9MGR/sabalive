import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/utils/coalesced_runner.dart';

void main() {
  testWidgets('a burst of triggers runs the action once, at the end of the window', (t) async {
    var runs = 0;
    final r = CoalescedRunner(() => runs++, window: const Duration(seconds: 1));
    for (var i = 0; i < 50; i++) {
      r.trigger();
      await t.pump(const Duration(milliseconds: 10));
    }
    expect(runs, 0, reason: 'nothing runs until the window ends');
    await t.pump(const Duration(seconds: 1));
    expect(runs, 1);
  });

  testWidgets('a later event after the window starts a new one', (t) async {
    var runs = 0;
    final r = CoalescedRunner(() => runs++, window: const Duration(seconds: 1));
    r.trigger();
    await t.pump(const Duration(seconds: 2));
    r.trigger();
    await t.pump(const Duration(seconds: 2));
    expect(runs, 2);
  });

  testWidgets('cancel drops a pending run', (t) async {
    var runs = 0;
    final r = CoalescedRunner(() => runs++, window: const Duration(seconds: 1));
    r.trigger();
    r.cancel();
    await t.pump(const Duration(seconds: 5));
    expect(runs, 0);
  });
}
