import 'package:flutter/material.dart' hide Text;

import '../../../core/i18n/text.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../data/models.dart';
import '../../../data/social_repository.dart';
import '../../../router/app_nav.dart';
import '../../../state/pk_battle_controller.dart';
import '../../../theme/app_colors.dart';

/// A viewer taps the OTHER host's side of a PK battle (the right frame of a video battle, the blue half of an audio one): a short card,
/// and if they say yes they leave this room and open the other host's live, where they can chat, gift and take a seat. In the new room
/// the sides swap (its own host is on the left), so tapping the other side takes them back. Hosts never get this: they are in the
/// middle of their own live.
///
/// [fetchStream] and [switchTo] are the real lookup and navigation unless a test gives others.
Future<void> visitOpponentRoom(
  BuildContext context,
  PkBattleController controller, {
  Future<LiveStream?> Function(String streamId)? fetchStream,
  Future<void> Function(BuildContext context, LiveStream target)? switchTo,
}) async {
  final them = controller.opponent;
  final streamId = controller.opponentStreamId;
  if (them == null || streamId == null || !controller.fighting) return;

  final go = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: AppColors.bgElevated,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppAvatar(name: them.name, imageUrl: them.avatarUrl, frameUrl: them.frameUrl, size: 64),
            const SizedBox(height: 10),
            Text(
              them.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 6),
            const Text(
              'Join their room to chat, send gifts and take a seat there.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('pk-visit-go'),
                onPressed: () => Navigator.pop(sheet, true),
                child: Text("Go to ${them.name}'s room"),
              ),
            ),
            TextButton(
              key: const ValueKey('pk-visit-cancel'),
              onPressed: () => Navigator.pop(sheet, false),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    ),
  );
  if (go != true || !context.mounted) return;

  LiveStream? target;
  try {
    target = await (fetchStream ?? SocialRepository().streamById)(streamId);
  } catch (_) {
    // treated like "gone": the same message
  }
  if (!context.mounted) return;
  if (target == null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('That live is not available any more.')));
    return;
  }
  await (switchTo ?? AppNav.switchToLive)(context, target);
}

/// The small "switch" mark on the other host's side: it tells a viewer that this side can be tapped. Takes no taps itself.
class PkSwitchMark extends StatelessWidget {
  const PkSwitchMark({super.key});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), shape: BoxShape.circle),
      child: const Icon(Icons.swap_horiz_rounded, size: 16, color: Colors.white),
    ),
  );
}
