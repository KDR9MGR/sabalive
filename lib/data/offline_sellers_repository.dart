import '../config/supabase_client.dart';
import 'models.dart';

class OfflineSellersRepository {
  Future<List<OfflineSeller>> list() async {
    final rows = (await supabase
            .from('offline_coin_sellers')
            .select()
            .order('sort_order', ascending: true) as List)
        .cast<Map<String, dynamic>>();
    return [for (final r in rows) OfflineSeller.fromRow(r)];
  }
}
