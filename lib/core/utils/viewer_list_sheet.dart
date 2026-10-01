import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/social_repository.dart';
import '../../router/app_nav.dart';
import '../../theme/app_colors.dart';
import '../widgets/app_avatar.dart';

/// Who's watching a stream right now — public to any viewer, not just the
/// host. Tapping someone opens their profile.
Future<void> showViewerListSheet(BuildContext context, String streamId) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.bgElevated,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _ViewerListSheet(streamId: streamId),
  );
}

class _ViewerListSheet extends StatefulWidget {
  const _ViewerListSheet({required this.streamId});
  final String streamId;

  @override
  State<_ViewerListSheet> createState() => _ViewerListSheetState();
}

class _ViewerListSheetState extends State<_ViewerListSheet> {
  late final Future<List<AppUser>> _future =
      SocialRepository().currentViewers(widget.streamId);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Watching now',
                style: TextStyle(
                    fontFamily: 'Poppins', fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 12),
            SizedBox(
              height: 380,
              child: FutureBuilder<List<AppUser>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final viewers = snap.data ?? const [];
                  if (viewers.isEmpty) {
                    return const Center(
                      child: Text('No one is watching yet.',
                          style: TextStyle(color: AppColors.textMuted)),
                    );
                  }
                  return ListView.builder(
                    itemCount: viewers.length,
                    itemBuilder: (context, i) {
                      final u = viewers[i];
                      return ListTile(
                        onTap: () {
                          Navigator.pop(context);
                          AppNav.userProfile(context, u);
                        },
                        leading: AppAvatar(name: u.name, imageUrl: u.avatarUrl, size: 42),
                        title: Text(u.name,
                            style: const TextStyle(
                                fontFamily: 'Poppins',
                                fontWeight: FontWeight.w600,
                                fontSize: 13.5)),
                        subtitle: Text('ID: ${u.displayId}',
                            style: const TextStyle(
                                fontSize: 11.5, color: AppColors.textMuted)),
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
