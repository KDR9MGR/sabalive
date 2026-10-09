import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// How far a bottom-anchored control must rise to sit just above the keyboard.
///
/// The control rests [restInset] above the bottom of the screen (by default the system bar,
/// [MediaQueryData.viewPadding], which does not change while the keyboard moves), and the keyboard's top edge
/// is [MediaQueryData.viewInsets] up from the bottom, so the distance is the difference. Never negative.
double keyboardLiftFor(MediaQueryData mq, {double? restInset}) =>
    math.max(0, mq.viewInsets.bottom - (restInset ?? mq.viewPadding.bottom));

/// Wraps a live screen's layout so the keyboard cannot move the stage (video, seats, top bar).
///
/// Everything below sees the SYSTEM bars as constant and no keyboard at all, so nothing is laid out again
/// when the keyboard opens (relaying out and resizing a live video surface on every keyboard frame is slow
/// and can crash some phones). The few parts that should rise, the chat and the input bar, are wrapped in
/// [KeyboardLift], which paints them higher without touching the layout.
class KeyboardStable extends StatelessWidget {
  const KeyboardStable({super.key, required this.child, this.restInset});

  final Widget child;

  /// How far above the bottom of the screen the lifted controls rest. Null = the system bar's height. A screen
  /// that leaves more room under its input bar (the watch screens count the system bar twice) passes that.
  final double? restInset;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return _LiftScope(
      lift: keyboardLiftFor(mq, restInset: restInset),
      child: MediaQuery(
        data: mq.copyWith(padding: mq.viewPadding, viewInsets: EdgeInsets.zero),
        child: child,
      ),
    );
  }
}

class _LiftScope extends InheritedWidget {
  const _LiftScope({required this.lift, required super.child});

  final double lift;

  @override
  bool updateShouldNotify(_LiftScope old) => old.lift != lift;
}

/// Paints [child] above the keyboard (inside a [KeyboardStable]) without moving anything else.
/// Touches follow the painted position. Outside a [KeyboardStable] it does nothing.
class KeyboardLift extends StatelessWidget {
  const KeyboardLift({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final lift = context.dependOnInheritedWidgetOfExactType<_LiftScope>()?.lift ?? 0;
    // always a Transform, even at zero: swapping the wrapper when the keyboard opens would rebuild the
    // text field under it and drop its focus
    return Transform.translate(offset: Offset(0, -lift), child: child);
  }
}
