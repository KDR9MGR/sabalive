import '../config/supabase_client.dart';

enum StoreCategory { frame, vip, entryEffect, vehicle, roomSkin }

StoreCategory _categoryFromRow(String v) => switch (v) {
      'frame' => StoreCategory.frame,
      'vip' => StoreCategory.vip,
      'entry_effect' => StoreCategory.entryEffect,
      'room_skin' => StoreCategory.roomSkin,
      _ => StoreCategory.vehicle,
    };

class StoreItem {
  StoreItem({
    required this.id,
    required this.category,
    required this.name,
    required this.emoji,
    required this.priceCoins,
    required this.durationDays,
    this.assetUrl,
  });

  factory StoreItem.fromRow(Map<String, dynamic> row) => StoreItem(
        id: row['id'] as String,
        category: _categoryFromRow(row['category'] as String),
        name: row['name'] as String,
        emoji: row['emoji'] as String,
        priceCoins: row['price_coins'] as int,
        durationDays: row['duration_days'] as int,
        assetUrl: _nonEmpty(row['asset_url']),
      );

  static String? _nonEmpty(Object? v) {
    final s = (v as String?)?.trim();
    return s == null || s.isEmpty ? null : s;
  }

  final String id;
  final StoreCategory category;
  final String name;
  final String emoji;
  final int priceCoins;
  final int durationDays;

  /// Artwork uploaded in the admin panel (SVGA / MP4 / WebP / GIF / PNG); the
  /// emoji stays the stand-in for items that have none.
  final String? assetUrl;
}

class OwnedItem {
  OwnedItem(this.item, this.expiresAt, this.equipped);
  final StoreItem item;
  final DateTime expiresAt;
  final bool equipped;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// Store / My Bag / VIP — `store_items` (public catalog) and `user_items`
/// (ownership + equip state, also public — a frame/VIP tag is cosmetic
/// status meant to be seen by others). Every write goes through
/// `purchase_store_item`/`set_item_equipped` (both SECURITY DEFINER); no
/// direct client insert path exists for either.
class StoreRepository {
  Future<List<StoreItem>> catalog() async {
    final rows = await supabase
        .from('store_items')
        .select()
        .eq('status', 'active')
        .order('category', ascending: true)
        .order('sort_order', ascending: true);
    return rows.map(StoreItem.fromRow).toList();
  }

  static final Map<String, StoreItem> _byId = {};

  /// Store items by id, for rendering something another user has equipped (an
  /// entry effect, a room skin). Remembered for the session, since the same
  /// handful of items come up again and again.
  Future<List<StoreItem>> itemsByIds(List<String> ids) async {
    final missing = [
      for (final id in ids.toSet())
        if (!_byId.containsKey(id)) id,
    ];
    if (missing.isNotEmpty) {
      final rows = await supabase.from('store_items').select().inFilter('id', missing);
      for (final r in rows) {
        final item = StoreItem.fromRow(r);
        _byId[item.id] = item;
      }
    }
    return [
      for (final id in ids)
        if (_byId[id] case final item?) item,
    ];
  }

  /// The artwork url of store item [itemId] (a room skin, say), or null when
  /// there is no item or it has no artwork.
  Future<String?> assetUrlFor(String? itemId) async {
    if (itemId == null) return null;
    final items = await itemsByIds([itemId]);
    return items.isEmpty ? null : items.first.assetUrl;
  }

  Future<List<OwnedItem>> myItems() async {
    final me = supabase.auth.currentUser?.id;
    if (me == null) return const [];
    final rows = await supabase
        .from('user_items')
        .select('expires_at, equipped, store_items(*)')
        .eq('profile_id', me)
        .gt('expires_at', DateTime.now().toUtc().toIso8601String())
        .order('expires_at', ascending: true);
    return [
      for (final r in rows)
        if (r['store_items'] case final Map<String, dynamic> item)
          OwnedItem(
            StoreItem.fromRow(item),
            DateTime.parse(r['expires_at'] as String).toLocal(),
            r['equipped'] as bool,
          ),
    ];
  }

  /// The frame/VIP tag a specific profile currently shows to everyone —
  /// used to render equipped cosmetics on any profile, not just your own.
  Future<List<OwnedItem>> equippedFor(String profileId) async {
    final rows = await supabase
        .from('user_items')
        .select('expires_at, equipped, store_items(*)')
        .eq('profile_id', profileId)
        .eq('equipped', true)
        .gt('expires_at', DateTime.now().toUtc().toIso8601String());
    return [
      for (final r in rows)
        if (r['store_items'] case final Map<String, dynamic> item)
          OwnedItem(
            StoreItem.fromRow(item),
            DateTime.parse(r['expires_at'] as String).toLocal(),
            true,
          ),
    ];
  }

  Future<void> purchase(String itemId) async {
    await supabase.rpc('purchase_store_item', params: {'p_item_id': itemId});
  }

  Future<void> setEquipped(String itemId, bool equipped) async {
    await supabase.rpc('set_item_equipped', params: {
      'p_item_id': itemId,
      'p_equipped': equipped,
    });
  }
}
