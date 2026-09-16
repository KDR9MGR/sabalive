import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/errors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/gradient_button.dart';
import '../../data/models.dart';
import '../../data/social_repository.dart';
import '../../router/app_nav.dart';
import '../../state/auth_controller.dart';
import '../../state/session_controller.dart';
import '../../theme/app_colors.dart';

/// Another user's profile — real `profiles` data, follow/unfollow, and a
/// shortcut into their live room if they're broadcasting.
class UserProfileScreen extends StatefulWidget {
  const UserProfileScreen({super.key, required this.user});
  final AppUser user;

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  final _repo = SocialRepository();
  late AppUser _user = widget.user;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final fresh = await _repo.profile(widget.user.id);
    if (fresh != null && mounted) setState(() => _user = fresh);
  }

  Future<void> _toggleFollow() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<SessionController>().toggleFollow(_user.id);
      await _refresh();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthController>().user;
    final isMe = me?.id == _user.id;
    final following = context.watch<SessionController>().isFollowing(_user.id);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const Spacer(),
                  if (!isMe)
                    IconButton(
                      onPressed: _overflowMenu,
                      icon: const Icon(Icons.more_vert_rounded),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Center(child: AppAvatar(name: _user.name, size: 96, ring: true)),
              const SizedBox(height: 12),
              Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_user.name,
                        style: Theme.of(context).textTheme.titleLarge),
                    if (_user.verified) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.verified_rounded,
                          color: AppColors.primaryBright, size: 18),
                    ],
                  ],
                ),
              ),
              Center(
                child: Text(_user.username,
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 12.5)),
              ),
              if (_user.bio.isNotEmpty) ...[
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Text(_user.bio,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12.5,
                          height: 1.5)),
                ),
              ],
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _stat('Followers', compactCount(_user.followers),
                        () => AppNav.followList(context, _user.id, followers: true)),
                    _dot(),
                    _stat('Following', compactCount(_user.following),
                        () => AppNav.followList(context, _user.id, followers: false)),
                    _dot(),
                    _stat('Fans', compactCount(_user.fans), null),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (!isMe)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      Expanded(
                        child: following
                            ? OutlinePillButton(
                                label: 'Following',
                                icon: Icons.check_rounded,
                                height: 46,
                                onPressed: _toggleFollow,
                              )
                            : GradientButton(
                                label: 'Follow',
                                height: 46,
                                loading: _busy,
                                onPressed: _toggleFollow,
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinePillButton(
                          label: 'Message',
                          icon: Icons.chat_bubble_outline_rounded,
                          height: 46,
                          onPressed: () => AppNav.chatWith(context, _user),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_user.isLive) ...[
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: GradientButton(
                    label: 'Watch Live',
                    icon: Icons.podcasts_rounded,
                    height: 46,
                    onPressed: () => AppNav.watchHostLive(context, _user),
                  ),
                ),
              ],
              const SizedBox(height: 28),
              Center(
                child: Text(
                  _user.isHost ? 'Host · Level ${_user.level}' : 'Level ${_user.level}',
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stat(String label, String value, VoidCallback? onTap) =>
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          children: [
            Text(value,
                style: const TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w700,
                    fontSize: 16)),
            Text(label,
                style:
                    const TextStyle(fontSize: 11, color: AppColors.textMuted)),
          ],
        ),
      );

  Widget _dot() => Container(width: 1, height: 28, color: AppColors.stroke);

  Future<void> _overflowMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.block_rounded, color: AppColors.danger),
              title: const Text('Block'),
              onTap: () => Navigator.pop(context, 'block'),
            ),
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Report'),
              onTap: () => Navigator.pop(context, 'report'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'block') {
      await _block();
    } else if (choice == 'report') {
      await _report();
    }
  }

  Future<void> _block() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await _repo.block(_user.id);
      messenger.showSnackBar(SnackBar(content: Text('Blocked ${_user.name}')));
      navigator.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  Future<void> _report() async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('Report reason',
                  style: TextStyle(
                      fontFamily: 'Poppins', fontWeight: FontWeight.w600)),
            ),
            for (final r in const [
              'Harassment or bullying',
              'Nudity or sexual content',
              'Spam or scam',
              'Hate speech',
              'Impersonation',
              'Something else',
            ])
              ListTile(title: Text(r), onTap: () => Navigator.pop(context, r)),
          ],
        ),
      ),
    );
    if (reason == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _repo.report(
        targetType: 'user',
        targetId: _user.id,
        reason: reason,
      );
      messenger.showSnackBar(
          const SnackBar(content: Text('Report submitted — thank you')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }
}
