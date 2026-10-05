import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../state/active_live_session_controller.dart';

/// Keeps the system back gesture inside the app while a full-screen live is up.
///
/// Android 13+ asks the app *before* a back gesture happens whether Flutter wants
/// it (`SystemNavigator.setFrameworkHandlesBack`), and Flutter only says yes when
/// its Navigator can pop or a route blocks the pop. The live is not a route of the
/// root Navigator — it sits in an overlay — so with only the home page underneath
/// the answer was "no", and on Android 16 (where this is the only back path) the
/// system handled the gesture itself: the user was taken straight out of the live
/// instead of seeing "leave / end?" and the options over it. Blocking the pop on the
/// home route while a live is showing makes the answer "yes"; the back press then
/// reaches [ActiveLiveSessionController.handleBack] as before.
///
/// A minimized live is not in the way, so back behaves normally then.
class LiveBackGuard extends StatelessWidget {
  const LiveBackGuard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final liveOnScreen = context.select<ActiveLiveSessionController, bool>(
      (session) => session.isActive && !session.isMinimized,
    );
    return PopScope(canPop: !liveOnScreen, child: child);
  }
}
