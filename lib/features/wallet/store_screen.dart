import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/errors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/gradient_button.dart';
import '../../core/widgets/pills.dart';
import '../../data/store_repository.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';
import 'bag_screen.dart';
import 'widgets/store_art.dart';

/// Real cosmetics store — frames, VIP tiers, entry effects, vehicles, room skins.
/// A "purchase" grants N days of access (extended if you already own an
/// unexpired copy), not real recurring billing — see the migration's own
/// note. Prices/items are my own placeholder catalog, retunable via SQL
/// on store_items without a code change.
class StoreScreen extends StatefulWidget {
  const StoreScreen({super.key});

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> {
  final _repo = StoreRepository();
  List<StoreItem>? _catalog;
  int _tab = 0;
  final _busyIds = <String>{};

  static const _categories = [
    (StoreCategory.frame, 'Frame'),
    (StoreCategory.vip, 'Lucky ID'),
    (StoreCategory.entryEffect, 'Entry'),
    (StoreCategory.vehicle, 'Garage'),
    (StoreCategory.roomSkin, 'Room Skin'),
  ];

  @override
  void initState() {
    super.initState();
    _repo.catalog().then((c) {
      if (mounted) setState(() => _catalog = c);
    });
  }

  Future<void> _buy(StoreItem item) async {
    if (_busyIds.contains(item.id)) return;
    setState(() => _busyIds.add(item.id));
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _repo.purchase(item.id);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('${item.name} purchased!')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _busyIds.remove(item.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final coins = context.watch<WalletController>().coins;
    final catalog = _catalog;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Store'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: Row(
                children: [
                  const Icon(Icons.monetization_on_rounded,
                      color: AppColors.coin, size: 16),
                  const SizedBox(width: 4),
                  Text(compactCount(coins),
                      style: const TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w600,
                          fontSize: 13)),
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.shopping_bag_outlined),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const BagScreen())),
          ),
        ],
      ),
      body: catalog == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                const SizedBox(height: 12),
                ChipRow(
                  items: [for (final (_, label) in _categories) label],
                  index: _tab,
                  onChanged: (i) => setState(() => _tab = i),
                ),
                Expanded(child: _grid(catalog)),
              ],
            ),
    );
  }

  Widget _grid(List<StoreItem> catalog) {
    final category = _categories[_tab].$1;
    final items = catalog.where((i) => i.category == category).toList();
    if (items.isEmpty) {
      return const Center(
        child: Text('Nothing here yet', style: TextStyle(color: AppColors.textMuted)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 0.8,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) => _card(items[i]),
    );
  }

  Widget _card(StoreItem item) {
    final busy = _busyIds.contains(item.id);
    return GestureDetector(
      onTap: () => showStorePreview(context, item),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.stroke),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            StoreArt(item, size: 56),
            const SizedBox(height: 10),
            Text(item.name,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 13)),
            Text('${item.durationDays} days',
                style: const TextStyle(fontSize: 10.5, color: AppColors.textMuted)),
            const SizedBox(height: 10),
            GradientButton(
              label: '${withThousands(item.priceCoins)} coins',
              height: 36,
              loading: busy,
              onPressed: () => _buy(item),
            ),
          ],
        ),
      ),
    );
  }
}
