import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/maintenance_controller.dart';
import '../../theme/app_colors.dart';

/// A thin notice across the top while maintenance is coming (or running but the
/// app is still usable): "Maintenance starts in 00:14:32". Doesn't take taps.
class MaintenanceBanner extends StatefulWidget {
  const MaintenanceBanner({super.key, required this.controller});
  final MaintenanceController controller;

  @override
  State<MaintenanceBanner> createState() => _MaintenanceBannerState();
}

class _MaintenanceBannerState extends State<MaintenanceBanner> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final until = c.untilStart();
    final left = c.remaining();
    final text = until != null
        ? 'Maintenance starts in ${formatCountdown(until)}'
        : left != null && !c.overdue
        ? 'Maintenance in progress · ${formatCountdown(left)} left'
        : 'Maintenance in progress';
    return IgnorePointer(
      child: Material(
        key: const Key('maintenance-banner'),
        color: AppColors.gold.withValues(alpha: 0.95),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.build_rounded, size: 14, color: Color(0xFF241300)),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF241300),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
