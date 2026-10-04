import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../../../state/auth_controller.dart';
import '../../../core/i18n/text.dart';

/// True when the signed-in account is a ghost (monitoring) ID. Ghosts can watch
/// any live without being seen, and can't act in one — the server refuses every
/// write — so the watch screens use this to hide the controls instead.
bool isGhostViewer(BuildContext context) =>
    context.read<AuthController>().user?.isGhost ?? false;

/// Stands in for the chat input / gift bar on a watch screen when the viewer is
/// a ghost.
class GhostWatchBar extends StatelessWidget {
  const GhostWatchBar({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(21),
            border: Border.all(color: Colors.white24),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.visibility_off_rounded, color: Colors.white70, size: 16),
              SizedBox(width: 8),
              Text(
                'Ghost view · nobody can see you here',
                style: TextStyle(color: Colors.white70, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
