import 'dart:async';

/// Runs [action] once at the end of a short window, however many times [trigger]
/// is called inside it. For work that should follow a burst of events (a Realtime
/// table that changes on every heartbeat and every viewer join) without redoing it
/// for each one: the action reads fresh data when it runs, so nothing is lost.
class CoalescedRunner {
  CoalescedRunner(this.action, {this.window = const Duration(milliseconds: 1500)});

  final void Function() action;
  final Duration window;
  Timer? _timer;

  void trigger() {
    if (_timer?.isActive ?? false) return;
    _timer = Timer(window, action);
  }

  void cancel() => _timer?.cancel();
}
