import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'features/auth/auth_flow.dart';
import 'features/calls/incoming_call_banner.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/shell/main_shell.dart';
import 'features/splash/splash_screen.dart';
import 'state/auth_controller.dart';
import 'state/calls_controller.dart';
import 'state/live_streams_controller.dart';
import 'state/session_controller.dart';
import 'state/theme_config_controller.dart';
import 'state/wallet_controller.dart';
import 'theme/app_theme.dart';

class SabaLiveApp extends StatelessWidget {
  const SabaLiveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthController()),
        ChangeNotifierProvider(create: (_) => WalletController()),
        ChangeNotifierProvider(create: (_) => SessionController()),
        ChangeNotifierProvider(create: (_) => LiveStreamsController()),
        ChangeNotifierProvider(create: (_) => CallsController()),
        ChangeNotifierProvider(create: (_) => ThemeConfigController()),
      ],
      child: Consumer<ThemeConfigController>(
        builder: (context, themeConfig, _) => MaterialApp(
          title: 'SABALIVE',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(
            primary: themeConfig.primary,
            secondary: themeConfig.secondary,
            fontFamilyOverride: themeConfig.fontFamily,
          ),
          home: const _RootGate(),
        ),
      ),
    );
  }
}

class _RootGate extends StatelessWidget {
  const _RootGate();

  @override
  Widget build(BuildContext context) {
    final status = context.watch<AuthController>().status;
    final Widget child = switch (status) {
      AuthStatus.unknown => const SplashScreen(),
      AuthStatus.onboarding => const OnboardingScreen(),
      AuthStatus.unauthenticated => const AuthFlow(),
      AuthStatus.authenticated => const MainShell(),
    };

    final switcher = AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      switchInCurve: Curves.easeOut,
      child: KeyedSubtree(key: ValueKey(status), child: child),
    );

    if (status != AuthStatus.authenticated) return switcher;
    return Stack(
      children: [switcher, const IncomingCallBanner()],
    );
  }
}
