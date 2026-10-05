import 'package:flutter/material.dart' hide Text;

import '../../theme/app_colors.dart';
import '../i18n/text.dart';

/// Thin strip shown while the Agora connection is reconnecting after a
/// network drop, so a host/viewer isn't left staring at a frozen stream
/// with no explanation. [failure] is shown instead when the connection has
/// been given up on (Agora refused it, or the token expired) — it stays until
/// the connection comes back.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key, required this.reconnecting, this.failure});
  final bool reconnecting;
  final String? failure;

  @override
  Widget build(BuildContext context) {
    final message = failure ?? (reconnecting ? 'Reconnecting…' : null);
    if (message == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: AppColors.danger,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}
