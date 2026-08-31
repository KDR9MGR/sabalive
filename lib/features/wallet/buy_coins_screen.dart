import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/formatters.dart';
import '../../core/widgets/gradient_button.dart';
import '../../data/mock_data.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';

class BuyCoinsScreen extends StatefulWidget {
  const BuyCoinsScreen({super.key});

  @override
  State<BuyCoinsScreen> createState() => _BuyCoinsScreenState();
}

class _BuyCoinsScreenState extends State<BuyCoinsScreen> {
  int _selected = 2;
  int _method = 0;

  static const _methods = [
    (Icons.account_balance_wallet_rounded, 'UPI'),
    (Icons.credit_card_rounded, 'Card'),
    (Icons.account_balance_rounded, 'Net Banking'),
    (Icons.payments_rounded, 'Wallet / PayPal'),
  ];

  void _pay() {
    final pack = Mock.coinPacks[_selected];
    context.read<WalletController>().buyCoins(pack);
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
            'Added ${withThousands(pack.coins + pack.bonus)} coins to your wallet'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletController>();
    final pack = Mock.coinPacks[_selected];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Buy Coins'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Row(
                children: [
                  const Icon(Icons.monetization_on_rounded,
                      color: AppColors.coin, size: 16),
                  const SizedBox(width: 4),
                  Text(compactCount(wallet.coins),
                      style: const TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w600,
                          fontSize: 13)),
                ],
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              children: [
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.15,
                  ),
                  itemCount: Mock.coinPacks.length,
                  itemBuilder: (context, i) {
                    final p = Mock.coinPacks[i];
                    final sel = i == _selected;
                    return GestureDetector(
                      onTap: () => setState(() => _selected = i),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: sel
                              ? AppColors.primary.withValues(alpha: 0.16)
                              : AppColors.card,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color:
                                sel ? AppColors.primaryBright : AppColors.stroke,
                            width: sel ? 1.6 : 1,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (p.popular)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  gradient: AppColors.goldGradient,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Text('BEST VALUE',
                                    style: TextStyle(
                                      fontFamily: 'Poppins',
                                      fontWeight: FontWeight.w700,
                                      fontSize: 8,
                                      color: Color(0xFF3A1A5E),
                                    )),
                              ),
                            const SizedBox(height: 6),
                            const Icon(Icons.monetization_on_rounded,
                                color: AppColors.coin, size: 26),
                            const SizedBox(height: 6),
                            Text(withThousands(p.coins),
                                style: const TextStyle(
                                    fontFamily: 'Poppins',
                                    fontWeight: FontWeight.w700,
                                    fontSize: 17)),
                            if (p.bonus > 0)
                              Text('+${p.bonus} bonus',
                                  style: const TextStyle(
                                      fontSize: 10,
                                      color: AppColors.success)),
                            const SizedBox(height: 4),
                            Text(p.price,
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    color: AppColors.textSecondary)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 24),
                const Text('Payment Method',
                    style: TextStyle(
                        fontFamily: 'Poppins',
                        fontWeight: FontWeight.w600,
                        fontSize: 14)),
                const SizedBox(height: 10),
                for (final (i, m) in _methods.indexed)
                  GestureDetector(
                    onTap: () => setState(() => _method = i),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 14),
                      decoration: BoxDecoration(
                        color: AppColors.card,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: _method == i
                              ? AppColors.primaryBright
                              : AppColors.stroke,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(m.$1,
                              size: 20, color: AppColors.primaryBright),
                          const SizedBox(width: 12),
                          Text(m.$2,
                              style: const TextStyle(
                                  fontSize: 13.5, fontWeight: FontWeight.w500)),
                          const Spacer(),
                          Icon(
                            _method == i
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_unchecked_rounded,
                            color: _method == i
                                ? AppColors.primaryBright
                                : AppColors.textMuted,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(
                20, 12, 20, 12 + MediaQuery.of(context).padding.bottom),
            decoration: const BoxDecoration(
              color: AppColors.bgElevated,
              border: Border(top: BorderSide(color: AppColors.stroke)),
            ),
            child: GradientButton(
              label: 'Pay ${pack.price}  ·  ${withThousands(pack.coins + pack.bonus)} coins',
              icon: Icons.lock_rounded,
              onPressed: _pay,
            ),
          ),
        ],
      ),
    );
  }
}
