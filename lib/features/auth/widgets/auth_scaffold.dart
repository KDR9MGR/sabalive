import 'package:flutter/material.dart';

import '../../../core/widgets/aurora_background.dart';
import '../../../core/widgets/saba_logo.dart';
import '../../../theme/app_colors.dart';

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

class SocialRow extends StatelessWidget {
  const SocialRow({super.key, required this.onTap});
  final void Function(String provider) onTap;

  @override
  Widget build(BuildContext context) {
    Widget btn(String label, IconData icon, Color color) => Expanded(
          child: GestureDetector(
            onTap: () => onTap(label),
            child: Container(
              height: 50,
              margin: const EdgeInsets.symmetric(horizontal: 5),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.stroke),
              ),
              child: Icon(icon, color: color),
            ),
          ),
        );

    return Row(
      children: [
        btn('Google', Icons.g_mobiledata_rounded, const Color(0xFFEA4335)),
        btn('Apple', Icons.apple_rounded, Colors.white),
        btn('Facebook', Icons.facebook_rounded, const Color(0xFF1877F2)),
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
        const Expanded(child: Divider(color: AppColors.stroke)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(label,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
        ),
        const Expanded(child: Divider(color: AppColors.stroke)),
      ],
    );
  }
}
