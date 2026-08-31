import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/aurora_background.dart';
import '../../core/widgets/saba_logo.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..forward();

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        context.read<AuthController>().completeSplash();
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AuroraBackground(
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 3),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.7, end: 1),
                duration: const Duration(milliseconds: 900),
                curve: Curves.easeOutBack,
                builder: (context, v, child) =>
                    Transform.scale(scale: v, child: Opacity(opacity: v.clamp(0, 1), child: child)),
                child: SabaLogo(
                  size: MediaQuery.of(context).size.width * 0.62,
                ),
              ),
              const SizedBox(height: 24),
              Text('Go Live. Be a Star!',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 10),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 48),
                child: Text(
                  'Broadcast, connect and grow your fans worldwide.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary, height: 1.5),
                ),
              ),
              const Spacer(flex: 3),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: AnimatedBuilder(
                  animation: _c,
                  builder: (context, _) => ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: _c.value,
                      minHeight: 6,
                      backgroundColor: AppColors.surface,
                      valueColor:
                          const AlwaysStoppedAnimation(AppColors.primaryBright),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              const Text('Made for Live. Made for You. 💜',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
