import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/utils/errors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/gradient_button.dart';
import '../../data/social_repository.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';

/// Coin reseller / agent tool — send coins to another user by @username.
/// Gated by [AccessCodeScreen] on the way in (reseller code).
class SellCoinsScreen extends StatefulWidget {
  const SellCoinsScreen({super.key});

  @override
  State<SellCoinsScreen> createState() => _SellCoinsScreenState();
}

class _SellCoinsScreenState extends State<SellCoinsScreen> {
  final _repo = SocialRepository();
  final _to = TextEditingController();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  bool _sending = false;
  bool _loadingHistory = true;
  List<({String other, int coins, bool outgoing, DateTime? at, String note})> _history =
      const [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _to.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final h = await _repo.resellerTransfers();
      if (!mounted) return;
      setState(() {
        _history = h;
        _loadingHistory = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  Future<void> _send() async {
    final to = _to.text.trim();
    final amount = int.tryParse(_amount.text.trim()) ?? 0;
    if (to.isEmpty || amount <= 0 || _sending) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    try {
      await _repo.sellCoins(
        recipientUsername: to,
        coins: amount,
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      );
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text('Sent ${withThousands(amount)} coins to @$to')));
      _to.clear();
      _amount.clear();
      _note.clear();
      await _loadHistory();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coins = context.watch<WalletController>().coins;
    return Scaffold(
      appBar: AppBar(title: const Text('Sell Coins')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: AppColors.goldGradient,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Your coin balance',
                    style: TextStyle(color: Color(0xFF5A3A00), fontSize: 12)),
                const SizedBox(height: 4),
                Row(children: [
                  const Icon(Icons.monetization_on_rounded,
                      color: Color(0xFF5A3A00), size: 24),
                  const SizedBox(width: 6),
                  Text(withThousands(coins),
                      style: const TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w800,
                          fontSize: 24,
                          color: Color(0xFF3A1A5E))),
                ]),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Text('Recipient @username',
              style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          TextField(
            controller: _to,
            decoration: const InputDecoration(hintText: 'e.g. priya_23'),
          ),
          const SizedBox(height: 14),
          const Text('Amount (coins)',
              style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          TextField(
            controller: _amount,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(hintText: '1000'),
          ),
          const SizedBox(height: 14),
          const Text('Note (optional)',
              style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          TextField(
            controller: _note,
            maxLength: 80,
            decoration: const InputDecoration(hintText: 'Order #…'),
          ),
          const SizedBox(height: 8),
          GradientButton(
            label: 'Send Coins',
            icon: Icons.send_rounded,
            loading: _sending,
            onPressed: _send,
          ),
          const SizedBox(height: 28),
          const Text('Recent transfers',
              style: TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w600,
                  fontSize: 15)),
          const SizedBox(height: 8),
          if (_loadingHistory)
            const Center(child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator()))
          else if (_history.isEmpty)
            const Text('No transfers yet.',
                style: TextStyle(fontSize: 12.5, color: AppColors.textMuted))
          else
            for (final t in _history)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                    t.outgoing
                        ? Icons.call_made_rounded
                        : Icons.call_received_rounded,
                    color: t.outgoing ? AppColors.danger : AppColors.success),
                title: Text(
                    '${t.outgoing ? '−' : '+'}${withThousands(t.coins)} coins  '
                    '${t.outgoing ? 'to' : 'from'} ${t.other}',
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
                subtitle: Text(
                    [
                      if (t.at != null) relativeTime(t.at!),
                      if (t.note.isNotEmpty) t.note,
                    ].join(' · '),
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textMuted)),
              ),
        ],
      ),
    );
  }
}
