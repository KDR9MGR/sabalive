import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/errors.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../data/models.dart';
import '../../../data/pk_battles_repository.dart';
import '../../../state/live_streams_controller.dart';
import '../../../theme/app_colors.dart';

/// Lists other hosts currently live in PK mode, waiting for an opponent.
/// Tapping one sends a real invite via [PkBattlesRepository.invite] and
/// returns the created battle so the caller can react immediately, without
/// waiting on a Realtime round trip for its own outgoing invite.
Future<PkBattleInfo?> showPkOpponentPicker(
  BuildContext context, {
  required String myStreamId,
}) {
  return showModalBottomSheet<PkBattleInfo>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.bgElevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (_) => _PkOpponentPickerSheet(myStreamId: myStreamId),
  );
}

class _PkOpponentPickerSheet extends StatefulWidget {
  const _PkOpponentPickerSheet({required this.myStreamId});
  final String myStreamId;

  @override
  State<_PkOpponentPickerSheet> createState() => _PkOpponentPickerSheetState();
}

class _PkOpponentPickerSheetState extends State<_PkOpponentPickerSheet> {
  String? _inviting;

  Future<void> _invite(LiveStream target) async {
    setState(() => _inviting = target.id);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final battle = await PkBattlesRepository().invite(widget.myStreamId, target.id);
      if (navigator.canPop()) navigator.pop(battle);
    } catch (e) {
      if (mounted) {
        setState(() => _inviting = null);
        messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final candidates = context
        .watch<LiveStreamsController>()
        .streams
        .where((s) => s.mode == LiveMode.pk && s.id != widget.myStreamId)
        .toList();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Challenge a PK streamer',
                style: TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w700,
                    fontSize: 16)),
            const SizedBox(height: 4),
            const Text('They need to accept before the battle starts',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
            const SizedBox(height: 16),
            if (candidates.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    Icon(Icons.bolt_rounded,
                        size: 40, color: AppColors.textMuted.withValues(alpha: 0.6)),
                    const SizedBox(height: 10),
                    const Text('No one else is live in PK mode right now.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textMuted, fontSize: 12.5)),
                  ],
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: AppColors.stroke),
                  itemBuilder: (_, i) {
                    final s = candidates[i];
                    final busy = _inviting == s.id;
                    return ListTile(
                      leading: AppAvatar(name: s.host.name, size: 40),
                      title: Text(s.host.name),
                      subtitle: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.bolt_rounded, color: AppColors.gold),
                      onTap: _inviting == null ? () => _invite(s) : null,
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
