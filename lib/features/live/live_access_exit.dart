import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/active_live_session_controller.dart';
import '../../theme/app_colors.dart';

/// Takes the user out of a live they may not be in — banned from live, banned
/// altogether, or removed by the host — and says why. Video and audio lives are
/// hosted by [ActiveLiveSessionController]; PK battles are ordinary pushed
/// routes, so they pass [popRoute].
void leaveLiveBecauseDenied(
  BuildContext context,
  String message, {
  bool popRoute = false,
}) {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));
  if (popRoute) {
    Navigator.of(context).maybePop();
  } else {
    context.read<ActiveLiveSessionController>().end();
  }
}

/// "You can't use live right now", with the reason (from
/// `Restrictions.liveBlockMessage`).
Future<void> showLiveBlockedDialog(BuildContext context, String message) {
  return showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: AppColors.bgElevated,
      title: const Text('Live unavailable'),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
