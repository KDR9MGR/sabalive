import 'package:flutter/material.dart' hide Text;

import '../../data/models.dart';
import '../../data/social_repository.dart';
import '../../theme/app_colors.dart';
import '../widgets/app_avatar.dart';
import '../i18n/text.dart';

/// Lets the host pick one of the people watching right now — used by the
/// "Block viewer" tool. Returns the chosen viewer, or null if dismissed.
Future<AppUser?> pickViewer(
  BuildContext context, {
  required String streamId,
  required String hostId,
}) {
  return showModalBottomSheet<AppUser>(
    context: context,
    backgroundColor: AppColors.bgElevated,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _ViewerPicker(streamId: streamId, hostId: hostId),
  );
}

class _ViewerPicker extends StatelessWidget {
  const _ViewerPicker({required this.streamId, required this.hostId});
  final String streamId;
  final String hostId;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Remove a viewer',
              style: TextStyle(
                fontFamily: 'Poppins',
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              "They leave now and can't rejoin this live.",
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 380,
              child: FutureBuilder<List<AppUser>>(
                future: SocialRepository().currentViewers(streamId),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final viewers = [
                    for (final u in snap.data ?? const <AppUser>[])
                      if (u.id != hostId) u,
                  ];
                  if (viewers.isEmpty) {
                    return const Center(
                      child: Text(
                        'No one is watching yet.',
                        style: TextStyle(color: AppColors.textMuted),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: viewers.length,
                    itemBuilder: (context, i) {
                      final u = viewers[i];
                      return ListTile(
                        key: ValueKey('viewer-${u.id}'),
                        onTap: () => Navigator.pop(context, u),
                        leading: AppAvatar(
                          name: u.name,
                          imageUrl: u.avatarUrl,
                          size: 42,
                        ),
                        title: Text(
                          u.name,
                          style: const TextStyle(
                            fontFamily: 'Poppins',
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                          ),
                        ),
                        subtitle: Text(
                          'ID: ${u.displayId}',
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppColors.textMuted,
                          ),
                        ),
                        trailing: const Icon(
                          Icons.person_remove_alt_1_rounded,
                          color: AppColors.danger,
                        ),
                      );
                    },
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
