import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'config/feature_flags.dart';
import 'core/widgets/permissions_prompt_host.dart';
import 'features/auth/auth_flow.dart';
import 'features/calls/incoming_call_banner.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/shell/main_shell.dart';
import 'features/splash/splash_screen.dart';
import 'state/active_live_session_controller.dart';
import 'state/auth_controller.dart';
import 'state/calls_controller.dart';
import 'state/live_streams_controller.dart';
import 'state/session_controller.dart';
import 'state/theme_config_controller.dart';
import 'state/wallet_controller.dart';
import 'theme/app_theme.dart';

/// Lets code outside the widget tree (the share-link deep-link handler)
/// navigate without needing a BuildContext of its own.
final rootNavigatorKey = GlobalKey<NavigatorState>();

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
        ChangeNotifierProvider(create: (_) => ActiveLiveSessionController()),
      ],
      child: Consumer<ThemeConfigController>(
        builder: (context, themeConfig, _) => MaterialApp(
          navigatorKey: rootNavigatorKey,
          title: 'SABALIVE',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(
            primary: themeConfig.primary,
            secondary: themeConfig.secondary,
            fontFamilyOverride: themeConfig.fontFamily,
          ),
          home: const _RootGate(),
          // A true root-level overlay, above the Navigator's own routes
          // entirely — not tied to any single route's position in the
          // stack the way a Stack inside _RootGate would be (that only
          // renders while _RootGate's own route is topmost; push anything
          // else — a profile, a chat — and it'd be covered). This is what
          // lets a minimized (or even full-screen) live session stay
          // mounted and interactive-underneath no matter where the user
          // navigates elsewhere in the app.
          builder: (context, child) =>
              Stack(children: [?child, const _ActiveLiveSessionOverlay()]),
        ),
      ),
    );
  }
}

/// Renders whichever live screen is currently active (video/audio
/// broadcast or watch — PK never registers here, see
/// ActiveLiveSessionController's own doc comment). The screen's own
/// build() decides internally whether that's its full UI or just the
/// small floating bubble, exactly as it already did when this was a
/// pushed route — only WHERE it's mounted changed, not that logic.
class _ActiveLiveSessionOverlay extends StatelessWidget {
  const _ActiveLiveSessionOverlay();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<ActiveLiveSessionController>();
    if (!session.isActive) return const SizedBox.shrink();
    // This overlay sits OUTSIDE MaterialApp's real Navigator — it's a
    // sibling of `child` in the builder above, not a descendant of it
    // (WidgetsApp builds its Navigator separately and only ever hands it
    // down as `child`). Without a Navigator of its own, every showDialog/
    // showModalBottomSheet/Navigator.pop the live screens use internally
    // (end-stream confirm, leave/minimize/follow, gift sheet, seat menu…)
    // fails to find one and silently throws — which is exactly why the
    // close button and back button stopped responding once these screens
    // moved out of the pushed-route Navigator.
    //
    // A plain PageRouteBuilder/ModalRoute was tried first and made things
    // WORSE: ModalRoute wraps its content in _ModalScope (focus trapping,
    // Offstage, an IgnorePointer), and that wrapping hit-tests across the
    // Overlay's FULL bounds regardless of what the route's own content
    // actually paints there — confirmed empirically (see
    // test/minimize_hittest_test.dart), it's what silently absorbed every
    // tap on the rest of the app while a session was minimized, even far
    // from the bubble. _TransparentRoute below is a bare OverlayRoute
    // instead — no _ModalScope — so it still gives showDialog/Navigator.pop
    // a real Navigator to resolve against, but hit-tests only where the
    // live screen's own content (the bubble, or the full screen) actually
    // is, exactly like before this overlay had a Navigator at all.
    return HeroControllerScope.none(
      child: Navigator(
        onGenerateRoute: (_) =>
            _TransparentRoute(builder: (context) => session.buildActive(context)),
      ),
    );
  }
}

/// Hosts content in the Navigator's Overlay without ModalRoute's
/// _ModalScope wrapping — see the doc comment above on why that wrapping
/// can't be used here. Just enough of a Route for showDialog/Navigator.pop
/// to have something to resolve/push against.
class _TransparentRoute extends OverlayRoute<void> {
  _TransparentRoute({required this.builder});
  final WidgetBuilder builder;

  @override
  Iterable<OverlayEntry> createOverlayEntries() {
    return [OverlayEntry(builder: builder)];
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
      AuthStatus.authenticated => const PermissionsPromptHost(child: MainShell()),
    };

    final switcher = AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      switchInCurve: Curves.easeOut,
      child: KeyedSubtree(key: ValueKey(status), child: child),
    );

    if (status != AuthStatus.authenticated || !FeatureFlags.callsEnabled) {
      return switcher;
    }
    return Stack(children: [switcher, const IncomingCallBanner()]);
  }
}
