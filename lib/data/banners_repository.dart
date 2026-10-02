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

/// How long a banner shows before the carousel slides on. Set from the admin
/// panel (Banners -> Auto-slide); 20 seconds unless it says otherwise, and
/// 20 seconds again if it can't be read.
const defaultBannerInterval = Duration(seconds: 20);
const _minBannerInterval = Duration(seconds: 3);
const _maxBannerInterval = Duration(seconds: 600);

Duration clampBannerInterval(int? seconds) {
  if (seconds == null) return defaultBannerInterval;
  final d = Duration(seconds: seconds);
  if (d < _minBannerInterval) return _minBannerInterval;
  if (d > _maxBannerInterval) return _maxBannerInterval;
  return d;
}

class BannersRepository {
  Future<Duration> slideInterval() async {
    try {
      final row = await supabase
          .from('banner_settings')
          .select('slide_interval_seconds')
          .eq('id', true)
          .maybeSingle();
      return clampBannerInterval(row?['slide_interval_seconds'] as int?);
    } catch (_) {
      return defaultBannerInterval;
    }
  }

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
