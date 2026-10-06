import 'package:flutter/material.dart' hide Text;
import 'package:url_launcher/url_launcher.dart';

import '../../core/i18n/text.dart';
import '../../core/widgets/gradient_button.dart';
import '../../state/remote_config_controller.dart';
import '../../theme/app_colors.dart';

typedef StoreLauncher = Future<bool> Function(Uri url);

Future<bool> _openStore(Uri url) => launchUrl(url, mode: LaunchMode.externalApplication);

/// Covers the whole app with "Update required" while this build is older than the server's minimum.
/// The app underneath stays mounted (nothing is torn down); it is simply unreachable.
class UpdateRequiredGate extends StatelessWidget {
  const UpdateRequiredGate({
    super.key,
    required this.controller,
    required this.child,
    this.launcher = _openStore,
  });

  final RemoteConfigController controller;
  final Widget child;
  final StoreLauncher launcher;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Stack(
        children: [
          child,
          if (controller.updateRequired)
            Positioned.fill(child: UpdateRequiredScreen(controller: controller, launcher: launcher)),
        ],
      ),
    );
  }
}

class UpdateRequiredScreen extends StatelessWidget {
  const UpdateRequiredScreen({super.key, required this.controller, this.launcher = _openStore});

  final RemoteConfigController controller;
  final StoreLauncher launcher;

  static const defaultMessage = 'A newer version of SABALIVE is available. Please update to keep using the app.';

  @override
  Widget build(BuildContext context) {
    final message = controller.config.message.isNotEmpty ? controller.config.message : defaultMessage;
    final url = controller.storeUrl;
    return Material(
      color: AppColors.bg,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.system_update_rounded, size: 64, color: AppColors.primaryBright),
                const SizedBox(height: 20),
                const Text(
                  'Update required',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w700, fontSize: 22, color: Colors.white),
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, height: 1.5, color: Colors.white70),
                ),
                const SizedBox(height: 28),
                if (url.isNotEmpty)
                  GradientButton(label: 'Update now', onPressed: () => launcher(Uri.parse(url))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
