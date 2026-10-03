import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/errors.dart';
import '../../data/store_repository.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';
import 'widgets/store_art.dart';
import 'frames_screen.dart';
import 'store_screen.dart';

/// What you currently own (non-expired) and what's equipped — real data
/// from user_items, not mock.
class BagScreen extends StatefulWidget {
  const BagScreen({super.key});

  @override
  State<BagScreen> createState() => _BagScreenState();
}

class _BagScreenState extends State<BagScreen> {
  final _repo = StoreRepository();
  List<OwnedItem>? _items;
  final _busyIds = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await _repo.myItems();
    if (mounted) setState(() => _items = items);
  }

  Future<void> _toggle(OwnedItem owned) async {
    if (_busyIds.contains(owned.item.id)) return;
    setState(() => _busyIds.add(owned.item.id));
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _repo.setEquipped(owned.item.id, !owned.equipped);
      await _load();
      // a frame you just put on (or took off) should show on your own profile now
      if (mounted && owned.item.category == StoreCategory.frame) {
        await context.read<AuthController>().reloadProfile();
      }
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _busyIds.remove(owned.item.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Bag'),
        actions: [
          IconButton(
            tooltip: 'Profile frames',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const FramesScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.storefront_outlined),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const StoreScreen())),
          ),
        ],
      ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.shopping_bag_outlined,
                            size: 40, color: AppColors.textMuted),
                        const SizedBox(height: 10),
                        const Text("You don't own anything yet",
                            style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const StoreScreen())),
                          child: const Text('Go to Store'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(20),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, i) => _tile(items[i]),
                ),
    );
  }

  Widget _tile(OwnedItem owned) {
    final busy = _busyIds.contains(owned.item.id);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: owned.equipped ? AppColors.primaryBright : AppColors.stroke,
            width: owned.equipped ? 1.6 : 1),
      ),
      child: Row(
        children: [
          StoreArt(owned.item, size: 44),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(owned.item.name,
                    style: const TextStyle(
                        fontFamily: 'Poppins',
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5)),
                Text('Exp: ${owned.expiresAt.day}/${owned.expiresAt.month}/${owned.expiresAt.year}',
                    style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
              ],
            ),
          ),
          TextButton(
            onPressed: busy ? null : () => _toggle(owned),
            child: Text(
              busy ? '…' : (owned.equipped ? 'Remove' : 'Equip'),
              style: TextStyle(
                  color: owned.equipped ? AppColors.danger : AppColors.primaryBright),
            ),
          ),
        ],
      ),
    );
  }
}
