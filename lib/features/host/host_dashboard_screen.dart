import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/errors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/gradient_button.dart';
import '../../data/host_repository.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';

class HostDashboardScreen extends StatefulWidget {
  const HostDashboardScreen({super.key});

  @override
  State<HostDashboardScreen> createState() => _HostDashboardScreenState();
}

class _HostDashboardScreenState extends State<HostDashboardScreen> {
  final _repo = HostRepository();
  bool _loading = true;
  String? _error;
  HostSummary? _summary;
  List<HostStreamRow> _streams = const [];
  List<WithdrawalRow> _withdrawals = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _repo.summary(),
        _repo.myStreams(),
        _repo.myWithdrawals(),
      ]);
      if (!mounted) return;
      setState(() {
        _summary = results[0] as HostSummary;
        _streams = results[1] as List<HostStreamRow>;
        _withdrawals = results[2] as List<WithdrawalRow>;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  Future<void> _withdraw() async {
    final wallet = context.read<WalletController>();
    final diamonds = wallet.diamonds;
    if (diamonds < HostRepository.minWithdrawalDiamonds) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Need at least ${HostRepository.minWithdrawalDiamonds} diamonds to withdraw'),
      ));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('Request withdrawal'),
        content: Text(
            'Withdraw all $diamonds diamonds (≈ ₹${(diamonds * 0.82).toStringAsFixed(0)})? '
            'An admin reviews payout requests.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Request')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _repo.requestWithdrawal(diamonds);
      messenger.showSnackBar(
          const SnackBar(content: Text('Withdrawal requested')));
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletController>();
    return Scaffold(
      appBar: AppBar(title: const Text('Creator Dashboard')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!,
                      style: const TextStyle(color: AppColors.textMuted)),
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ]))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
                    children: [
                      _earningsCard(wallet),
                      const SizedBox(height: 18),
                      _statsRow(),
                      const SizedBox(height: 24),
                      const Text('Recent streams',
                          style: TextStyle(
                              fontFamily: 'Poppins',
                              fontWeight: FontWeight.w600,
                              fontSize: 15)),
                      const SizedBox(height: 8),
                      if (_streams.isEmpty)
                        _muted('No streams yet — tap Go Live to start.')
                      else
                        ..._streams.take(10).map(_streamTile),
                      const SizedBox(height: 24),
                      const Text('Withdrawals',
                          style: TextStyle(
                              fontFamily: 'Poppins',
                              fontWeight: FontWeight.w600,
                              fontSize: 15)),
                      const SizedBox(height: 8),
                      if (_withdrawals.isEmpty)
                        _muted('No withdrawal requests yet.')
                      else
                        ..._withdrawals.take(10).map(_withdrawalTile),
                    ],
                  ),
                ),
    );
  }

  Widget _earningsCard(WalletController wallet) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: AppColors.brandGradient,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Available to withdraw',
              style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.diamond_rounded, color: Colors.white, size: 22),
              const SizedBox(width: 6),
              Text(withThousands(wallet.diamonds),
                  style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w700,
                      fontSize: 26,
                      color: Colors.white)),
              const SizedBox(width: 8),
              Text('≈ ₹${wallet.earningsInr.toStringAsFixed(0)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 14),
          GradientButton(
            label: 'Request Withdrawal',
            icon: Icons.account_balance_rounded,
            height: 44,
            onPressed: _withdraw,
          ),
        ],
      ),
    );
  }

  Widget _statsRow() {
    final s = _summary!;
    return Row(
      children: [
        _stat('Streams', '${s.totalStreams}'),
        _stat('Gifts (30d)', compactCount(s.giftCoins30d)),
        _stat('Lifetime gifts', compactCount(s.lifetimeGiftCoins)),
      ],
    );
  }

  Widget _stat(String label, String value) => Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.stroke),
          ),
          child: Column(
            children: [
              Text(value,
                  style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w700,
                      fontSize: 16)),
              const SizedBox(height: 2),
              Text(label,
                  style:
                      const TextStyle(fontSize: 10, color: AppColors.textMuted)),
            ],
          ),
        ),
      );

  Widget _streamTile(HostStreamRow s) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13.5)),
                const SizedBox(height: 2),
                Text(
                  '${s.category} · ${s.startedAt == null ? '' : relativeTime(s.startedAt!)}'
                  '${s.status == 'live' ? ' · LIVE' : ''}',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(children: [
                const Icon(Icons.monetization_on_rounded,
                    size: 12, color: AppColors.coin),
                const SizedBox(width: 3),
                Text(compactCount(s.giftCoins),
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 2),
              Text('${s.viewerPeak} viewers',
                  style:
                      const TextStyle(fontSize: 10, color: AppColors.textMuted)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _withdrawalTile(WithdrawalRow w) {
    final color = switch (w.status) {
      'paid' => AppColors.success,
      'rejected' => AppColors.danger,
      'processing' => AppColors.gold,
      _ => AppColors.textMuted,
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.diamond_rounded, color: AppColors.diamond),
      title: Text('${w.diamonds} diamonds',
          style:
              const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
      subtitle: Text(
          w.requestedAt == null ? '' : relativeTime(w.requestedAt!),
          style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
      trailing: Text(w.status.toUpperCase(),
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _muted(String t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(t,
            style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted)),
      );
}
