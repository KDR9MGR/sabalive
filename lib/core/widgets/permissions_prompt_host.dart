import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../services/permissions_flow.dart';
import '../../theme/app_colors.dart';

/// Wraps the signed-in app and, the first time it appears on an install, shows
/// a short explainer and then asks for the permissions the app needs.
class PermissionsPromptHost extends StatefulWidget {
  const PermissionsPromptHost({super.key, required this.child, this.flow});

  final Widget child;

  /// Injectable for tests; defaults to the real device flow.
  final PermissionsFlow? flow;

  @override
  State<PermissionsPromptHost> createState() => _PermissionsPromptHostState();
}

class _PermissionsPromptHostState extends State<PermissionsPromptHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePrompt());
  }

  Future<void> _maybePrompt() async {
    if (!mounted) return;
    final flow = widget.flow ??
        PermissionsFlow(DevicePermissionGateway(), isAndroid: Platform.isAndroid);
    await flow.run(confirm: _explain);
  }

  Future<bool> _explain() async {
    if (!mounted) return false;
    final agreed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: AppColors.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (context) => const _Explainer(),
    );
    return agreed ?? false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Explainer extends StatelessWidget {
  const _Explainer();

  static const _items = [
    (Icons.videocam_rounded, 'Camera', 'Go live and show your video'),
    (Icons.mic_rounded, 'Microphone', 'Talk in live rooms and audio rooms'),
    (
      Icons.notifications_rounded,
      'Notifications',
      'Know when someone messages you or goes live'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Allow access',
              style: TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w700,
                  fontSize: 18),
            ),
            const SizedBox(height: 6),
            const Text(
              'SABALIVE works best with these. You can change them any time in '
              'your phone settings.',
              style: TextStyle(color: AppColors.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 16),
            for (final (icon, title, why) in _items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, color: AppColors.primaryBright, size: 24),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 14)),
                          Text(why,
                              style: const TextStyle(
                                  color: AppColors.textMuted, fontSize: 12.5)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Continue'),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Not now'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
