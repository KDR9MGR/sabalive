import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../../core/i18n/text.dart';
import '../../core/utils/errors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/label_picture.dart';
import '../../data/vip_repository.dart';
import '../../state/auth_controller.dart';
import '../../state/wallet_controller.dart';
import '../../theme/app_colors.dart';
import 'vip_kinds.dart';
import 'vip_screen.dart';

/// One VIP product (owner, 2026-11-06): its badge and name, "VIP Benefits (n)" with a tile per benefit (the picture the panel gave it, else the kind's icon, and its name), and a bottom
/// bar with the coin price and Buy. Buying asks first, takes the coins, gives the benefits that are linked to Store items for the VIP's days and adds the days when it is already
/// active ("Extend"). Pops with `true` when something was bought, so the list can refresh.
class VipProductScreen extends StatefulWidget {
  const VipProductScreen({
    super.key,
    required this.product,
    this.endsAt,
    @visibleForTesting this.buy,
    @visibleForTesting this.coinsOf,
    @visibleForTesting this.afterBuy,
  });

  final VipProduct product;

  /// When the person's VIP of this product ends (null = they do not have it).
  final DateTime? endsAt;

  /// Replaces the purchase (tests): returns when the VIP now ends.
  final Future<DateTime> Function(String productId)? buy;

  /// Replaces reading the coin balance (tests).
  final int Function(BuildContext context)? coinsOf;

  /// Replaces what happens after a purchase (tests); the app reloads the signed-in profile (a frame that was put on shows at once).
  final Future<void> Function(BuildContext context)? afterBuy;

  @override
  State<VipProductScreen> createState() => _VipProductScreenState();
}

class _VipProductScreenState extends State<VipProductScreen> {
  late DateTime? _endsAt = widget.endsAt;
  bool _busy = false;
  bool _bought = false;

  VipProduct get _p => widget.product;

  int _coins(BuildContext context) {
    final f = widget.coinsOf;
    if (f != null) return f(context);
    try {
      return context.watch<WalletController>().coins;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _buy() async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    if (_coins(context) < _p.priceCoins) {
      messenger.showSnackBar(SnackBar(content: Text(tr('Not enough coins'))));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Buy ${_p.name}?'),
        content: Text('${withThousands(_p.priceCoins)} coins for ${vipDaysLabel(_p.durationDays)} of VIP. Buying it again while it is active adds the days.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Buy')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final end = await (widget.buy ?? VipRepository().purchase)(_p.id);
      if (!mounted) return;
      await (widget.afterBuy ?? _reloadProfile)(context);
      if (!mounted) return;
      setState(() {
        _endsAt = end;
        _bought = true;
      });
      messenger.showSnackBar(SnackBar(content: Text('${_p.name} is yours until ${vipEndLabel(end)}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static Future<void> _reloadProfile(BuildContext context) => context.read<AuthController>().reloadProfile();

  @override
  Widget build(BuildContext context) {
    final owned = _endsAt != null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _bought);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_p.name)),
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _hero(owned)),
            SliverToBoxAdapter(child: _benefitsTitle()),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              sliver: _p.benefits.isEmpty
                  ? SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: Text('No benefits listed yet.', textAlign: TextAlign.center, style: TextStyle(color: AppColors.textMuted)),
                      ),
                    )
                  : SliverGrid(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 1.15),
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => VipBenefitTile(key: ValueKey('vip-benefit-${_p.benefits[i].id}'), benefit: _p.benefits[i]),
                        childCount: _p.benefits.length,
                      ),
                    ),
            ),
          ],
        ),
        bottomNavigationBar: _buyBar(owned),
      ),
    );
  }

  Widget _hero(bool owned) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.gold.withValues(alpha: 0.22), Colors.transparent],
        ),
      ),
      child: Column(
        children: [
          VipBadgeArt(url: _p.badgeUrl, height: 150, maxWidth: 240),
          const SizedBox(height: 10),
          Text(_p.name, style: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w700, fontSize: 22)),
          if (_p.tagline != null) ...[
            const SizedBox(height: 4),
            Text(_p.tagline!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ],
          if (owned) ...[
            const SizedBox(height: 10),
            Container(
              key: const ValueKey('vip-active'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(color: AppColors.gold.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(20), border: Border.all(color: AppColors.gold)),
              child: Text('Active until ${vipEndLabel(_endsAt!)}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.gold)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _benefitsTitle() {
    Widget line() => Expanded(child: Container(height: 1, color: AppColors.stroke));
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
      child: Column(
        children: [
          Row(
            children: [
              line(),
              const SizedBox(width: 8),
              const Icon(Icons.diamond_outlined, size: 12, color: AppColors.textMuted),
              const SizedBox(width: 8),
              const Text('VIP Benefits', style: TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(width: 8),
              const Icon(Icons.diamond_outlined, size: 12, color: AppColors.textMuted),
              const SizedBox(width: 8),
              line(),
            ],
          ),
          const SizedBox(height: 2),
          Text('(${_p.benefits.length})', key: const ValueKey('vip-benefit-count'), style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
        ],
      ),
    );
  }

  Widget _buyBar(bool owned) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        decoration: BoxDecoration(color: AppColors.card, border: Border(top: BorderSide(color: AppColors.stroke))),
        child: Row(
          children: [
            const Icon(Icons.monetization_on_rounded, color: AppColors.coin, size: 22),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(withThousands(_p.priceCoins), key: const ValueKey('vip-price'), style: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w700, fontSize: 18)),
                  Text(vipDaysLabel(_p.durationDays), style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
                ],
              ),
            ),
            SizedBox(
              height: 44,
              child: FilledButton(
                key: const ValueKey('vip-buy'),
                onPressed: _busy ? null : _buy,
                child: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(owned ? 'Extend' : 'Buy'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One benefit of a product: its picture (else the kind's icon) and its name.
class VipBenefitTile extends StatelessWidget {
  const VipBenefitTile({super.key, required this.benefit});

  final VipBenefit benefit;

  @override
  Widget build(BuildContext context) {
    final kind = vipKindFor(benefit.kind);
    final icon = Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.gold.withValues(alpha: 0.14), border: Border.all(color: AppColors.gold.withValues(alpha: 0.5))),
      child: Icon(kind.icon, color: AppColors.gold, size: 28),
    );
    final url = benefit.imageUrl;
    final art = url != null && LabelPicture.supports(url) ? LabelPicture(url: url, height: 64, maxWidth: 110, fallback: icon) : icon;
    final label = benefit.label;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.stroke)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(height: 64, child: Center(child: art)),
          const SizedBox(height: 8),
          Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
