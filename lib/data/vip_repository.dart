import 'package:flutter/foundation.dart';

import '../config/supabase_client.dart';
import '../core/utils/ids.dart';
import '../features/vip/vip_kinds.dart';

/// One thing a VIP product includes (`vip_product_benefits`, sabalive migration 20261106120000): a kind, an optional title and picture from the panel, and, for some kinds, a
/// link to a Store item that the buyer is given.
@immutable
class VipBenefit {
  const VipBenefit({required this.id, required this.kind, this.title, this.imageUrl, this.linkItemId, this.order = 0});

  final String id;
  final String kind;
  final String? title;
  final String? imageUrl;
  final String? linkItemId;
  final int order;

  /// What the tile says: the panel's own title when there is one, else the kind's name (English; the screen translates it). A kind the app does not know and has no title: empty.
  String get label {
    final t = title;
    if (t != null && t.trim().isNotEmpty) return t.trim();
    return vipKindFor(kind).label;
  }

  static VipBenefit? fromRow(Map<String, dynamic>? row) {
    if (row == null) return null;
    final id = row['id'];
    final kind = row['kind'];
    if (id is! String || kind is! String || kind.isEmpty) return null;
    final title = row['title'];
    final image = row['image_url'];
    final link = row['link_item_id'];
    return VipBenefit(
      id: id,
      kind: kind,
      title: title is String && title.trim().isNotEmpty ? title.trim() : null,
      imageUrl: image is String && image.trim().isNotEmpty ? image.trim() : null,
      linkItemId: link is String && link.isNotEmpty ? link : null,
      order: row['sort_order'] is int ? row['sort_order'] as int : 0,
    );
  }
}

/// A VIP product (`vip_products`): one card in the VIP list and one page of benefits with a price. A product is a bundle: it is bought as one thing.
@immutable
class VipProduct {
  const VipProduct({
    required this.id,
    required this.name,
    required this.priceCoins,
    required this.durationDays,
    this.tagline,
    this.badgeUrl,
    this.sortOrder = 0,
    this.benefits = const [],
  });

  final String id;
  final String name;
  final String? tagline;

  /// The badge picture (still, GIF, WebP, SVG or SVGA); null = a plain crown.
  final String? badgeUrl;
  final int priceCoins;
  final int durationDays;
  final int sortOrder;
  final List<VipBenefit> benefits;

  /// Reads a `vip_products` row with its embedded `vip_product_benefits`. A row without an id, name or a sane price / length gives null, so a bad row never breaks the list.
  static VipProduct? fromRow(Map<String, dynamic>? row) {
    if (row == null) return null;
    final id = row['id'];
    final name = row['name'];
    final price = row['price_coins'];
    final days = row['duration_days'];
    if (id is! String || name is! String || name.trim().isEmpty || price is! num || days is! num || price <= 0 || days <= 0) return null;
    final tagline = row['tagline'];
    final badge = row['badge_url'];
    final rawBenefits = row['vip_product_benefits'];
    final benefits = <VipBenefit>[
      if (rawBenefits is List)
        for (final b in rawBenefits)
          if (b is Map<String, dynamic>) ?VipBenefit.fromRow(b),
    ]..sort((a, b) => a.order.compareTo(b.order));
    return VipProduct(
      id: id,
      name: name.trim(),
      tagline: tagline is String && tagline.trim().isNotEmpty ? tagline.trim() : null,
      badgeUrl: badge is String && badge.trim().isNotEmpty ? badge.trim() : null,
      priceCoins: price.toInt(),
      durationDays: days.toInt(),
      sortOrder: row['sort_order'] is int ? row['sort_order'] as int : 0,
      benefits: benefits,
    );
  }
}

/// The badge a person shows on their profile while a VIP is active: the picture of the product (null = just its name).
@immutable
class VipBadge {
  const VipBadge({required this.name, this.imageUrl});

  final String name;
  final String? imageUrl;
}

/// Reads and buys VIP products. `vip_products` / `vip_product_benefits` are readable for ACTIVE products only; `user_vip` says who owns what and until when; buying is
/// `purchase_vip_product` (a SECURITY DEFINER function that takes the coins, starts or extends the days and gives the linked Store items).
class VipRepository {
  /// The active products in the panel's order (then cheapest first), each with its benefits.
  Future<List<VipProduct>> fetchProducts() async {
    final rows = (await supabase
            .from('vip_products')
            .select('id, name, tagline, badge_url, price_coins, duration_days, sort_order, vip_product_benefits(id, kind, title, image_url, link_item_id, sort_order)')
            .eq('status', 'active')
            .order('sort_order', ascending: true)
            .order('price_coins', ascending: true) as List)
        .cast<Map<String, dynamic>>();
    return [
      for (final r in rows) ?VipProduct.fromRow(r),
    ];
  }

  /// The products the signed-in person owns right now: product id -> when it ends. Anything that has ended is left out.
  Future<Map<String, DateTime>> fetchMine(String profileId) async {
    if (!isRealId(profileId)) return const {};
    final rows = (await supabase
            .from('user_vip')
            .select('product_id, expires_at')
            .eq('profile_id', profileId)
            .gt('expires_at', DateTime.now().toUtc().toIso8601String()) as List)
        .cast<Map<String, dynamic>>();
    return ownedFrom(rows);
  }

  @visibleForTesting
  static Map<String, DateTime> ownedFrom(List<Map<String, dynamic>> rows, {DateTime? now}) {
    final at = (now ?? DateTime.now()).toUtc();
    final out = <String, DateTime>{};
    for (final r in rows) {
      final id = r['product_id'];
      final end = r['expires_at'] is String ? DateTime.tryParse(r['expires_at'] as String) : null;
      if (id is! String || end == null || !end.toUtc().isAfter(at)) continue;
      final kept = out[id];
      if (kept == null || end.isAfter(kept)) out[id] = end.toLocal();
    }
    return out;
  }

  /// Buys the product (or adds its days when it is already active). Returns when the VIP now ends. Throws the server's own message ("Insufficient coins", "This VIP is not available").
  Future<DateTime> purchase(String productId) async {
    final res = await supabase.rpc('purchase_vip_product', params: {'p_product_id': productId});
    final end = res is Map ? DateTime.tryParse('${res['expires_at']}') : null;
    return (end ?? DateTime.now().add(const Duration(days: 30))).toLocal();
  }

  /// The badge [profileId] shows: the dearest of the products they own right now (null = none, or a server without the tables). Never throws: no badge is a fine answer.
  Future<VipBadge?> badgeFor(String profileId) async {
    if (!isRealId(profileId)) return null;
    try {
      final rows = (await supabase
              .from('user_vip')
              .select('expires_at, vip_products!inner(name, badge_url, price_coins)')
              .eq('profile_id', profileId)
              .gt('expires_at', DateTime.now().toUtc().toIso8601String()) as List)
          .cast<Map<String, dynamic>>();
      return pickBadge(rows);
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static VipBadge? pickBadge(List<Map<String, dynamic>> rows) {
    Map<String, dynamic>? best;
    var bestPrice = -1;
    for (final r in rows) {
      final p = r['vip_products'];
      if (p is! Map<String, dynamic> || p['name'] is! String || (p['name'] as String).trim().isEmpty) continue;
      final price = p['price_coins'] is num ? (p['price_coins'] as num).toInt() : 0;
      if (price > bestPrice) {
        best = p;
        bestPrice = price;
      }
    }
    if (best == null) return null;
    final badge = best['badge_url'];
    return VipBadge(name: (best['name'] as String).trim(), imageUrl: badge is String && badge.trim().isNotEmpty ? badge.trim() : null);
  }
}
