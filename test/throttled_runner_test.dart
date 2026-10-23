import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/utils/throttled_runner.dart';

void main() {
  const gap = Duration(seconds: 8);

  testWidgets('the first trigger after a quiet spell runs at once', (t) async {
    var runs = 0;
    final r = ThrottledRunner(() => runs++, minGap: gap);
    r.trigger();
    expect(runs, 1);
    r.cancel();
  });

  testWidgets('a stream of events never gets more than one run per gap', (t) async {
    var runs = 0;
    final r = ThrottledRunner(() => runs++, minGap: gap);
    // an event every 100 ms for a minute: 600 events
    for (var i = 0; i < 600; i++) {
      r.trigger();
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(runs, inInclusiveRange(7, 9), reason: 'about 60 s / 8 s, not 600 (nor the 40 a minute the old 1.5 s window allowed)');
    r.cancel();
  });

  testWidgets('events inside the gap collapse into ONE run when it ends', (t) async {
    var runs = 0;
    final r = ThrottledRunner(() => runs++, minGap: gap);
    r.trigger();
    for (var i = 0; i < 50; i++) {
      r.trigger();
    }
    expect(runs, 1);
    await t.pump(gap);
    expect(runs, 2, reason: 'the collapsed events ran once at the end of the gap');
    await t.pump(gap * 3);
    expect(runs, 2, reason: 'and nothing more: no new events');
    r.cancel();
  });

  testWidgets('a quiet gap leaves nothing scheduled, and the next event runs at once again', (t) async {
    var runs = 0;
    final r = ThrottledRunner(() => runs++, minGap: gap);
    r.trigger();
    await t.pump(gap * 2);
    expect(runs, 1);
    r.trigger();
    expect(runs, 2);
    r.cancel();
  });

  testWidgets('runNow runs whatever the gap, and starts a new one', (t) async {
    var runs = 0;
    final r = ThrottledRunner(() => runs++, minGap: gap);
    r.trigger();
    r.runNow();
    expect(runs, 2);
    r.trigger();
    expect(runs, 2, reason: 'inside the new gap');
    await t.pump(gap);
    expect(runs, 3);
    r.cancel();
  });

  testWidgets('cancel drops a pending run', (t) async {
    var runs = 0;
    final r = ThrottledRunner(() => runs++, minGap: gap);
    r.trigger();
    r.trigger();
    r.cancel();
    await t.pump(gap * 2);
    expect(runs, 1);
  });
}
