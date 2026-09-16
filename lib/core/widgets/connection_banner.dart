import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Thin strip shown while the Agora connection is reconnecting after a
/// network drop, so a host/viewer isn't left staring at a frozen stream
/// with no explanation.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key, required this.reconnecting});
  final bool reconnecting;

  @override
  Widget build(BuildContext context) {
    if (!reconnecting) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: AppColors.danger,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: const Text(
        'Reconnecting…',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}
