import 'dart:async';

/// Runs [action] at most once per [minGap]: the first trigger after a quiet spell runs AT ONCE (so something new shows without waiting), and every
/// trigger that arrives inside the gap collapses into ONE more run when the gap ends. For work that follows a stream of events that never stops
/// (a Realtime table that changes on every heartbeat): [CoalescedRunner] would run once per window however long the stream goes on, which for a short
/// window is still dozens of runs a minute; this one has a hard ceiling of one run per [minGap].
///
/// The action reads fresh data when it runs, so a collapsed trigger loses nothing.
class ThrottledRunner {
  ThrottledRunner(this.action, {this.minGap = const Duration(seconds: 8)});

  final void Function() action;
  final Duration minGap;
  Timer? _timer;
  bool _cooling = false;
  bool _pending = false;

  void trigger() {
    if (_cooling) {
      _pending = true;
      return;
    }
    _run();
  }

  /// Runs now, whatever the gap (coming back to the screen, pull to refresh) and starts a new gap.
  void runNow() {
    cancel();
    _run();
  }

  void _run() {
    _pending = false;
    _cooling = true;
    action();
    _timer = Timer(minGap, () {
      _cooling = false;
      if (_pending) _run();
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _cooling = false;
    _pending = false;
  }
}
