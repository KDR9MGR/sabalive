import 'package:flutter/material.dart';

import '../../core/utils/errors.dart';
import '../../core/widgets/gradient_button.dart';
import '../../data/social_repository.dart';
import '../../theme/app_colors.dart';

/// Host identity verification. Alpha: captures document type + an optional
/// reference/URL and files a `kyc_verifications` row (self-insert RLS); an
/// admin reviews it. File upload comes with Supabase Storage later.
class KycScreen extends StatefulWidget {
  const KycScreen({super.key});

  @override
  State<KycScreen> createState() => _KycScreenState();
}

class _KycScreenState extends State<KycScreen> {
  final _repo = SocialRepository();
  final _ref = TextEditingController();
  String _docType = 'Aadhaar';
  bool _loading = true;
  bool _submitting = false;
  String _status = 'none';

  static const _types = ['Aadhaar', 'PAN', 'Passport', 'Driving licence', 'Voter ID'];

  @override
  void initState() {
    super.initState();
    _repo.kycStatus().then((s) {
      if (!mounted) return;
      setState(() {
        _status = s;
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _ref.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _repo.submitKyc(
        documentType: _docType,
        documentUrl: _ref.text.trim().isEmpty ? null : _ref.text.trim(),
      );
      if (!mounted) return;
      setState(() => _status = 'pending');
      messenger.showSnackBar(
          const SnackBar(content: Text('KYC submitted for review')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Identity Verification')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
              children: [
                _statusBanner(),
                const SizedBox(height: 20),
                const Text('Document type',
                    style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  initialValue: _docType,
                  items: [
                    for (final t in _types)
                      DropdownMenuItem(value: t, child: Text(t)),
                  ],
                  onChanged: (v) => setState(() => _docType = v ?? _docType),
                ),
                const SizedBox(height: 16),
                const Text('Document number / reference (optional)',
                    style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                const SizedBox(height: 6),
                TextField(
                  controller: _ref,
                  decoration: const InputDecoration(hintText: 'e.g. last 4 digits'),
                ),
                const SizedBox(height: 24),
                GradientButton(
                  label: _status == 'pending'
                      ? 'Awaiting review'
                      : 'Submit for verification',
                  loading: _submitting,
                  onPressed: _status == 'pending' || _status == 'verified'
                      ? null
                      : _submit,
                ),
              ],
            ),
    );
  }

  Widget _statusBanner() {
    final (text, color) = switch (_status) {
      'verified' => ('You are verified ✓', AppColors.success),
      'pending' => ('Your verification is under review.', AppColors.gold),
      'rejected' => ('Previous submission was rejected — you can re-submit.',
          AppColors.danger),
      _ => ('Verify your identity to unlock withdrawals and a verified badge.',
          AppColors.textMuted),
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text, style: TextStyle(fontSize: 12.5, color: color)),
    );
  }
}
