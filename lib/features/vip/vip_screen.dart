import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../../core/i18n/text.dart';
import '../../core/utils/errors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/label_picture.dart';
import '../../data/vip_repository.dart';
import '../../router/app_nav.dart';
import '../../state/auth_controller.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';

/// The VIP screen (owner, 2026-11-06): a list of cards like My Level's, one per VIP product the panel made (Master -> VIP). A card shows the product's badge, name, how many
/// benefits it has, its price and days, and "Active until ..." when the person owns it; tapping it opens [VipProductScreen] with every benefit and the Buy button.
/// It reads when it opens, on a pull down, and again after a product page was used.
class VipScreen extends StatefulWidget {
  const VipScreen({super.key, @visibleForTesting this.loader});

  /// Replaces the database reads (tests): the active products and what the person owns.
  final Future<({List<VipProduct> products, Map<String, DateTime> mine})> Function()? loader;

  @override
  State<VipScreen> createState() => _VipScreenState();
}

class _VipScreenState extends State<VipScreen> {
  List<VipProduct>? _products;
  Map<String, DateTime> _mine = const {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<({List<VipProduct> products, Map<String, DateTime> mine})> _read() async {
    final repo = VipRepository();
    final me = context.read<AuthController>().user?.id ?? '';
    final products = await repo.fetchProducts();
    // what the person owns is a nice-to-have: a failed read just shows no "Active until"
    Map<String, DateTime> mine = const {};
    try {
      mine = await repo.fetchMine(me);
    } catch (_) {}
    return (products: products, mine: mine);
  }

  Future<void> _load() async {
    try {
      final r = await (widget.loader ?? _read)();
      if (!mounted) return;
      setState(() {
        _products = r.products;
        _mine = r.mine;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      // keep what is already on screen; only a first read that failed shows the message
      setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _open(VipProduct p) async {
    await AppNav.vipProduct(context, p, endsAt: _mine[p.id]);
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final coins = _coins(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('VIP'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: _CoinChip(coins: coins)),
          ),
        ],
      ),
      body: _body(),
    );
  }

  int _coins(BuildContext context) {
    try {
      return context.watch<WalletController>().coins;
    } catch (_) {
      return 0; // no wallet around (tests)
    }
  }

  Widget _body() {
    final products = _products;
    if (products == null) {
      if (_error != null) return _message(_error!, retry: true);
      return const Center(child: CircularProgressIndicator());
    }
    if (products.isEmpty) return _message('No VIP products yet.');
    return RefreshIndicator(
      onRefresh: _load,
      child: GridView.builder(
        key: const ValueKey('vip-grid'),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        physics: const AlwaysScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.8),
        itemCount: products.length,
        itemBuilder: (context, i) {
          final p = products[i];
          return VipCard(key: ValueKey('vip-card-${p.id}'), product: p, endsAt: _mine[p.id], onTap: () => _open(p));
        },
      ),
    );
  }

  Widget _message(String text, {bool retry = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.workspace_premium_outlined, size: 48, color: AppColors.textMuted.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
            if (retry) ...[
              const SizedBox(height: 10),
              TextButton(onPressed: _load, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}

/// The coin balance in the app bar of the VIP screens.
class _CoinChip extends StatelessWidget {
  const _CoinChip({required this.coins});

  final int coins;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.monetization_on_rounded, color: AppColors.coin, size: 16),
        const SizedBox(width: 4),
        Text(compactCount(coins), style: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 13)),
      ],
    );
  }
}

/// "5 Dec 2026": a date as people read it, in the phone's own time zone (the VIP ends at an exact moment).
String vipEndLabel(DateTime at) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final d = at.toLocal();
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

/// How a product's days are said: "1 day", "30 days".
String vipDaysLabel(int days) => days == 1 ? '1 day' : '$days days';

/// The badge of a product at [height]: its picture, or a plain gold crown while it loads, if it fails, or when the panel gave none.
class VipBadgeArt extends StatelessWidget {
  const VipBadgeArt({super.key, required this.url, required this.height, this.maxWidth = 160});

  final String? url;
  final double height;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final crown = SizedBox(
      width: height,
      height: height,
      child: Icon(Icons.workspace_premium_rounded, size: height * 0.75, color: AppColors.gold),
    );
    final u = url;
    if (u == null || !LabelPicture.supports(u)) return crown;
    return LabelPicture(url: u, height: height, maxWidth: maxWidth, fallback: crown);
  }
}

/// One product in the VIP list.
class VipCard extends StatelessWidget {
  const VipCard({super.key, required this.product, required this.onTap, this.endsAt});

  final VipProduct product;

  /// When the person's VIP of this product ends (null = they do not have it).
  final DateTime? endsAt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final owned = endsAt != null;
    final n = product.benefits.length;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: owned ? AppColors.gold : AppColors.stroke, width: owned ? 1.6 : 1),
        ),
        // scaled down rather than overflowing when the phone's text size is large
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: 128,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(height: 84, child: VipBadgeArt(url: product.badgeUrl, height: 84, maxWidth: 120)),
                const SizedBox(height: 8),
                Text(product.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w700, fontSize: 14.5)),
                Text(n == 1 ? '1 benefit' : '$n benefits', style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.monetization_on_rounded, size: 13, color: AppColors.coin),
                    const SizedBox(width: 3),
                    // never wider than the card, whatever the phone's text size
                    Flexible(
                      child: Text('${compactCount(product.priceCoins)} · ${vipDaysLabel(product.durationDays)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 11.5)),
                    ),
                  ],
                ),
                if (owned) ...[
                  const SizedBox(height: 4),
                  Text('Active until ${vipEndLabel(endsAt!)}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: AppColors.gold, fontWeight: FontWeight.w600)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
