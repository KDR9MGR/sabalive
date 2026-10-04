import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/errors.dart';
import '../../core/widgets/gradient_button.dart';
import '../../core/widgets/pills.dart';
import '../../data/feedback_repository.dart';
import '../../data/models.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';
import '../../core/i18n/text.dart';

/// Submit feedback (self-insert RLS on `feedback`) and see admin responses
/// to what you've filed before — real data, no mock, mirrors kyc_screen.dart's
/// submit-and-track shape.
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  int _tab = 0; // 0 = Feedback (submit), 1 = My Feedback

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Feedback')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: SegmentedTabs(
              tabs: const ['Feedback', 'My Feedback'],
              index: _tab,
              onChanged: (i) => setState(() => _tab = i),
            ),
          ),
          Expanded(
            child: _tab == 0 ? const _SubmitTab() : const _MyFeedbackTab(),
          ),
        ],
      ),
    );
  }
}

class _SubmitTab extends StatefulWidget {
  const _SubmitTab();

  @override
  State<_SubmitTab> createState() => _SubmitTabState();
}

class _SubmitTabState extends State<_SubmitTab> {
  final _repo = FeedbackRepository();
  final _body = TextEditingController();
  final _contactValue = TextEditingController();
  FeedbackKind _kind = FeedbackKind.appError;
  int _contactMethod = 0; // 0 = email, 1 = phone
  bool _submitting = false;

  static const _kinds = [
    (FeedbackKind.appError, 'App Error'),
    (FeedbackKind.suggestion, 'Suggestions'),
    (FeedbackKind.earningInfo, 'Earning Info'),
    (FeedbackKind.other, 'Other'),
  ];

  @override
  void dispose() {
    _body.dispose();
    _contactValue.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final text = _body.text.trim();
    if (text.isEmpty) return;
    setState(() => _submitting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _repo.submit(
        kind: _kind,
        body: text,
        contactMethod: _contactMethod == 0 ? 'email' : 'phone',
        contactValue:
            _contactValue.text.trim().isEmpty ? null : _contactValue.text.trim(),
      );
      if (!mounted) return;
      _body.clear();
      _contactValue.clear();
      messenger.showSnackBar(const SnackBar(content: Text('Feedback sent — thank you!')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: [
        const Text('Feedback Type',
            style: TextStyle(
                fontFamily: 'Poppins',
                fontWeight: FontWeight.w600,
                fontSize: 13.5)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (kind, label) in _kinds)
              ChoiceChip(
                label: Text(label),
                selected: _kind == kind,
                onSelected: (_) => setState(() => _kind = kind),
                selectedColor: AppColors.primary,
                labelStyle: TextStyle(
                  fontSize: 12,
                  color: _kind == kind ? Colors.white : AppColors.textSecondary,
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        const Text('Contact Information (optional)',
            style: TextStyle(
                fontFamily: 'Poppins',
                fontWeight: FontWeight.w600,
                fontSize: 13.5)),
        const SizedBox(height: 10),
        SegmentedTabs(
          tabs: const ['Email', 'Phone'],
          index: _contactMethod,
          onChanged: (i) => setState(() => _contactMethod = i),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _contactValue,
          keyboardType: _contactMethod == 0
              ? TextInputType.emailAddress
              : TextInputType.phone,
          decoration: InputDecoration(
            hintText: _contactMethod == 0
                ? 'Enter your email address'
                : 'Enter your phone number',
          ),
        ),
        const SizedBox(height: 20),
        const Text('Your Feedback',
            style: TextStyle(
                fontFamily: 'Poppins',
                fontWeight: FontWeight.w600,
                fontSize: 13.5)),
        const SizedBox(height: 10),
        TextField(
          controller: _body,
          maxLines: 5,
          decoration: InputDecoration(
            hintText: tr('Please describe your feedback in detail…'),
          ),
        ),
        const SizedBox(height: 24),
        GradientButton(
          label: 'Submit',
          loading: _submitting,
          onPressed: _submit,
        ),
      ],
    );
  }
}

class _MyFeedbackTab extends StatefulWidget {
  const _MyFeedbackTab();

  @override
  State<_MyFeedbackTab> createState() => _MyFeedbackTabState();
}

class _MyFeedbackTabState extends State<_MyFeedbackTab> {
  final _repo = FeedbackRepository();
  List<FeedbackItem> _items = const [];
  bool _loading = true;
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await _repo.mine();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
    final me = context.read<AuthController>().user?.id;
    if (me != null) {
      _channel = _repo.subscribe(me, (updated) {
        if (!mounted) return;
        setState(() {
          _items = [
            for (final it in _items) if (it.id == updated.id) updated else it,
          ];
        });
      });
    }
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            "You haven't sent any feedback yet.",
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      itemCount: _items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, i) => _FeedbackCard(item: _items[i]),
    );
  }
}

class _FeedbackCard extends StatelessWidget {
  const _FeedbackCard({required this.item});
  final FeedbackItem item;

  String get _kindLabel => switch (item.kind) {
        FeedbackKind.appError => 'App Error',
        FeedbackKind.suggestion => 'Suggestions',
        FeedbackKind.earningInfo => 'Earning Info',
        FeedbackKind.other => 'Other',
      };

  (String, Color) get _statusChip => switch (item.status) {
        FeedbackStatus.resolved => ('Resolved', AppColors.success),
        FeedbackStatus.inProgress => ('In Progress', AppColors.gold),
        FeedbackStatus.pending => ('Pending', AppColors.textMuted),
      };

  @override
  Widget build(BuildContext context) {
    final (statusLabel, statusColor) = _statusChip;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _pill(_kindLabel, AppColors.primaryBright),
              const Spacer(),
              _pill(statusLabel, statusColor),
            ],
          ),
          const SizedBox(height: 10),
          Text(item.body, style: const TextStyle(fontSize: 13)),
          if (item.response != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.support_agent_rounded,
                      size: 16, color: AppColors.success),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(item.response!,
                        style: const TextStyle(fontSize: 12.5)),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(_relativeDay(item.createdAt),
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
        ],
      ),
    );
  }

  Widget _pill(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(label, style: TextStyle(fontSize: 10.5, color: color)),
      );

  String _relativeDay(DateTime d) {
    final days = DateTime.now().difference(d).inDays;
    if (days <= 0) return 'Today';
    if (days == 1) return '1 day ago';
    if (days < 30) return '$days days ago';
    return '${d.day}/${d.month}/${d.year}';
  }
}
