import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/utils/avatar_picker.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/gradient_button.dart';
import '../../core/widgets/level_star.dart';
import '../../data/mock_data.dart';
import '../../data/models.dart';
import '../../router/app_nav.dart';
import '../../state/auth_controller.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';
import 'blocked_users_screen.dart';
import 'widgets/equipped_cosmetics.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _uploadingPhoto = false;

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthController>().user ?? Mock.me;
    final wallet = context.watch<WalletController>();

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
                child: Row(
                  children: [
                    Text('My Profile', style: Theme.of(context).textTheme.headlineSmall),
                    const Spacer(),
                    IconButton(
                      onPressed: () => AppNav.settings(context),
                      icon: const Icon(Icons.settings_outlined),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _photo(context, user),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(user.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.titleMedium),
                              ),
                              if (user.verified) ...[
                                const SizedBox(width: 6),
                                const Icon(Icons.verified_rounded,
                                    color: AppColors.primaryBright, size: 16),
                              ],
                            ],
                          ),
                          const SizedBox(height: 3),
                          _copyableLine(context, 'ID: ${user.displayId}'),
                          const SizedBox(height: 6),
                          EquippedCosmetics(profileId: user.id),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              if (user.gender != null)
                                _pill(
                                  icon: _genderIcon(user.gender!),
                                  text: _genderLabel(user.gender!),
                                  bg: AppColors.success.withValues(alpha: 0.18),
                                  fg: AppColors.success,
                                ),
                              // Wealth (gold star) and Charm (shiny purple star);
                              // tapping opens the My Level screen.
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => AppNav.myLevel(context),
                                child: LevelStars(
                                  wealth: user.wealthLevel,
                                  charm: user.charmLevel,
                                  size: 26,
                                ),
                              ),
                              _pill(
                                icon: Icons.diamond_rounded,
                                text: compactCount(wallet.diamonds),
                                bg: AppColors.primary.withValues(alpha: 0.18),
                                fg: AppColors.primaryBright,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _stat(context, 'Followers', compactCount(user.followers),
                        () => AppNav.followList(context, user.id, followers: true)),
                    _divider(),
                    _stat(context, 'Following', compactCount(user.following),
                        () => AppNav.followList(context, user.id, followers: false)),
                    _divider(),
                    _stat(context, 'Fans', compactCount(user.fans), null),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (user.bio.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(user.bio,
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 12.5, height: 1.5)),
                ),
              if (user.bio.isNotEmpty) const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: GradientButton(
                  label: 'Edit Profile',
                  height: 46,
                  onPressed: () => AppNav.editProfile(context),
                ),
              ),
              const SizedBox(height: 18),
              _vipBanner(context),
              const SizedBox(height: 16),
              _walletStrip(context, wallet),
              const SizedBox(height: 20),
              _menuGrid(context, user),
              const SizedBox(height: 8),
              _signOut(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _photo(BuildContext context, AppUser user) {
    return GestureDetector(
      onTap: _uploadingPhoto
          ? null
          : () => pickAndUploadAvatar(context,
              onBusyChanged: (busy) {
                if (mounted) setState(() => _uploadingPhoto = busy);
              }),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AppAvatar(name: user.name, imageUrl: user.avatarUrl, size: 92, ring: true),
          if (_uploadingPhoto)
            Positioned.fill(
              child: Container(
                decoration: const BoxDecoration(
                    shape: BoxShape.circle, color: Colors.black54),
                alignment: Alignment.center,
                child: const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
              ),
            ),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                gradient: AppColors.primaryGradient,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.bg, width: 2),
              ),
              child: const Icon(Icons.camera_alt_rounded, size: 13, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  IconData _genderIcon(String g) => switch (g) {
        'female' => Icons.female_rounded,
        'male' => Icons.male_rounded,
        _ => Icons.transgender_rounded,
      };

  String _genderLabel(String g) => switch (g) {
        'female' => 'F',
        'male' => 'M',
        _ => 'O',
      };

  Widget _pill({
    required IconData icon,
    required String text,
    required Color bg,
    required Color fg,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 3),
          Text(text,
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: fg)),
        ],
      ),
    );
  }

  Widget _copyableLine(BuildContext context, String text) {
    return GestureDetector(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Copied "$text"'), duration: const Duration(seconds: 1)),
          );
        }
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5)),
          const SizedBox(width: 4),
          const Icon(Icons.copy_rounded, size: 13, color: AppColors.textMuted),
        ],
      ),
    );
  }

  Widget _stat(
          BuildContext context, String label, String value, VoidCallback? onTap) =>
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

  Widget _divider() =>
      Container(width: 1, height: 28, color: AppColors.stroke);

  Widget _vipBanner(BuildContext context) {
    return GestureDetector(
      onTap: () => _soon(context, 'VIP'),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          gradient: AppColors.goldGradient,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Row(
          children: [
            Icon(Icons.diamond_rounded, color: Color(0xFF3A1A5E), size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text('VIP  ·  Luxury Privileges',
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: Color(0xFF3A1A5E),
                  )),
            ),
            Icon(Icons.chevron_right_rounded, color: Color(0xFF3A1A5E)),
          ],
        ),
      ),
    );
  }

  Widget _walletStrip(BuildContext context, WalletController wallet) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Row(
        children: [
          _walletCell(Icons.monetization_on_rounded, AppColors.coin, 'Coins',
              compactCount(wallet.coins)),
          Container(width: 1, height: 34, color: AppColors.stroke),
          _walletCell(Icons.diamond_rounded, AppColors.diamond, 'Diamonds',
              compactCount(wallet.diamonds)),
          Container(width: 1, height: 34, color: AppColors.stroke),
          Expanded(
            child: GestureDetector(
              onTap: () => AppNav.wallet(context),
              child: const Column(
                children: [
                  Icon(Icons.account_balance_wallet_rounded,
                      color: AppColors.primaryBright, size: 20),
                  SizedBox(height: 4),
                  Text('Wallet',
                      style: TextStyle(
                          fontSize: 11, color: AppColors.textSecondary)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _walletCell(IconData icon, Color color, String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
          Text(label,
              style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
        ],
      ),
    );
  }

  void _soon(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$feature is coming soon')),
    );
  }

  Widget _menuGrid(BuildContext context, AppUser user) {
    final items = <(IconData, String, VoidCallback)>[
      (Icons.bar_chart_rounded, 'Creator Dashboard', () => AppNav.hostDashboard(context)),
      (Icons.account_balance_wallet_rounded, 'Wallet & Earnings', () => AppNav.wallet(context)),
      (Icons.storefront_rounded, 'Store', () => AppNav.store(context)),
      (Icons.military_tech_rounded, 'My Level', () => AppNav.myLevel(context)),
      (Icons.shopping_bag_outlined, 'My Bag', () => AppNav.bag(context)),
      (Icons.apartment_rounded, 'Apply for Agency', () => AppNav.applyAgency(context)),
      (Icons.workspace_premium_rounded, 'Badges', () => AppNav.badges(context, user.id)),
      (Icons.person_add_alt_1_rounded, 'Invite a Friend', () => AppNav.referrals(context)),
      (Icons.visibility_outlined, 'Profile Visitors', () => AppNav.profileVisitors(context)),
      (
        Icons.block_rounded,
        'Blocked Users',
        () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const BlockedUsersScreen())),
      ),
      (Icons.auto_awesome_outlined, 'Room Effects', () => _soon(context, 'Room Effects')),
      (Icons.feedback_outlined, 'Feedback', () => AppNav.feedback(context)),
      (Icons.notifications_none_rounded, 'Notifications', () => AppNav.notifications(context)),
      (Icons.translate_rounded, 'Language', () => _soon(context, 'Language selection')),
      (Icons.shield_outlined, 'Privacy & Safety', () => AppNav.settings(context)),
      (Icons.help_outline_rounded, 'Help & Support', () => AppNav.settings(context)),
      (Icons.groups_rounded, 'Family', () => _soon(context, 'Family')),
      (Icons.settings_outlined, 'Settings', () => AppNav.settings(context)),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 0.86,
        children: [
          for (final (icon, label, onTap) in items) _gridTile(icon, label, onTap),
        ],
      ),
    );
  }

  Widget _gridTile(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.stroke),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: AppColors.primaryBright, size: 23),
          ),
          const SizedBox(height: 6),
          Text(label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 10.5, color: AppColors.textSecondary, height: 1.2)),
        ],
      ),
    );
  }

  Widget _signOut(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: ListTile(
        onTap: () => context.read<AuthController>().signOut(),
        leading: const Icon(Icons.logout_rounded, color: AppColors.danger, size: 20),
        title: const Text('Sign Out',
            style: TextStyle(fontSize: 13.5, color: AppColors.danger)),
      ),
    );
  }
}
