import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../../core/widgets/remote_media.dart';
import '../../state/maintenance_controller.dart';
import '../../theme/app_colors.dart';
import '../../core/i18n/text.dart';

/// Covers the whole app while it is locked for maintenance or an emergency
/// lockdown: the Super Admin's title and message, and — when an end time is set —
/// a countdown worked out from the server's clock.
class MaintenanceScreen extends StatefulWidget {
  const MaintenanceScreen({super.key, required this.controller});
  final MaintenanceController controller;

  @override
  State<MaintenanceScreen> createState() => _MaintenanceScreenState();
}

class _MaintenanceScreenState extends State<MaintenanceScreen> {
  Timer? _tick;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    // the countdown moves every second
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    await widget.controller.refresh();
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final s = c.status;
    final remaining = c.remaining();
    final end = s.endsAt;
    final lockdown = s.isLockdown;

    return Material(
      key: const Key('maintenance-screen'),
      color: AppColors.bg,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (s.imageUrl != null)
                    SizedBox(
                      height: 180,
                      child: RemoteMedia(
                        s.imageUrl!,
                        fit: BoxFit.contain,
                        fallback: _icon(lockdown),
                      ),
                    )
                  else
                    _icon(lockdown),
                  const SizedBox(height: 24),
                  Text(
                    s.title.isEmpty ? "We'll be right back" : s.title,
                    key: const Key('maintenance-title'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w700,
                      fontSize: 22,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    s.message,
                    key: const Key('maintenance-message'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (!lockdown && end != null) ...[
                    const SizedBox(height: 28),
                    if (c.overdue) ...[
                      const Text(
                        'This is taking a little longer than expected.',
                        key: Key('maintenance-overdue'),
                        textAlign: TextAlign.center,
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        "We'll be back as soon as we can.",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                      ),
                    ] else ...[
                      Text(
                        formatCountdown(remaining ?? Duration.zero),
                        key: const Key('maintenance-countdown'),
                        style: const TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w700,
                          fontSize: 44,
                          letterSpacing: 2,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Expected completion: ${formatExpectedCompletion(end, c.serverNow())}',
                        key: const Key('maintenance-expected'),
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 28),
                  TextButton.icon(
                    onPressed: _checking ? null : _check,
                    icon: _checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Check again'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _icon(bool lockdown) => Container(
    width: 96,
    height: 96,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: (lockdown ? AppColors.danger : AppColors.primary).withValues(alpha: 0.16),
    ),
    child: Icon(
      lockdown ? Icons.shield_rounded : Icons.build_circle_rounded,
      size: 52,
      color: lockdown ? AppColors.danger : AppColors.primaryBright,
    ),
  );
}
