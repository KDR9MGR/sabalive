import 'package:flutter/material.dart';

import '../../core/utils/errors.dart';
import '../../core/widgets/gradient_button.dart';
import '../../data/agency_repository.dart';
import '../../theme/app_colors.dart';

/// Self-serve agency application. Files an `agencies` row (status defaults
/// 'pending') via `apply_for_agency`; an admin reviews and approves it
/// elsewhere (sabaliveadmin). ID document upload is deferred, same as
/// kyc_screen.dart — an optional text reference for now.
class ApplyAgencyScreen extends StatefulWidget {
  const ApplyAgencyScreen({super.key});

  @override
  State<ApplyAgencyScreen> createState() => _ApplyAgencyScreenState();
}

class _ApplyAgencyScreenState extends State<ApplyAgencyScreen> {
  final _repo = AgencyRepository();
  final _name = TextEditingController();
  final _holder = TextEditingController();
  final _whatsapp = TextEditingController();
  final _country = TextEditingController(text: 'India');
  final _reference = TextEditingController();

  bool _loading = true;
  bool _submitting = false;
  AgencyStatus? _existing;

  @override
  void initState() {
    super.initState();
    _repo.myApplication().then((s) {
      if (!mounted) return;
      setState(() {
        _existing = s;
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _holder.dispose();
    _whatsapp.dispose();
    _country.dispose();
    _reference.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final name = _name.text.trim();
    final holder = _holder.text.trim();
    final whatsapp = _whatsapp.text.trim();
    if (name.isEmpty || holder.isEmpty || whatsapp.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Agency name, holder name, and WhatsApp number are required'),
      ));
      return;
    }
    setState(() => _submitting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _repo.apply(
        name: name,
        holderName: holder,
        whatsapp: whatsapp,
        country: _country.text.trim(),
        reference: _reference.text.trim().isEmpty ? null : _reference.text.trim(),
      );
      if (!mounted) return;
      setState(() => _existing = AgencyStatus(name: name, status: 'pending', holderName: holder));
      messenger.showSnackBar(const SnackBar(content: Text('Application submitted for review')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Apply for Agency')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _existing != null
              ? _statusView(_existing!)
              : _form(),
    );
  }

  Widget _statusView(AgencyStatus s) {
    final (text, color) = switch (s.status) {
      'active' => ('Your agency "${s.name}" is approved ✓', AppColors.success),
      'inactive' => ('Your application for "${s.name}" was not approved.', AppColors.danger),
      _ => ('Your application for "${s.name}" is under review.', AppColors.gold),
    };
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(text, style: TextStyle(fontSize: 13, color: color)),
      ),
    );
  }

  Widget _form() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: [
        _label('Agency Name'),
        TextField(controller: _name),
        const SizedBox(height: 16),
        _label('Holder Name'),
        TextField(controller: _holder),
        const SizedBox(height: 16),
        _label('WhatsApp Number'),
        TextField(controller: _whatsapp, keyboardType: TextInputType.phone),
        const SizedBox(height: 16),
        _label('Country'),
        TextField(controller: _country),
        const SizedBox(height: 16),
        _label('Reference (optional)'),
        TextField(
          controller: _reference,
          decoration: const InputDecoration(hintText: 'Who referred you, if anyone'),
        ),
        const SizedBox(height: 24),
        GradientButton(
          label: 'Submit Application',
          loading: _submitting,
          onPressed: _submit,
        ),
      ],
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
      );
}
