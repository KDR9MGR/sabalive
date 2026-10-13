import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../../core/utils/errors.dart';
import '../../router/app_nav.dart';
import '../../data/store_repository.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';
import 'widgets/store_art.dart';
import 'frames_screen.dart';
import 'store_screen.dart';
import '../../core/i18n/text.dart';

/// What you currently own (non-expired) and what's equipped — real data
/// from user_items, not mock.
class BagScreen extends StatefulWidget {
  const BagScreen({super.key, this.repo, this.storePage});

  /// Injectable for tests.
  final StoreRepository? repo;
  final Widget Function()? storePage;

  @override
  State<BagScreen> createState() => _BagScreenState();
}

class _BagScreenState extends State<BagScreen> with WidgetsBindingObserver {
  late final StoreRepository _repo = widget.repo ?? StoreRepository();
  List<OwnedItem>? _items;
  final _busyIds = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      final items = await _repo.myItems();
      if (mounted) setState(() => _items = items);
    } catch (e) {
      // keep what is showing; an empty spinner forever helps nobody
      if (mounted && _items == null) setState(() => _items = const []);
    }
  }

  /// Opens the Store (or the Profile frames page) over the Bag and reads the Bag again when it closes: something bought
  /// there must be in the list when the user comes back to put it on. (Without this the Bag opened before the purchase
  /// kept showing its old list, so a bought frame looked as if it had never arrived.)
  Future<void> _openThenReload(Widget page) async {
    await AppNav.open(context, page);
    if (mounted) await _load();
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
            tooltip: tr('Profile frames'),
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => _openThenReload(const FramesScreen()),
          ),
          IconButton(
            icon: const Icon(Icons.storefront_outlined),
            onPressed: () => _openThenReload(widget.storePage?.call() ?? const StoreScreen()),
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
                          onPressed: () => _openThenReload(const StoreScreen()),
                          child: const Text('Go to Store'),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(20),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, i) => _tile(items[i]),
                  ),
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
