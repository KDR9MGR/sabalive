import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/formatters.dart';
import '../../../core/widgets/gradient_button.dart';
import '../../../data/mock_data.dart';
import '../../../data/models.dart';
import '../../../router/app_nav.dart';
import '../../../state/wallet_controller.dart';
import '../../../theme/app_colors.dart';

/// Bottom sheet for picking and sending a virtual gift. Returns the chosen
/// [Gift] to the caller (or null if dismissed).
Future<Gift?> showGiftSheet(BuildContext context, {required String hostName}) {
  return showModalBottomSheet<Gift>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.bgElevated,
    builder: (_) => _GiftSheet(hostName: hostName),
  );
}

class _GiftSheet extends StatefulWidget {
  const _GiftSheet({required this.hostName});
  final String hostName;

  @override
  State<_GiftSheet> createState() => _GiftSheetState();
}

class _GiftSheetState extends State<_GiftSheet> {
  int _tab = 0;
  int _selected = 0;

  List<Gift> get _list => switch (_tab) {
        1 => Mock.gifts.reversed.toList(),
        2 => Mock.gifts.where((g) => g.effect).toList(),
        _ => Mock.gifts,
      };

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletController>();
    final gifts = _list;
    final gift = gifts[_selected.clamp(0, gifts.length - 1)];
    final canAfford = wallet.canAfford(gift.price);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.stroke,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
            child: Row(
              children: [
                const Text('Send a Gift',
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    )),
                const Spacer(),
                GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    AppNav.buyCoins(context);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.stroke),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.monetization_on_rounded,
                            color: AppColors.coin, size: 16),
                        const SizedBox(width: 6),
                        Text(compactCount(wallet.coins),
                            style: const TextStyle(
                                fontFamily: 'Poppins',
                                fontWeight: FontWeight.w600,
                                fontSize: 13)),
                        const SizedBox(width: 4),
                        const Icon(Icons.add_circle,
                            color: AppColors.primaryBright, size: 16),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                for (final (i, label) in ['Popular', 'New', 'Effects'].indexed)
                  Padding(
                    padding: const EdgeInsets.only(right: 20),
                    child: GestureDetector(
                      onTap: () => setState(() {
                        _tab = i;
                        _selected = 0;
                      }),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                          color: _tab == i
                              ? AppColors.textPrimary
                              : AppColors.textMuted,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.42),
            child: GridView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 0.86,
              ),
              itemCount: gifts.length,
              itemBuilder: (context, i) {
                final g = gifts[i];
                final sel = i == _selected;
                return GestureDetector(
                  onTap: () => setState(() => _selected = i),
                  child: Container(
                    decoration: BoxDecoration(
                      color: sel
                          ? AppColors.primary.withValues(alpha: 0.18)
                          : AppColors.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: sel ? AppColors.primaryBright : AppColors.stroke,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(g.emoji, style: const TextStyle(fontSize: 28)),
                        const SizedBox(height: 4),
                        Text(g.name,
                            style: const TextStyle(
                                fontSize: 10, color: AppColors.textSecondary)),
                        const SizedBox(height: 2),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.monetization_on_rounded,
                                color: AppColors.coin, size: 10),
                            const SizedBox(width: 2),
                            Text('${g.price}',
                                style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.coin)),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                20, 14, 20, 20 + MediaQuery.of(context).padding.bottom),
            child: GradientButton(
              label: canAfford
                  ? 'Send ${gift.name} · ${gift.price}'
                  : 'Not enough coins — top up',
              icon: canAfford ? Icons.send_rounded : Icons.add_rounded,
              onPressed: () {
                if (canAfford) {
                  Navigator.pop(context, gift);
                } else {
                  Navigator.pop(context);
                  AppNav.buyCoins(context);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
