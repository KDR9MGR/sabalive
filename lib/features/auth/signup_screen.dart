import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/errors.dart';
import '../../core/widgets/gradient_button.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';
import 'widgets/auth_scaffold.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _agree = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  List<(String, bool)> get _rules {
    final p = _password.text;
    return [
      ('At least 8 characters', p.length >= 8),
      ('One uppercase letter', p.contains(RegExp(r'[A-Z]'))),
      ('One number', p.contains(RegExp(r'[0-9]'))),
      ('One special character', p.contains(RegExp(r'[!@#\$%^&*(),.?":{}|<>]'))),
    ];
  }

  double get _strength =>
      _rules.where((r) => r.$2).length / _rules.length;

  bool get _canSubmit =>
      _agree &&
      _name.text.isNotEmpty &&
      _username.text.trim().isNotEmpty &&
      _email.text.contains('@') &&
      _strength == 1;

  Future<void> _submit() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final needsConfirmation = await context.read<AuthController>().signUp(
            name: _name.text,
            email: _email.text,
            username: _username.text,
            password: _password.text,
          );
      if (needsConfirmation && mounted) {
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: AppColors.bgElevated,
            title: const Text('Confirm your email'),
            content: Text(
                'We sent a confirmation link to ${_email.text.trim()}. '
                'Tap it, then come back and log in.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK')),
            ],
          ),
        );
        if (mounted) navigator.pop();
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = context.watch<AuthController>().busy;
    return AuthScaffold(
      showBack: true,
      title: 'Create Your Account',
      subtitle: 'Join millions of streamers and fans worldwide.',
      logoSize: 84,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _field(_name, 'Full Name', Icons.badge_outlined,
              onChanged: (_) => setState(() {})),
          const SizedBox(height: 12),
          _field(_email, 'Email Address', Icons.mail_outline_rounded,
              keyboard: TextInputType.emailAddress,
              onChanged: (_) => setState(() {})),
          const SizedBox(height: 12),
          _field(_username, 'Username', Icons.alternate_email_rounded),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: _obscure,
            onChanged: (_) => setState(() {}),
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
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: _strength == 0 ? null : _strength,
              minHeight: 5,
              backgroundColor: AppColors.surface,
              valueColor: AlwaysStoppedAnimation(
                _strength < 0.5
                    ? AppColors.danger
                    : _strength < 1
                        ? AppColors.gold
                        : AppColors.success,
              ),
            ),
          ),
          const SizedBox(height: 12),
          ..._rules.map((r) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(
                      r.$2 ? Icons.check_circle_rounded : Icons.circle_outlined,
                      size: 16,
                      color: r.$2 ? AppColors.success : AppColors.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Text(r.$1,
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 12.5)),
                  ],
                ),
              )),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: _agree,
                  onChanged: (v) => setState(() => _agree = v ?? false),
                  activeColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: 3),
                  child: Text(
                    'I agree to the Terms of Service and Privacy Policy',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 12.5, height: 1.4),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          GradientButton(
            label: 'Create Account',
            loading: busy,
            enabled: _canSubmit,
            onPressed: _submit,
          ),
          const SizedBox(height: 20),
          Center(
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: const Text.rich(TextSpan(
                text: 'Already have an account? ',
                style: TextStyle(color: AppColors.textSecondary),
                children: [
                  TextSpan(
                    text: 'Login',
                    style: TextStyle(
                        color: AppColors.primaryBright,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              )),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, IconData icon,
      {TextInputType? keyboard, ValueChanged<String>? onChanged}) {
    return TextField(
      controller: c,
      keyboardType: keyboard,
      onChanged: onChanged,
      decoration: InputDecoration(hintText: hint, prefixIcon: Icon(icon)),
    );
  }
}
