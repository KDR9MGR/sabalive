import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/formatters.dart';
import '../../../data/models.dart';
import '../../../state/wallet_controller.dart';
import '../../../theme/app_colors.dart';

/// Horizontal strip of gifts (emoji + diamond price) shown along the bottom of
/// a live room, matching the reference layout. Tapping one calls [onSelect].
class GiftTray extends StatelessWidget {
  const GiftTray({super.key, required this.onSelect});
  final ValueChanged<Gift> onSelect;

  @override
  Widget build(BuildContext context) {
    final gifts = context.watch<WalletController>().gifts;
    if (gifts.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: gifts.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final g = gifts[i];
          return GestureDetector(
            onTap: () => onSelect(g),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(g.emoji, style: const TextStyle(fontSize: 24)),
                ),
                const SizedBox(height: 3),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.diamond_rounded,
                        size: 10, color: AppColors.diamond),
                    const SizedBox(width: 2),
                    Text(compactCount(g.price),
                        style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
