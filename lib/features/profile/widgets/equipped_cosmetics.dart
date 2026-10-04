import 'package:flutter/material.dart' hide Text;

import '../../../data/store_repository.dart';
import '../../../theme/app_colors.dart';
import '../../../core/i18n/text.dart';

/// Renders whatever a profile currently has equipped (VIP tag + frame
/// emoji) — the visible half of the Store/Bag feature; owning an item
/// means nothing if it's never actually shown anywhere. Real data via
/// StoreRepository.equippedFor(), not decorative.
class EquippedCosmetics extends StatelessWidget {
  const EquippedCosmetics({super.key, required this.profileId});
  final String profileId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<OwnedItem>>(
      future: StoreRepository().equippedFor(profileId),
      builder: (context, snap) {
        final items = snap.data ?? const [];
        if (items.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            children: [
              for (final o in items)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    gradient: o.item.category == StoreCategory.vip
                        ? AppColors.goldGradient
                        : null,
                    color: o.item.category == StoreCategory.vip ? null : AppColors.card,
                    borderRadius: BorderRadius.circular(20),
                    border: o.item.category == StoreCategory.vip
                        ? null
                        : Border.all(color: AppColors.stroke),
                  ),
                  child: Text('${o.item.emoji} ${o.item.name}',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: o.item.category == StoreCategory.vip
                            ? const Color(0xFF3A1A5E)
                            : AppColors.textSecondary,
                      )),
                ),
            ],
          ),
        );
      },
    );
  }
}
