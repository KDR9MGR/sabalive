import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/formatters.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/gradient_button.dart';
import '../../data/mock_data.dart';
import '../../data/models.dart';
import '../../data/social_repository.dart';
import '../../router/app_nav.dart';
import '../../state/auth_controller.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

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
            children: [
              _cover(context, user),
              const SizedBox(height: 56),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(user.name,
                      style: Theme.of(context).textTheme.titleLarge),
                  if (user.verified) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.verified_rounded,
                        color: AppColors.primaryBright, size: 18),
                  ],
                ],
              ),
              Text(user.username,
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 12.5)),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  user.bio.isEmpty ? 'Living the SABALIVE life ✨' : user.bio,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12.5, height: 1.5),
                ),
              ),
              const SizedBox(height: 16),
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
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: GradientButton(
                        label: 'Edit Profile',
                        height: 46,
                        onPressed: () => AppNav.editProfile(context),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinePillButton(
                        label: 'Go Live',
                        icon: Icons.podcasts_rounded,
                        height: 46,
                        onPressed: () => AppNav.goLive(context),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              _walletStrip(context, wallet),
              const SizedBox(height: 18),
              _badges(context, user),
              const SizedBox(height: 10),
              _menu(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cover(BuildContext context, AppUser user) {
    return SizedBox(
      height: 150,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            height: 130,
            decoration: const BoxDecoration(gradient: AppColors.brandGradient),
          ),
          Positioned(
            top: 12,
            right: 8,
            child: IconButton(
              onPressed: () => AppNav.settings(context),
              icon: const Icon(Icons.settings_outlined, color: Colors.white),
            ),
          ),
          Positioned(
            bottom: -44,
            left: 0,
            right: 0,
            child: Column(
              children: [
                AppAvatar(name: user.name, size: 96, ring: true),
                Transform.translate(
                  offset: const Offset(0, -14),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      gradient: AppColors.goldGradient,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.bg, width: 2),
                    ),
                    child: Text('Lv ${user.level}',
                        style: const TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w700,
                          fontSize: 10,
                          color: Color(0xFF3A1A5E),
                        )),
                  ),
                ),
              ],
            ),
          ),
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

  Widget _badges(BuildContext context, AppUser user) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Text('Badges',
              style: TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w600,
                  fontSize: 15)),
        ),
        SizedBox(
          height: 62,
          child: FutureBuilder<List<({String emoji, String name})>>(
            future: SocialRepository().userBadges(user.id),
            builder: (context, snap) {
              final badges = snap.data ?? const [];
              if (snap.connectionState == ConnectionState.done && badges.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Text('No badges yet — earn them by streaming & gifting.',
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
                );
              }
              return ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: badges.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, i) => Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: AppColors.tints[i % AppColors.tints.length],
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  alignment: Alignment.center,
                  child:
                      Text(badges[i].emoji, style: const TextStyle(fontSize: 24)),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _menu(BuildContext context) {
    final items = <(IconData, String, VoidCallback)>[
      (Icons.bar_chart_rounded, 'Creator Dashboard',
          () => AppNav.hostDashboard(context)),
      (Icons.account_balance_wallet_rounded, 'Wallet & Earnings',
          () => AppNav.wallet(context)),
      (Icons.storefront_rounded, 'Coin Reseller',
          () => AppNav.sellCoins(context)),
      (Icons.notifications_none_rounded, 'Notifications',
          () => AppNav.notifications(context)),
      (Icons.shield_outlined, 'Privacy & Safety',
          () => AppNav.settings(context)),
      (Icons.settings_outlined, 'Settings', () => AppNav.settings(context)),
      (Icons.help_outline_rounded, 'Help & Support',
          () => AppNav.settings(context)),
      (Icons.logout_rounded, 'Sign Out',
          () => context.read<AuthController>().signOut()),
    ];
    return Column(
      children: [
        for (final (icon, label, onTap) in items)
          ListTile(
            onTap: onTap,
            leading: Icon(icon,
                color: label == 'Sign Out'
                    ? AppColors.danger
                    : AppColors.primaryBright,
                size: 20),
            title: Text(label,
                style: TextStyle(
                    fontSize: 13.5,
                    color: label == 'Sign Out'
                        ? AppColors.danger
                        : AppColors.textPrimary)),
            trailing: label == 'Sign Out'
                ? null
                : const Icon(Icons.chevron_right_rounded,
                    color: AppColors.textMuted),
          ),
      ],
    );
  }
}
