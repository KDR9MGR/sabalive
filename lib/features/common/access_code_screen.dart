import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/errors.dart';
import '../../core/widgets/aurora_background.dart';
import '../../core/widgets/gradient_button.dart';
import '../../theme/app_colors.dart';

typedef AccessInfo = ({bool hasAccess, bool staff, bool banned, DateTime? expiresAt});

/// Reusable gate: a feature (Go Live, Sell Coins, …) is unlocked only after
/// redeeming a code issued by an agency/admin. Staff bypass automatically.
class AccessCodeScreen extends StatefulWidget {
  const AccessCodeScreen({
    super.key,
    required this.title,
    required this.blurb,
    required this.check,
    required this.redeem,
    required this.destination,
  });

  final String title;
  final String blurb;
  final Future<AccessInfo> Function() check;
  final Future<DateTime?> Function(String code) redeem;
  final WidgetBuilder destination;

  @override
  State<AccessCodeScreen> createState() => _AccessCodeScreenState();
}

class _AccessCodeScreenState extends State<AccessCodeScreen> {
  final _code = TextEditingController();
  bool _checking = true;
  bool _redeeming = false;
  bool _banned = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    try {
      final a = await widget.check();
      if (!mounted) return;
      if (a.hasAccess) {
        _open();
        return;
      }
      setState(() {
        _banned = a.banned;
        _checking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e);
        _checking = false;
      });
    }
  }

  void _open() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: widget.destination),
    );
  }

  Future<void> _redeem() async {
    final code = _code.text.trim();
    if (code.isEmpty || _redeeming) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _redeeming = true;
      _error = null;
    });
    try {
      final expiry = await widget.redeem(code);
      if (!mounted) return;
      final until = expiry == null
          ? ''
          : ' Valid until ${expiry.day}/${expiry.month}/${expiry.year}.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unlocked.$until')),
      );
      _open();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e);
        _redeeming = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AuroraBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              children: [
                Row(
                  children: [
                    Text(widget.title,
                        style: Theme.of(context).textTheme.headlineSmall),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const Spacer(),
                Container(
                  width: 84,
                  height: 84,
                  decoration: const BoxDecoration(
                      gradient: AppColors.primaryGradient, shape: BoxShape.circle),
                  child: Icon(
                      _banned
                          ? Icons.gpp_bad_rounded
                          : Icons.workspace_premium_rounded,
                      color: Colors.white,
                      size: 40),
                ),
                const SizedBox(height: 20),
                if (_checking)
                  const CircularProgressIndicator(color: AppColors.primaryBright)
                else if (_banned) ...[
                  const Text('Access revoked',
                      style: TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w700,
                          fontSize: 18)),
                  const SizedBox(height: 8),
                  const Text(
                    'This permission has been withdrawn. Contact your agency '
                    'for a new code.',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: AppColors.textSecondary, height: 1.5),
                  ),
                ] else ...[
                  const Text('Enter your code',
                      style: TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w700,
                          fontSize: 18)),
                  const SizedBox(height: 8),
                  Text(widget.blurb,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: AppColors.textSecondary, height: 1.5)),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _code,
                    autofocus: true,
                    textCapitalization: TextCapitalization.characters,
                    textAlign: TextAlign.center,
                    inputFormatters: [
                      _UpperCase(),
                      LengthLimitingTextInputFormatter(16),
                    ],
                    style: const TextStyle(
                        fontFamily: 'Poppins',
                        fontWeight: FontWeight.w700,
                        fontSize: 20,
                        letterSpacing: 4),
                    decoration: const InputDecoration(hintText: 'ABCD1234'),
                    onSubmitted: (_) => _redeem(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: AppColors.danger, fontSize: 12.5)),
                  ],
                  const SizedBox(height: 20),
                  GradientButton(
                    label: 'Unlock',
                    icon: Icons.lock_open_rounded,
                    loading: _redeeming,
                    onPressed: _redeem,
                  ),
                ],
                const Spacer(flex: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UpperCase extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue o, TextEditingValue n) =>
      n.copyWith(text: n.text.toUpperCase());
}
