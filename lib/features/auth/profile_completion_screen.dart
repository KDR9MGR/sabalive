import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../../core/i18n/text.dart';
import '../../core/utils/errors.dart';
import '../../core/widgets/gradient_button.dart';
import '../../data/countries.dart';
import '../../data/models.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';

/// The youngest age that may use the app.
const int kMinimumAge = 13;

/// The message for somebody under [kMinimumAge]. A literal (it is a translation key): a test keeps it in step with [kMinimumAge].
const String kUnderAgeMessage = 'You must be at least 13 years old to use SABALIVE.';

/// The latest birth date that is old enough on [now].
DateTime latestBirthDate(DateTime now) => DateTime(now.year - kMinimumAge, now.month, now.day);

/// Is somebody born on [dob] at least [kMinimumAge] on [now]?
bool oldEnough(DateTime dob, DateTime now) => !dob.isAfter(latestBirthDate(now));

/// Does this person still have to give their date of birth and country before they reach the home screen? Everyone does the first time after
/// this update (a new sign-up, or an account that never filled them in). A ghost account (a staff monitoring account) is never asked.
///
/// The date of birth is the signal: every account starts with the country "India" (a database default), so the country alone can't tell
/// who has chosen one. An account with a saved date of birth has completed this step.
bool needsProfileCompletion(AppUser? user) => user != null && !user.isGhost && (user.dateOfBirth == null || user.location.trim().isEmpty);

/// Reads the signed-in person from the auth controller and puts [ProfileCompletionGateView] in front of [child].
class ProfileCompletionGate extends StatelessWidget {
  const ProfileCompletionGate({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    return ProfileCompletionGateView(
      user: auth.user,
      onSave: (dob, country) => auth.updateProfile(location: country, dateOfBirth: dob),
      onSignOut: auth.signOut,
      child: child,
    );
  }
}

/// Shows [ProfileCompletionScreen] instead of [child] while [user] still has to give their date of birth and country, and [child] (the app) the
/// moment they have. While the profile is still being read ([user] null: a returning user at launch) a short wait avoids flashing the home screen
/// to someone who is about to be asked; if the profile can't be read (offline) the app opens as before.
class ProfileCompletionGateView extends StatefulWidget {
  const ProfileCompletionGateView({
    super.key,
    required this.user,
    required this.onSave,
    required this.onSignOut,
    required this.child,
    this.wait = const Duration(seconds: 4),
  });

  final AppUser? user;
  final Future<void> Function(DateTime dateOfBirth, String country) onSave;
  final Future<void> Function() onSignOut;
  final Widget child;
  final Duration wait;

  @override
  State<ProfileCompletionGateView> createState() => _ProfileCompletionGateViewState();
}

class _ProfileCompletionGateViewState extends State<ProfileCompletionGateView> {
  Timer? _timer;
  bool _gaveUpWaiting = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.wait, () {
      if (mounted) setState(() => _gaveUpWaiting = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    if (user == null) return _gaveUpWaiting ? widget.child : const _Waiting();
    if (needsProfileCompletion(user)) {
      return ProfileCompletionScreen(onSave: widget.onSave, onSignOut: widget.onSignOut);
    }
    return widget.child;
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting();

  @override
  Widget build(BuildContext context) =>
      Scaffold(backgroundColor: AppColors.bg, body: const Center(child: CircularProgressIndicator()));
}

/// "Complete your profile": date of birth and country, both required, then on to the home screen. Nothing here is optional and there is no
/// skip; the only other way out is signing out.
class ProfileCompletionScreen extends StatefulWidget {
  const ProfileCompletionScreen({
    super.key,
    required this.onSave,
    required this.onSignOut,
    this.initialCountry,
    this.now,
  });

  /// Saves the answers (the app writes them to the profile). Throwing shows the error under the button.
  final Future<void> Function(DateTime dateOfBirth, String country) onSave;
  final Future<void> Function() onSignOut;
  final String? initialCountry;

  /// "Today" for the age check (tests).
  final DateTime? now;

  @override
  State<ProfileCompletionScreen> createState() => _ProfileCompletionScreenState();
}

class _ProfileCompletionScreenState extends State<ProfileCompletionScreen> {
  DateTime? _dob;
  String? _country;
  bool _saving = false;
  String? _error;

  DateTime get _today => widget.now ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _country = widget.initialCountry;
  }

  Future<void> _pickDob() async {
    final now = _today;
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 18, now.month, now.day),
      firstDate: DateTime(now.year - 100),
      lastDate: latestBirthDate(now),
    );
    if (picked != null && mounted) setState(() => _dob = picked);
  }

  Future<void> _pickCountry() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => _CountrySheet(selected: _country),
    );
    if (picked != null && mounted) setState(() => _country = picked);
  }

  Future<void> _save() async {
    final dob = _dob;
    final country = _country;
    if (dob == null || country == null || _saving) return;
    if (!oldEnough(dob, _today)) {
      setState(() => _error = tr(kUnderAgeMessage));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(dob, country);
      // the gate swaps this screen for the app as soon as the profile reloads
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = friendlyError(e);
      });
    }
  }

  String _date(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final ready = _dob != null && _country != null;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Complete your profile',
                      key: ValueKey('complete-title'),
                      style: TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w700, fontSize: 24)),
                  const SizedBox(height: 8),
                  const Text('We need your date of birth and country before you continue.',
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 13.5, height: 1.45)),
                  const SizedBox(height: 28),
                  _label('Date of Birth'),
                  InkWell(
                    key: const ValueKey('complete-dob'),
                    onTap: _saving ? null : _pickDob,
                    borderRadius: BorderRadius.circular(10),
                    child: InputDecorator(
                      decoration: const InputDecoration(prefixIcon: Icon(Icons.cake_outlined)),
                      child: Text(_dob == null ? 'Select date of birth' : _date(_dob!),
                          style: TextStyle(color: _dob == null ? AppColors.textMuted : AppColors.textPrimary)),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(kUnderAgeMessage,
                      style: TextStyle(color: AppColors.textMuted, fontSize: 11.5)),
                  const SizedBox(height: 20),
                  _label('Country'),
                  InkWell(
                    key: const ValueKey('complete-country'),
                    onTap: _saving ? null : _pickCountry,
                    borderRadius: BorderRadius.circular(10),
                    child: InputDecorator(
                      decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.public_rounded), suffixIcon: Icon(Icons.arrow_drop_down_rounded)),
                      child: Text(_country ?? 'Select your country',
                          style: TextStyle(color: _country == null ? AppColors.textMuted : AppColors.textPrimary)),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(_error!, key: const ValueKey('complete-error'), style: const TextStyle(color: AppColors.danger, fontSize: 12.5)),
                  ],
                  const SizedBox(height: 28),
                  GradientButton(
                    key: const ValueKey('complete-continue'),
                    label: 'Continue',
                    loading: _saving,
                    enabled: ready,
                    onPressed: _save,
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: const ValueKey('complete-signout'),
                    onPressed: _saving ? null : () => unawaited(widget.onSignOut()),
                    child: const Text('Sign Out', style: TextStyle(color: AppColors.textMuted)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
      );
}

/// The searchable country list; pops with the English name that was tapped.
class _CountrySheet extends StatefulWidget {
  const _CountrySheet({required this.selected});
  final String? selected;

  @override
  State<_CountrySheet> createState() => _CountrySheetState();
}

class _CountrySheetState extends State<_CountrySheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final found = searchCountries(_query);
    final height = MediaQuery.of(context).size.height * 0.8;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.stroke, borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: TextField(
                key: const ValueKey('country-search'),
                autofocus: false,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Search country')),
              ),
            ),
            Expanded(
              child: found.isEmpty
                  ? const Center(child: Text('No country found', style: TextStyle(color: AppColors.textMuted)))
                  : ListView.builder(
                      itemCount: found.length,
                      itemBuilder: (context, i) {
                        final c = found[i];
                        return ListTile(
                          key: ValueKey('country-$c'),
                          dense: true,
                          title: Text(c),
                          trailing: c == widget.selected ? const Icon(Icons.check_rounded, color: AppColors.success) : null,
                          onTap: () => Navigator.of(context).pop(c),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
