import 'package:flutter/material.dart' hide Text;

import '../../core/i18n/text.dart';
import '../../core/utils/errors.dart';
import '../../data/models.dart';
import '../../data/social_repository.dart';
import '../../state/blocks_controller.dart';
import '../../theme/app_colors.dart';

const _reportReasons = [
  'Harassment or bullying',
  'Nudity or sexual content',
  'Spam or scam',
  'Hate speech',
  'Impersonation',
  'Something else',
];

/// The "⋯" menu for another user: Block and Report, plus View profile when the
/// caller can offer it (the chat screen can; the profile screen is already there).
/// Blocking leaves the screen it was opened from, since that screen is about
/// someone the user no longer wants to see.
///
/// [repo] is only for tests.
Future<void> showUserSafetyMenu(
  BuildContext context,
  AppUser user, {
  VoidCallback? onViewProfile,
  SocialRepository? repo,
}) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.bgElevated,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          if (onViewProfile != null)
            ListTile(
              leading: const Icon(Icons.person_outline_rounded),
              title: const Text('View profile'),
              onTap: () => Navigator.pop(sheet, 'profile'),
            ),
          ListTile(
            leading: const Icon(Icons.block_rounded, color: AppColors.danger),
            title: const Text('Block'),
            onTap: () => Navigator.pop(sheet, 'block'),
          ),
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('Report'),
            onTap: () => Navigator.pop(sheet, 'report'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (!context.mounted || choice == null) return;
  final social = repo ?? SocialRepository();
  switch (choice) {
    case 'profile':
      onViewProfile?.call();
    case 'block':
      await _block(context, user, social);
    case 'report':
      await _report(context, user, social);
  }
}

Future<void> _block(BuildContext context, AppUser user, SocialRepository repo) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  try {
    await repo.block(user.id);
    BlocksController.instance.markBlocked(user.id);
    messenger.showSnackBar(SnackBar(content: Text('Blocked ${user.name}')));
    navigator.pop();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
  }
}

Future<void> _report(BuildContext context, AppUser user, SocialRepository repo) async {
  final reason = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.bgElevated,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(14),
            child: Text(
              'Report reason',
              style: TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600),
            ),
          ),
          // scrolls when the screen is short (a small phone, or landscape)
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final r in _reportReasons)
                  ListTile(title: Text(r), onTap: () => Navigator.pop(sheet, r)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  if (reason == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await repo.report(targetType: 'user', targetId: user.id, reason: reason);
    messenger.showSnackBar(
      const SnackBar(content: Text('Report submitted — thank you')),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
  }
}
