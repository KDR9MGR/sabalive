import 'package:flutter/material.dart';

import '../config/supabase_client.dart';
import '../core/utils/ids.dart';

/// How a staff tag is drawn: a coloured [pill], a [picture] shown as it is (the name is inside the artwork), or a [plate] (a background picture the
/// app writes the name on).
enum TagLook { pill, picture, plate }

/// A staff tag on a profile (Master -> Tags in the panel): a short label with a colour, an optional emoji and one of three looks.
@immutable
class ProfileTag {
  const ProfileTag({
    required this.id,
    required this.name,
    required this.color,
    this.emoji,
    this.look = TagLook.pill,
    this.imageUrl,
    this.textColor,
  });

  final String id;
  final String name;
  final Color color;
  final String? emoji;
  final TagLook look;

  /// The uploaded picture of a [TagLook.picture] / [TagLook.plate] tag (null for a pill).
  final String? imageUrl;

  /// The colour of the name; null = readable on the colour (a pill) or white (a plate).
  final Color? textColor;

  /// Reads a `profile_tags` row. Anything unreadable gives the default purple, and a row without an id or name gives null.
  static ProfileTag? fromRow(Map<String, dynamic>? row) {
    if (row == null) return null;
    final id = row['id'];
    final name = row['name'];
    if (id is! String || name is! String || name.trim().isEmpty) return null;
    final emoji = row['emoji'];
    final image = row['image_url'];
    final imageUrl = image is String && image.trim().isNotEmpty ? image.trim() : null;
    final wanted = switch (row['look']) {
      'picture' => TagLook.picture,
      'plate' => TagLook.plate,
      _ => TagLook.pill,
    };
    final text = row['text_color'];
    return ProfileTag(
      id: id,
      name: name.trim(),
      color: parseTagColor(row['color']),
      emoji: emoji is String && emoji.trim().isNotEmpty ? emoji.trim() : null,
      // a picture look with no picture is just a pill
      look: imageUrl == null ? TagLook.pill : wanted,
      imageUrl: imageUrl,
      textColor: text is String && text.trim().isNotEmpty ? parseTagColor(text) : null,
    );
  }
}

/// `#rrggbb` -> a colour; anything else -> the default purple.
Color parseTagColor(Object? raw, {Color fallback = const Color(0xFF7C3AED)}) {
  if (raw is! String) return fallback;
  final hex = raw.trim().replaceFirst('#', '');
  if (hex.length != 6) return fallback;
  final v = int.tryParse(hex, radix: 16);
  return v == null ? fallback : Color(0xFF000000 | v);
}

/// An earned badge (`badges` / `user_badges`). [iconUrl] is the picture the panel's Badge Management uploaded (null = show the emoji).
@immutable
class ProfileBadge {
  const ProfileBadge({required this.id, required this.name, required this.emoji, this.iconUrl});

  final String id;
  final String name;
  final String emoji;
  final String? iconUrl;
}

/// What a profile shows under the name besides the Store items: the staff tags it was given and the badges it earned.
@immutable
class ProfileLabels {
  const ProfileLabels({this.tags = const [], this.badges = const []});

  final List<ProfileTag> tags;
  final List<ProfileBadge> badges;

  bool get isEmpty => tags.isEmpty && badges.isEmpty;
}

/// Reads both lists for one profile. They are public (any signed-in person can see anyone's tags and badges), and each read FAILS OPEN to
/// an empty list: a server that does not have the tag tables yet, or a dropped connection, just shows no tags.
class ProfileLabelsRepository {
  Future<ProfileLabels> load(String profileId) async {
    if (!isRealId(profileId)) return const ProfileLabels();
    final results = await Future.wait([_tags(profileId), _badges(profileId)]);
    return ProfileLabels(tags: results[0] as List<ProfileTag>, badges: results[1] as List<ProfileBadge>);
  }

  Future<List<ProfileTag>> _tags(String profileId) async {
    try {
      final rows = (await supabase
              .from('profile_tag_assignments')
              .select('assigned_at, profile_tags!inner(id, name, color, emoji, look, image_url, text_color, sort_order)')
              .eq('profile_id', profileId) as List)
          .cast<Map<String, dynamic>>();
      final tags = <({ProfileTag tag, int order})>[];
      for (final r in rows) {
        final t = r['profile_tags'];
        if (t is! Map<String, dynamic>) continue;
        final tag = ProfileTag.fromRow(t);
        if (tag != null) tags.add((tag: tag, order: t['sort_order'] is int ? t['sort_order'] as int : 0));
      }
      tags.sort((a, b) {
        final byOrder = a.order.compareTo(b.order);
        return byOrder != 0 ? byOrder : a.tag.name.toLowerCase().compareTo(b.tag.name.toLowerCase());
      });
      return [for (final t in tags) t.tag];
    } catch (_) {
      return const [];
    }
  }

  Future<List<ProfileBadge>> _badges(String profileId) async {
    try {
      final rows = (await supabase
              .from('user_badges')
              .select('badges!inner(id, name, emoji, icon_url, sort_order)')
              .eq('profile_id', profileId) as List)
          .cast<Map<String, dynamic>>();
      final badges = <({ProfileBadge badge, int order})>[];
      for (final r in rows) {
        final b = r['badges'];
        if (b is! Map<String, dynamic>) continue;
        final id = b['id'];
        final name = b['name'];
        if (id is! String || name is! String) continue;
        final emoji = b['emoji'];
        final icon = b['icon_url'];
        badges.add((
          badge: ProfileBadge(
            id: id,
            name: name,
            emoji: emoji is String && emoji.isNotEmpty ? emoji : '🏅',
            iconUrl: icon is String && icon.trim().isNotEmpty ? icon.trim() : null,
          ),
          order: b['sort_order'] is int ? b['sort_order'] as int : 0,
        ));
      }
      badges.sort((a, b) => a.order.compareTo(b.order));
      return [for (final b in badges) b.badge];
    } catch (_) {
      return const [];
    }
  }
}
