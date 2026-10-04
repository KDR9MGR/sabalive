import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../../core/utils/errors.dart';
import '../../core/widgets/aurora_background.dart';
import '../../core/widgets/gradient_button.dart';
import '../../data/social_repository.dart';
import '../../theme/app_colors.dart';
import '../../core/i18n/text.dart';

/// Going live is enabled by an agency. Instead of pasting a host code, the user
/// types the agency's public ID; that agency (and the staff above it) sees the
/// request in the admin panel and approves or declines it. Approval makes the
/// user that agency's host, and this screen then opens [destination].
///
/// States: checking → (already has access: open) | banned | pending (waiting
/// for the agency) | form (first request, or after a decline).
class AgencyRequestScreen extends StatefulWidget {
  const AgencyRequestScreen({
    super.key,
    required this.repo,
    required this.destination,
  });

  final SocialRepository repo;
  final WidgetBuilder destination;

  @override
  State<AgencyRequestScreen> createState() => _AgencyRequestScreenState();
}

class _AgencyRequestScreenState extends State<AgencyRequestScreen>
    with WidgetsBindingObserver {
  final _agencyId = TextEditingController();
  Timer? _poll;
  HostGate? _gate;
  bool _checking = true;
  bool _sending = false;
  bool _askingAnother =
      false; // user chose "request a different agency" while pending
  String? _error;

  bool get _pending => _gate?.requestStatus == 'pending' && !_askingAnother;
  bool get _declined => _gate?.requestStatus == 'rejected';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _agencyId.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // came back from the background — the agency may have answered meanwhile
    if (state == AppLifecycleState.resumed && _pending) _check(quiet: true);
  }

  Future<void> _check({bool quiet = false}) async {
    if (!quiet) setState(() => _checking = true);
    try {
      final g = await widget.repo.hostGate();
      if (!mounted) return;
      if (g.hasAccess) {
        _poll?.cancel();
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: widget.destination),
        );
        return;
      }
      setState(() {
        _gate = g;
        _checking = false;
        if (!quiet) _error = null;
      });
      _syncPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (!quiet) _error = friendlyError(e);
        _checking = false;
      });
    }
  }

  /// While a request is waiting, look for the answer every few seconds.
  void _syncPolling() {
    if (_pending) {
      _poll ??= Timer.periodic(
        const Duration(seconds: 8),
        (_) => _check(quiet: true),
      );
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  Future<void> _send() async {
    final id = int.tryParse(_agencyId.text.trim());
    if (id == null) {
      setState(() => _error = 'Enter the agency ID, digits only');
      return;
    }
    if (_sending) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final name = await widget.repo.requestGoLive(id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Request sent to $name')));
      _agencyId.clear();
      _askingAnother = false;
      setState(() => _sending = false);
      await _check(quiet: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e);
        _sending = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final banned = _gate?.banned ?? false;
    return Scaffold(
      body: AuroraBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              children: [
                Row(
                  children: [
                    Text(
                      'Host Access',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
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
                    gradient: AppColors.primaryGradient,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    banned
                        ? Icons.gpp_bad_rounded
                        : _pending
                        ? Icons.hourglass_top_rounded
                        : Icons.business_rounded,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
                const SizedBox(height: 20),
                if (_checking && _gate == null)
                  const CircularProgressIndicator(
                    color: AppColors.primaryBright,
                  )
                else if (banned)
                  ..._banned()
                else if (_pending)
                  ..._waiting()
                else
                  ..._form(),
                const Spacer(flex: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _banned() => const [
    Text(
      'Access revoked',
      style: TextStyle(
        fontFamily: 'Poppins',
        fontWeight: FontWeight.w700,
        fontSize: 18,
      ),
    ),
    SizedBox(height: 8),
    Text(
      'Your host access has been withdrawn. Contact your agency.',
      textAlign: TextAlign.center,
      style: TextStyle(color: AppColors.textSecondary, height: 1.5),
    ),
  ];

  List<Widget> _waiting() {
    final name = _gate?.requestAgencyName ?? 'your agency';
    return [
      const Text(
        'Request sent',
        style: TextStyle(
          fontFamily: 'Poppins',
          fontWeight: FontWeight.w700,
          fontSize: 18,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Waiting for $name to approve you. You will be able to go live as soon '
        'as they do.',
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.textSecondary, height: 1.5),
      ),
      if (_error != null) ...[
        const SizedBox(height: 10),
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.danger, fontSize: 12.5),
        ),
      ],
      const SizedBox(height: 20),
      GradientButton(
        label: 'Check status',
        icon: Icons.refresh_rounded,
        loading: _checking,
        onPressed: _check,
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: () => setState(() {
          _askingAnother = true;
          _error = null;
          _syncPolling();
        }),
        child: const Text('Request a different agency'),
      ),
    ];
  }

  List<Widget> _form() {
    final declined = _declined && !_askingAnother;
    final by = _gate?.requestAgencyName;
    return [
      const Text(
        'Enter your agency ID',
        style: TextStyle(
          fontFamily: 'Poppins',
          fontWeight: FontWeight.w700,
          fontSize: 18,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        declined
            ? '${by ?? 'That agency'} declined your request. You can try again '
                  'or send it to another agency.'
            : 'Going live is enabled by an agency. Enter the ID your agency '
                  'gave you and they will get your request.',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: declined ? AppColors.danger : AppColors.textSecondary,
          height: 1.5,
        ),
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _agencyId,
        autofocus: true,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(12),
        ],
        style: const TextStyle(
          fontFamily: 'Poppins',
          fontWeight: FontWeight.w700,
          fontSize: 20,
          letterSpacing: 4,
        ),
        decoration: InputDecoration(hintText: tr('Agency ID')),
        onSubmitted: (_) => _send(),
      ),
      if (_error != null) ...[
        const SizedBox(height: 10),
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.danger, fontSize: 12.5),
        ),
      ],
      const SizedBox(height: 20),
      GradientButton(
        label: 'Send request',
        icon: Icons.send_rounded,
        loading: _sending,
        onPressed: _send,
      ),
    ];
  }
}
