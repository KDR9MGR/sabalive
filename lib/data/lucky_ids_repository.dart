import '../config/supabase_client.dart';

/// A special app ID number for sale in the Store's Lucky ID tab. Owning one replaces
/// the user's own app ID for its duration (the server swaps profiles.display_id and
/// puts the original back when it ends).
class LuckyId {
  LuckyId({
    required this.id,
    required this.number,
    required this.priceCoins,
    required this.durationDays,
    this.ownerId,
    this.expiresAt,
  });

  factory LuckyId.fromRow(Map<String, dynamic> row) => LuckyId(
        id: row['id'] as String,
        number: row['number'] as int,
        priceCoins: row['price_coins'] as int,
        durationDays: row['duration_days'] as int,
        ownerId: row['owner_id'] as String?,
        expiresAt: DateTime.tryParse('${row['expires_at'] ?? ''}')?.toLocal(),
      );

  final String id;
  final int number;
  final int priceCoins;
  final int durationDays;
  final String? ownerId;
  final DateTime? expiresAt;

  bool get taken =>
      ownerId != null && expiresAt != null && expiresAt!.isAfter(DateTime.now());
}

class LuckyIdsRepository {
  /// The numbers still for sale, then (separately) the one this user holds now.
  Future<({List<LuckyId> forSale, LuckyId? mine})> load() async {
    final me = supabase.auth.currentUser?.id;
    final rows = await supabase
        .from('lucky_ids')
        .select()
        .eq('status', 'active')
        .order('number', ascending: true);
    final all = [for (final r in rows) LuckyId.fromRow(r)];
    final mine = all.where((l) => l.taken && l.ownerId == me).firstOrNull;
    return (forSale: all.where((l) => !l.taken).toList(), mine: mine);
  }

  Future<void> purchase(String id) async {
    await supabase.rpc('purchase_lucky_id', params: {'p_lucky': id});
  }
}
