import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/utils/errors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/gradient_button.dart';
import '../../core/widgets/pills.dart';
import '../../data/referrals_repository.dart';
import '../../theme/app_colors.dart';
import '../../core/i18n/text.dart';

/// Invite a friend, real referral_code + redeem_referral_code RPCs behind
/// it — no deep-link capture at signup yet, so redemption is a manual
/// "enter your friend's code" action from inside the app.
class ReferralsScreen extends StatefulWidget {
  const ReferralsScreen({super.key});

  @override
  State<ReferralsScreen> createState() => _ReferralsScreenState();
}

class _ReferralsScreenState extends State<ReferralsScreen> {
  int _tab = 0; // 0 = Invite a Friend, 1 = My Invites

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Invites')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: SegmentedTabs(
              tabs: const ['Invite a Friend', 'My Invites'],
              index: _tab,
              onChanged: (i) => setState(() => _tab = i),
            ),
          ),
          Expanded(child: _tab == 0 ? const _InviteTab() : const _MyInvitesTab()),
        ],
      ),
    );
  }
}

class _InviteTab extends StatefulWidget {
  const _InviteTab();

  @override
  State<_InviteTab> createState() => _InviteTabState();
}

class _InviteTabState extends State<_InviteTab> {
  final _repo = ReferralsRepository();
  final _redeemCode = TextEditingController();
  String? _code;
  bool _redeeming = false;

  @override
  void initState() {
    super.initState();
    _repo.myCode().then((c) {
      if (mounted) setState(() => _code = c);
    });
  }

  @override
  void dispose() {
    _redeemCode.dispose();
    super.dispose();
  }

  String get _link => 'https://sabalive.app/invite/${_code ?? ''}';

  Future<void> _redeem() async {
    final code = _redeemCode.text.trim();
    if (code.isEmpty || _redeeming) return;
    setState(() => _redeeming = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _repo.redeem(code);
      if (!mounted) return;
      _redeemCode.clear();
      messenger.showSnackBar(const SnackBar(content: Text('Referral code redeemed!')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _redeeming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_code == null) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      children: [
        const Text(
          'Invite friends to SABALIVE and earn coins when they join with your code!',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 24),
        Center(
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: QrImageView(data: _link, size: 200),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text('Scan to join with code $_code',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: GradientButton(
                label: 'Share',
                icon: Icons.share_rounded,
                onPressed: () => SharePlus.instance.share(
                  ShareParams(text: 'Join me on SABALIVE! $_link'),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinePillButton(
                label: 'Copy Link',
                icon: Icons.copy_rounded,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _link));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Link copied')),
                    );
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
        const Text('Have a friend\'s code?',
            style: TextStyle(
                fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 13.5)),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _redeemCode,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(hintText: tr('Enter code')),
              ),
            ),
            const SizedBox(width: 10),
            GradientButton(
              label: 'Redeem',
              loading: _redeeming,
              onPressed: _redeem,
              height: 44,
            ),
          ],
        ),
      ],
    );
  }
}

class _MyInvitesTab extends StatefulWidget {
  const _MyInvitesTab();

  @override
  State<_MyInvitesTab> createState() => _MyInvitesTabState();
}

class _MyInvitesTabState extends State<_MyInvitesTab> {
  final _repo = ReferralsRepository();
  List<ReferralEntry> _entries = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _repo.myReferrals().then((e) {
      if (!mounted) return;
      setState(() {
        _entries = e;
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final totalReward = _entries.fold<int>(0, (sum, e) => sum + e.rewardCoins);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.stroke),
          ),
          child: Row(
            children: [
              const Expanded(
                child: Text('Total Referral Rewards',
                    style: TextStyle(
                        fontFamily: 'Poppins',
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5)),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('+${withThousands(totalReward)}',
                      style: const TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: AppColors.gold)),
                  Text('${_entries.length} invites',
                      style: const TextStyle(
                          fontSize: 10.5, color: AppColors.textMuted)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (_entries.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.person_add_alt_1_rounded,
                      size: 40, color: AppColors.textMuted),
                  SizedBox(height: 10),
                  Text('No invites yet',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                  Text('Share your code and your rewards will show up here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textMuted, fontSize: 11.5)),
                ],
              ),
            ),
          )
        else
          for (final e in _entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  AppAvatar(name: e.user.name, imageUrl: e.user.avatarUrl, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(e.user.name,
                        style: const TextStyle(
                            fontFamily: 'Poppins',
                            fontWeight: FontWeight.w600,
                            fontSize: 13)),
                  ),
                  Text('+${e.rewardCoins}',
                      style: const TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5,
                          color: AppColors.gold)),
                ],
              ),
            ),
      ],
    );
  }
}
