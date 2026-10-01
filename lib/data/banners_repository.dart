import '../config/supabase_client.dart';

class PromoBanner {
  PromoBanner({
    required this.id,
    required this.title,
    required this.imageUrl,
    this.linkUrl,
  });

  factory PromoBanner.fromRow(Map<String, dynamic> row) => PromoBanner(
        id: row['id'] as String,
        title: row['title'] as String,
        imageUrl: row['image_url'] as String? ?? '',
        linkUrl: row['link_url'] as String?,
      );

  final String id;
  final String title;
  final String imageUrl;
  final String? linkUrl;
}

class BannersRepository {
  Future<List<PromoBanner>> homeTop() async {
    final rows = (await supabase
            .from('banners')
            .select()
            .eq('placement', 'home_top')
            .eq('status', 'active') as List)
        .cast<Map<String, dynamic>>();
    return [
      for (final r in rows)
        if ((r['image_url'] as String?)?.startsWith('http') ?? false) PromoBanner.fromRow(r),
    ];
  }
}
