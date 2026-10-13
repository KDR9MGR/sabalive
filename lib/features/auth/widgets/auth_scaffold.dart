import 'package:flutter/material.dart' hide Text;

import '../../../core/widgets/aurora_background.dart';
import '../../../core/widgets/saba_logo.dart';
import '../../../theme/app_colors.dart';
import '../../../core/i18n/text.dart';

class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    this.subtitle,
    required this.child,
    this.showBack = false,
    this.logoSize = 104,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final bool showBack;
  final double logoSize;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: AuroraBackground(
        intensity: 0.7,
        child: SafeArea(
          child: Column(
            children: [
              if (showBack)
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                )
              else
                const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(child: SabaLogo(size: logoSize)),
                      const SizedBox(height: 28),
                      Text(title,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall),
                      if (subtitle != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          subtitle!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: AppColors.textSecondary, height: 1.5),
                        ),
                      ],
                      const SizedBox(height: 28),
                      child,
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The social sign-in buttons: one full-width banner per provider, stacked, each with the provider's mark and its
/// name ("Google", "Apple"). [onTap] receives the provider name.
class SocialRow extends StatelessWidget {
  const SocialRow({super.key, required this.onTap});
  final void Function(String provider) onTap;

  @override
  Widget build(BuildContext context) {
    Widget banner(String label, IconData icon, Color color) => Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('social-$label'),
            borderRadius: BorderRadius.circular(14),
            onTap: () => onTap(label),
            child: Container(
              height: 52,
              width: double.infinity,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.stroke),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: color, size: 28),
                  const SizedBox(width: 8),
                  Text(label,
                      style: const TextStyle(
                          fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 15, color: Colors.white)),
                ],
              ),
            ),
          ),
        );

    // Facebook isn't here — no provider configured on Supabase for it
    // and no product need yet. Add it back (with the provider configured)
    // if that changes.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        banner('Google', Icons.g_mobiledata_rounded, const Color(0xFFEA4335)),
        const SizedBox(height: 12),
        banner('Apple', Icons.apple_rounded, Colors.white),
      ],
    );
  }
}

class OrDivider extends StatelessWidget {
  const OrDivider({super.key, this.label = 'or continue with'});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Divider(color: AppColors.stroke)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(label,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
        ),
        Expanded(child: Divider(color: AppColors.stroke)),
      ],
    );
  }
}
