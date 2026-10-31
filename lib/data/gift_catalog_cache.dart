import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The last gift list the server sent, kept on the phone, so the gift sheet and every gift effect know their gifts the moment the app opens instead of after the
/// network answers (stale-while-revalidate: the fresh list replaces it as soon as it arrives). Never throws: no cache just means waiting for the network, as before.
class GiftCatalogCache {
  static const _key = 'gifts.catalog.v1';

  static Future<List<Map<String, dynamic>>?> read() async {
    try {
      final text = (await SharedPreferences.getInstance()).getString(_key);
      if (text == null || text.isEmpty) return null;
      final decoded = jsonDecode(text);
      if (decoded is! List) return null;
      return [for (final r in decoded) if (r is Map) Map<String, dynamic>.from(r)];
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(List<Map<String, dynamic>> rows) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(rows));
    } catch (_) {}
  }
}
