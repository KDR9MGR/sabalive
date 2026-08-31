import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/gradient_button.dart';
import '../../core/widgets/otp_input.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';
import 'auth_flow.dart';
import 'widgets/auth_scaffold.dart';

class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key, this.args});
  final OtpArgs? args;

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  String _code = '';
  int _seconds = 30;
  Timer? _timer;
  bool _verified = false;

  String get _phone => widget.args?.phone ?? '+91 98765 43210';

  @override
  void initState() {
    super.initState();
    _startTimer();
    context.read<AuthController>().requestOtp(_phone);
  }

  void _startTimer() {
    _seconds = 30;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_seconds == 0) {
        t.cancel();
      } else {
        setState(() => _seconds--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _verify() async {
    final ok = await context.read<AuthController>().verifyOtp(_code);
    if (!mounted) return;
    if (ok) {
      setState(() => _verified = true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the 6-digit code to continue')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = context.watch<AuthController>().busy;
    return AuthScaffold(
      showBack: true,
      title: _verified ? "You're All Set!" : 'Enter OTP',
      subtitle: _verified
          ? 'Your number has been verified successfully.'
          : "We've sent a 6-digit code to\n$_phone",
      child: _verified
          ? Column(
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 84,
                  height: 84,
                  decoration: const BoxDecoration(
                      color: AppColors.success, shape: BoxShape.circle),
                  child: const Icon(Icons.check_rounded,
                      color: Colors.white, size: 46),
                ),
                const SizedBox(height: 28),
                GradientButton(
                  label: 'Continue',
                  onPressed: () => context.read<AuthController>().finishAuth(),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OtpInput(
                  onChanged: (v) => _code = v,
                  onCompleted: (v) {
                    _code = v;
                    _verify();
                  },
                ),
                const SizedBox(height: 20),
                Center(
                  child: _seconds > 0
                      ? Text(
                          'Resend OTP in 00:${_seconds.toString().padLeft(2, '0')}',
                          style: const TextStyle(
                              color: AppColors.textMuted, fontSize: 12.5),
                        )
                      : TextButton(
                          onPressed: () {
                            _startTimer();
                            context.read<AuthController>().requestOtp(_phone);
                          },
                          child: const Text('Resend OTP',
                              style: TextStyle(color: AppColors.primaryBright)),
                        ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.stroke),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.shield_outlined,
                          size: 18, color: AppColors.textMuted),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text('Your verification code is valid for 10 minutes.',
                            style: TextStyle(
                                color: AppColors.textSecondary, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                GradientButton(
                  label: 'Verify OTP',
                  loading: busy,
                  onPressed: _verify,
                ),
                const SizedBox(height: 10),
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Change Number',
                        style: TextStyle(color: AppColors.textSecondary)),
                  ),
                ),
              ],
            ),
    );
  }
}
