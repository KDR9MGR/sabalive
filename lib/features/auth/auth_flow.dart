import 'package:flutter/material.dart';

import 'forgot_password_screen.dart';
import 'login_screen.dart';
import 'otp_screen.dart';
import 'signup_screen.dart';

/// Self-contained navigator for the signed-out experience. When auth succeeds
/// the [AuthController] status flips and the root gate swaps this whole tree
/// for the main shell.
class AuthFlow extends StatelessWidget {
  const AuthFlow({super.key});

  @override
  Widget build(BuildContext context) {
    return Navigator(
      onGenerateRoute: (settings) {
        Widget page = switch (settings.name) {
          AuthRoutes.signup => const SignupScreen(),
          AuthRoutes.otp => OtpScreen(args: settings.arguments as OtpArgs?),
          AuthRoutes.forgot => const ForgotPasswordScreen(),
          _ => const LoginScreen(),
        };
        return PageRouteBuilder(
          settings: settings,
          transitionDuration: const Duration(milliseconds: 300),
          pageBuilder: (_, _, _) => page,
          transitionsBuilder: (_, anim, _, child) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, 0.03), end: Offset.zero)
                  .animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class AuthRoutes {
  static const login = '/login';
  static const signup = '/signup';
  static const otp = '/otp';
  static const forgot = '/forgot';
}

class OtpArgs {
  const OtpArgs({required this.phone, this.purpose = 'login'});
  final String phone;
  final String purpose;
}
