import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/errors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/gradient_button.dart';
import '../../data/models.dart';
import '../../router/app_nav.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';

class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletController>();
    return Scaffold(
      appBar: AppBar(title: const Text('Wallet & Earnings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: AppColors.brandGradient,
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.35),
                  blurRadius: 26,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Coin Balance',
                    style: TextStyle(color: Colors.white70, fontSize: 12.5)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.monetization_on_rounded,
                        color: AppColors.gold, size: 30),
                    const SizedBox(width: 8),
                    Text(withThousands(wallet.coins),
                        style: const TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w700,
                          fontSize: 30,
                          color: Colors.white,
                        )),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: GradientButton(
                        label: 'Buy Coins',
                        height: 44,
                        gradient: AppColors.goldGradient,
                        onPressed: () => AppNav.buyCoins(context),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinePillButton(
                        label: 'Withdraw',
                        height: 44,
                        color: Colors.white,
                        onPressed: () => _withdraw(context, wallet),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _miniStat(Icons.diamond_rounded, AppColors.diamond,
                    'Diamonds', withThousands(wallet.diamonds)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _miniStat(Icons.account_balance_rounded,
                    AppColors.success, 'Est. Earnings',
                    '₹${withThousands(wallet.earningsInr.round())}'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Text('Transaction History',
              style: TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w600,
                  fontSize: 15)),
          const SizedBox(height: 8),
          ...wallet.transactions.map(_txTile),
        ],
      ),
    );
  }

  Future<void> _withdraw(BuildContext context, WalletController wallet) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await wallet.withdraw(5000);
      messenger.showSnackBar(const SnackBar(content: Text('Withdrawal of 5,000 diamonds requested')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  Widget _miniStat(IconData icon, Color color, String label, String value) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 10),
          Text(value,
              style: const TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w700,
                  fontSize: 16)),
          Text(label,
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
        ],
      ),
    );
  }

  Widget _txTile(WalletTx tx) {
    final positive = tx.amount >= 0;
    final (icon, color) = switch (tx.type) {
      TxType.topUp => (Icons.add_circle_rounded, AppColors.success),
      TxType.giftReceived => (Icons.card_giftcard_rounded, AppColors.gold),
      TxType.giftSent => (Icons.send_rounded, AppColors.magenta),
      TxType.withdraw => (Icons.account_balance_rounded, AppColors.diamond),
      TxType.grant => (Icons.volunteer_activism_rounded, AppColors.success),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tx.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                Text(tx.date,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textMuted)),
              ],
            ),
          ),
          Text(
            '${positive ? '+' : '-'}${withThousands(tx.amount.abs())}',
            style: TextStyle(
              fontFamily: 'Poppins',
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: positive ? AppColors.success : AppColors.danger,
            ),
          ),
        ],
      ),
    );
  }
}
