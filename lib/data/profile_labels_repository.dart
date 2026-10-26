import 'dart:async';

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

/// Reads both lists for one profile, or for many at once ([loadMany], for a list of people). They are public (any signed-in person can see anyone's tags and
/// badges), and each read FAILS OPEN to an empty list: a server that does not have the tag tables yet, or a dropped connection, just shows no tags.
class ProfileLabelsRepository {
  Future<ProfileLabels> load(String profileId) async {
    if (!isRealId(profileId)) return const ProfileLabels();
    final many = await loadMany([profileId]);
    return many[profileId] ?? const ProfileLabels();
  }

  /// The labels of every profile in [ids] with TWO reads in all (one for tags, one for badges), however many people there are: a followers list or a ranking
  /// asks once, not once per row. A person with nothing is simply absent from the result.
  Future<Map<String, ProfileLabels>> loadMany(Iterable<String> ids) async {
    final wanted = {for (final id in ids) if (isRealId(id)) id}.toList();
    if (wanted.isEmpty) return const {};
    final results = await Future.wait([_tagRows(wanted), _badgeRows(wanted)]);
    final tags = groupTags(results[0]);
    final badges = groupBadges(results[1]);
    return {
      for (final id in {...tags.keys, ...badges.keys}) id: ProfileLabels(tags: tags[id] ?? const [], badges: badges[id] ?? const []),
    };
  }

  Future<List<Map<String, dynamic>>> _tagRows(List<String> ids) async {
    try {
      return (await supabase
              .from('profile_tag_assignments')
              .select('profile_id, assigned_at, profile_tags!inner(id, name, color, emoji, look, image_url, text_color, sort_order)')
              .inFilter('profile_id', ids) as List)
          .cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> _badgeRows(List<String> ids) async {
    try {
      return (await supabase.from('user_badges').select('profile_id, badges!inner(id, name, emoji, icon_url, sort_order)').inFilter('profile_id', ids) as List)
          .cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  /// `profile_tag_assignments` rows (with their `profile_tags`) -> each person's tags, in the panel's order, then by name.
  @visibleForTesting
  static Map<String, List<ProfileTag>> groupTags(List<Map<String, dynamic>> rows) {
    final byPerson = <String, List<({ProfileTag tag, int order})>>{};
    for (final r in rows) {
      final person = r['profile_id'];
      final t = r['profile_tags'];
      if (person is! String || t is! Map<String, dynamic>) continue;
      final tag = ProfileTag.fromRow(t);
      if (tag == null) continue;
      (byPerson[person] ??= []).add((tag: tag, order: t['sort_order'] is int ? t['sort_order'] as int : 0));
    }
    return {
      for (final e in byPerson.entries)
        e.key: [
          for (final t in (e.value
            ..sort((a, b) {
              final byOrder = a.order.compareTo(b.order);
              return byOrder != 0 ? byOrder : a.tag.name.toLowerCase().compareTo(b.tag.name.toLowerCase());
            })))
            t.tag,
        ],
    };
  }

  /// `user_badges` rows (with their `badges`) -> each person's badges, in the panel's order.
  @visibleForTesting
  static Map<String, List<ProfileBadge>> groupBadges(List<Map<String, dynamic>> rows) {
    final byPerson = <String, List<({ProfileBadge badge, int order})>>{};
    for (final r in rows) {
      final person = r['profile_id'];
      final b = r['badges'];
      if (person is! String || b is! Map<String, dynamic>) continue;
      final id = b['id'];
      final name = b['name'];
      if (id is! String || name is! String) continue;
      final emoji = b['emoji'];
      final icon = b['icon_url'];
      (byPerson[person] ??= []).add((
        badge: ProfileBadge(
          id: id,
          name: name,
          emoji: emoji is String && emoji.isNotEmpty ? emoji : '🏅',
          iconUrl: icon is String && icon.trim().isNotEmpty ? icon.trim() : null,
        ),
        order: b['sort_order'] is int ? b['sort_order'] as int : 0,
      ));
    }
    return {
      for (final e in byPerson.entries) e.key: [for (final b in (e.value..sort((a, b) => a.order.compareTo(b.order)))) b.badge],
    };
  }
}

/// Labels for many people on one screen, fetched together. Every row of a list asks [get]; the asks made in the same moment become ONE [ProfileLabelsRepository.loadMany]
/// call, and an answer is kept for [ttl], so scrolling back, or opening the same person's card again, costs nothing. Never throws: no answer is "no labels".
class ProfileLabelsCache {
  ProfileLabelsCache({
    Future<Map<String, ProfileLabels>> Function(List<String> ids)? loader,
    this.ttl = const Duration(minutes: 5),
    this.batchDelay = const Duration(milliseconds: 40),
    this.maxEntries = 300,
    DateTime Function()? now,
  })  : _loader = loader ?? ((ids) => ProfileLabelsRepository().loadMany(ids)),
        _now = now ?? DateTime.now;

  static final ProfileLabelsCache instance = ProfileLabelsCache();

  final Future<Map<String, ProfileLabels>> Function(List<String> ids) _loader;
  final Duration ttl;
  final Duration batchDelay;
  final int maxEntries;
  final DateTime Function() _now;

  final Map<String, ({ProfileLabels labels, DateTime at})> _kept = {};
  final Map<String, Completer<ProfileLabels>> _waiting = {};
  Timer? _timer;

  /// What is kept for [id] right now (null = not asked yet or expired): lets a row draw at once without a flash.
  ProfileLabels? peek(String id) {
    final k = _kept[id];
    if (k == null || _now().difference(k.at) > ttl) return null;
    return k.labels;
  }

  Future<ProfileLabels> get(String id) {
    if (!isRealId(id)) return Future.value(const ProfileLabels());
    final kept = peek(id);
    if (kept != null) return Future.value(kept);
    final waiting = _waiting[id];
    if (waiting != null) return waiting.future;
    final c = _waiting[id] = Completer<ProfileLabels>();
    _timer ??= Timer(batchDelay, _flush);
    return c.future;
  }

  Future<void> _flush() async {
    _timer = null;
    final batch = Map<String, Completer<ProfileLabels>>.of(_waiting);
    _waiting.clear();
    if (batch.isEmpty) return;
    Map<String, ProfileLabels> found = const {};
    var ok = true;
    try {
      // a long list is read in pieces, so one request never carries hundreds of ids
      final ids = batch.keys.toList();
      final all = <String, ProfileLabels>{};
      for (var i = 0; i < ids.length; i += 60) {
        all.addAll(await _loader(ids.sublist(i, i + 60 > ids.length ? ids.length : i + 60)));
      }
      found = all;
    } catch (_) {
      ok = false;
    }
    final at = _now();
    for (final e in batch.entries) {
      final labels = found[e.key] ?? const ProfileLabels();
      // a failed read is not remembered: the next screen tries again
      if (ok) _remember(e.key, labels, at);
      if (!e.value.isCompleted) e.value.complete(labels);
    }
  }

  void _remember(String id, ProfileLabels labels, DateTime at) {
    if (_kept.length >= maxEntries) _kept.remove(_kept.keys.first);
    _kept[id] = (labels: labels, at: at);
  }

  /// Forget everything (tests, sign-out).
  void clear() {
    _kept.clear();
  }
}
