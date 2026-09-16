import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/feature_flags.dart';
import '../../core/utils/errors.dart';
import '../../core/widgets/gradient_button.dart';
import '../../core/widgets/pills.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';
import 'auth_flow.dart';
import 'widgets/auth_scaffold.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  int _tab = 0; // 0 = Email/Phone, 1 = Username
  final _id = TextEditingController(text: '');
  final _password = TextEditingController(text: '');
  bool _obscure = true;
  bool _remember = true;

  @override
  void dispose() {
    _id.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<AuthController>().loginWithPassword(_id.text, _password.text);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  Future<void> _social(String provider) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<AuthController>().loginWithSocial(provider);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  void _loginWithOtp() {
    final phone = _id.text.trim();
    if (phone.isEmpty || phone.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter your phone number above first')),
      );
      return;
    }
    Navigator.pushNamed(context, AuthRoutes.otp, arguments: OtpArgs(phone: phone));
  }

  @override
  Widget build(BuildContext context) {
    final busy = context.watch<AuthController>().busy;
    return AuthScaffold(
      title: 'Welcome Back!',
      subtitle: 'Login to continue your journey',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedTabs(
            tabs: const ['Email / Phone', 'Username'],
            index: _tab,
            onChanged: (i) => setState(() => _tab = i),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _id,
            keyboardType:
                _tab == 0 ? TextInputType.emailAddress : TextInputType.text,
            decoration: InputDecoration(
              hintText: _tab == 0 ? 'Email or phone number' : 'Username',
              prefixIcon: Icon(
                  _tab == 0 ? Icons.alternate_email_rounded : Icons.person_outline_rounded),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _password,
            obscureText: _obscure,
            decoration: InputDecoration(
              hintText: 'Password',
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(_obscure
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.pushNamed(context, AuthRoutes.forgot),
              child: const Text('Forgot Password?',
                  style: TextStyle(color: AppColors.primaryBright, fontSize: 12.5)),
            ),
          ),
          Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: _remember,
                  onChanged: (v) => setState(() => _remember = v ?? false),
                  activeColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                ),
              ),
              const SizedBox(width: 8),
              const Text('Remember Me',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 16),
          GradientButton(label: 'Login', loading: busy, onPressed: _login),
          const SizedBox(height: 12),
          OutlinePillButton(
            label: 'Login with OTP',
            icon: Icons.sms_outlined,
            onPressed: _loginWithOtp,
          ),
          if (FeatureFlags.socialLoginEnabled) ...[
            const SizedBox(height: 22),
            const OrDivider(),
            const SizedBox(height: 16),
            SocialRow(onTap: _social),
          ],
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text("Don't have an account? ",
                  style: TextStyle(color: AppColors.textSecondary)),
              GestureDetector(
                onTap: () => Navigator.pushNamed(context, AuthRoutes.signup),
                child: const Text('Sign Up',
                    style: TextStyle(
                        color: AppColors.primaryBright,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
