import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Calls [onRefresh] when this part of the screen becomes visible (its tab is selected, or the screen that covered it is closed), when the app comes back to the front,
/// and every [every] while it is visible and the app is in front. It never runs for a tab that is not shown, and never while the app is in the background, so a
/// screen kept alive in a tab costs nothing until someone looks at it. Visible = [active] (the caller knows which tab is selected: an [IndexedStack] keeps the other
/// tabs' tickers running, so Flutter cannot say) and not covered by an opaque page (its tickers are then disabled). [onRefresh] must not throw.
class RefreshWhileVisible extends StatefulWidget {
  const RefreshWhileVisible({super.key, required this.onRefresh, this.every = const Duration(seconds: 30), this.active = true, required this.child});

  final Future<void> Function() onRefresh;
  final Duration every;

  /// False while the caller's tab is not the selected one.
  final bool active;
  final Widget child;

  @override
  State<RefreshWhileVisible> createState() => _RefreshWhileVisibleState();
}

class _RefreshWhileVisibleState extends State<RefreshWhileVisible> with WidgetsBindingObserver {
  ValueListenable<TickerModeData>? _visible;
  bool _foreground = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.getValuesNotifier(context);
    if (!identical(visible, _visible)) {
      _visible?.removeListener(_update);
      _visible = visible..addListener(_update);
      _update();
    }
  }

  @override
  void didUpdateWidget(RefreshWhileVisible old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _update();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final front = state == AppLifecycleState.resumed;
    if (front == _foreground || state == AppLifecycleState.inactive) return;
    _foreground = front;
    _update();
  }

  bool get _running => _timer != null;

  void _update() {
    final shouldRun = _foreground && widget.active && (_visible?.value.enabled ?? false);
    if (shouldRun && !_running) {
      _call();
      _timer = Timer.periodic(widget.every, (_) => _call());
    } else if (!shouldRun && _running) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _call() {
    unawaited(widget.onRefresh().catchError((Object _) {}));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _visible?.removeListener(_update);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
