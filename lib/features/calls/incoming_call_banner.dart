import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/app_avatar.dart';
import '../../data/calls_repository.dart';
import '../../state/calls_controller.dart';
import '../../theme/app_colors.dart';
import 'call_screen.dart';

/// Sits on top of the app shell; shows an accept/decline card whenever
/// [CallsController.incoming] is set.
class IncomingCallBanner extends StatelessWidget {
  const IncomingCallBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final call = context.watch<CallsController>().incoming;
    if (call == null) return const SizedBox.shrink();
    return Positioned(
      top: MediaQuery.of(context).padding.top + 10,
      left: 12,
      right: 12,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: AppColors.brandGradient,
            borderRadius: BorderRadius.circular(20),
            boxShadow: const [
              BoxShadow(color: Colors.black45, blurRadius: 24, offset: Offset(0, 8)),
            ],
          ),
          child: Row(
            children: [
              AppAvatar(name: call.otherName, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(call.otherName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontFamily: 'Poppins',
                            fontWeight: FontWeight.w600,
                            fontSize: 14)),
                    Text(
                        'Incoming ${call.kind == CallKind.video ? 'video' : 'voice'} call',
                        style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
                  ],
                ),
              ),
              _round(Icons.call_end_rounded, AppColors.danger,
                  () => _decline(context, call)),
              const SizedBox(width: 8),
              _round(Icons.call_rounded, const Color(0xFF22C55E),
                  () => _accept(context, call)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _accept(BuildContext context, CallInfo call) async {
    final controller = context.read<CallsController>();
    final navigator = Navigator.of(context, rootNavigator: true);
    try {
      await CallsRepository().setStatus(call.id, 'accepted');
    } catch (_) {}
    controller.clearIncoming();
    navigator.push(MaterialPageRoute(
      builder: (_) => CallScreen(call: call, outgoing: false),
    ));
  }

  Future<void> _decline(BuildContext context, CallInfo call) async {
    final controller = context.read<CallsController>();
    try {
      await CallsRepository().setStatus(call.id, 'declined');
    } catch (_) {}
    controller.clearIncoming();
  }

  Widget _round(IconData icon, Color bg, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      );
}
