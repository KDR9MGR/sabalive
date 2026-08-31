import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/gradient_button.dart';
import '../../core/widgets/pills.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';
import 'widgets/auth_scaffold.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  int _tab = 0; // 0 email, 1 mobile
  final _target = TextEditingController();
  bool _sent = false;

  @override
  void dispose() {
    _target.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    await context.read<AuthController>().resetPassword(_target.text);
    if (mounted) setState(() => _sent = true);
  }

  @override
  Widget build(BuildContext context) {
    final busy = context.watch<AuthController>().busy;
    return AuthScaffold(
      showBack: true,
      title: _sent ? 'Check Your Inbox' : 'Forgot Password?',
      subtitle: _sent
          ? "We've sent a password reset link to\n${_target.text.isEmpty ? 'your account' : _target.text}"
          : "Enter your registered ${_tab == 0 ? 'email' : 'mobile number'} and we'll help you reset your password.",
      child: _sent
          ? Column(
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.primary.withValues(alpha: 0.15),
                    border: Border.all(color: AppColors.primary),
                  ),
                  child: const Icon(Icons.mark_email_read_rounded,
                      color: AppColors.primaryBright, size: 40),
                ),
                const SizedBox(height: 24),
                const Text(
                  'The link will expire in 15 minutes. Check your spam folder if you don\'t see it.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                ),
                const SizedBox(height: 24),
                GradientButton(
                  label: 'Back to Login',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedTabs(
                  tabs: const ['Email', 'Mobile'],
                  index: _tab,
                  onChanged: (i) => setState(() => _tab = i),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _target,
                  keyboardType: _tab == 0
                      ? TextInputType.emailAddress
                      : TextInputType.phone,
                  decoration: InputDecoration(
                    hintText: _tab == 0
                        ? 'nisha.sharma@email.com'
                        : '+91 98765 43210',
                    prefixIcon: Icon(_tab == 0
                        ? Icons.mail_outline_rounded
                        : Icons.phone_outlined),
                  ),
                ),
                const SizedBox(height: 20),
                GradientButton(
                  label: 'Send Reset Link',
                  loading: busy,
                  onPressed: _send,
                ),
                const SizedBox(height: 10),
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Back to Login',
                        style: TextStyle(color: AppColors.textSecondary)),
                  ),
                ),
              ],
            ),
    );
  }
}
