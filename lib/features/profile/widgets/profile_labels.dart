import 'package:flutter/material.dart' hide Text;

import '../../../core/i18n/text.dart';
import '../../../core/media/disk_cached_image.dart';
import '../../../core/widgets/label_picture.dart';
import '../../../core/widgets/remote_media.dart' show MediaKind, RemoteMedia, mediaKindFor;
import '../../../data/profile_labels_repository.dart';
import '../../../theme/app_colors.dart';

/// How many tags / badges one profile shows before "+N".
const int kProfileLabelsShown = 6;

/// How many a one-line list row shows before "+N".
const int kCompactLabelsShown = 3;

/// How big badges and tags are drawn. A profile's own are generous; a row in a list (followers, search, a room's user card) uses the compact set.
@immutable
class LabelSizes {
  const LabelSizes({
    required this.badge,
    required this.tag,
    required this.chipEmoji,
    required this.chipText,
    required this.pillText,
    required this.padX,
    required this.padY,
  });

  /// The height of a badge picture, and of a badge chip's text row.
  final double badge;

  /// The height of a tag that is a picture or a plate.
  final double tag;
  final double chipEmoji;
  final double chipText;
  final double pillText;
  final double padX;
  final double padY;

  static const profile = LabelSizes(badge: 34, tag: 28, chipEmoji: 16, chipText: 12.5, pillText: 12, padX: 11, padY: 5);
  static const compact = LabelSizes(badge: 22, tag: 20, chipEmoji: 11, chipText: 10, pillText: 9.5, padX: 7, padY: 2);
}

/// What a profile shows under the name: the BADGES it earned, then the staff TAGS it was given (set in the panel's Tags page). The Store's own items (frame names,
/// VIP) are never shown here. A badge with an uploaded picture is the picture itself, as a banner; one without is an outlined chip with its emoji and name. Tapping a
/// badge (or the "+N") calls [onBadgesTap], which opens the full Badges page. Nothing is drawn while there is nothing to show or while it loads, so a profile never
/// jumps for people without any.
///
/// [compact] is the one-line version for a row in a list: smaller, at most [kCompactLabelsShown], read through [ProfileLabelsCache] so a whole list costs two
/// database reads, not two per row.
class ProfileLabelsRow extends StatefulWidget {
  const ProfileLabelsRow({
    super.key,
    required this.profileId,
    this.alignment = WrapAlignment.start,
    this.onBadgesTap,
    this.compact = false,
    @visibleForTesting this.loader,
  });

  final String profileId;
  final WrapAlignment alignment;
  final VoidCallback? onBadgesTap;
  final bool compact;

  /// Replaces the database read (tests).
  final Future<ProfileLabels> Function(String profileId)? loader;

  @override
  State<ProfileLabelsRow> createState() => _ProfileLabelsRowState();
}

class _ProfileLabelsRowState extends State<ProfileLabelsRow> {
  late ProfileLabels _labels = _kept ?? const ProfileLabels();

  ProfileLabels? get _kept => widget.compact && widget.loader == null ? ProfileLabelsCache.instance.peek(widget.profileId) : null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ProfileLabelsRow old) {
    super.didUpdateWidget(old);
    if (old.profileId != widget.profileId) {
      _labels = _kept ?? const ProfileLabels();
      _load();
    }
  }

  Future<void> _load() async {
    final id = widget.profileId;
    try {
      final labels = await (widget.loader ?? (widget.compact ? ProfileLabelsCache.instance.get : ProfileLabelsRepository().load))(id);
      if (mounted && id == widget.profileId) setState(() => _labels = labels);
    } catch (_) {
      // no labels is always a fine answer
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_labels.isEmpty) return const SizedBox.shrink();
    final sizes = widget.compact ? LabelSizes.compact : LabelSizes.profile;
    final limit = widget.compact ? kCompactLabelsShown : kProfileLabelsShown;
    // in a compact row the badges and tags share the limit (badges first); on a profile each has its own
    final badges = _labels.badges.take(limit).toList();
    final tags = _labels.tags.take(widget.compact ? (limit - badges.length).clamp(0, limit) : limit).toList();
    final hiddenBadges = _labels.badges.length - badges.length;
    final hiddenTags = _labels.tags.length - tags.length;
    final children = <Widget>[
      for (final b in badges) _BadgeChip(badge: b, sizes: sizes, onTap: widget.onBadgesTap),
      if (hiddenBadges > 0) _more('+$hiddenBadges', widget.onBadgesTap, sizes),
      for (final t in tags) TagPill(tag: t, sizes: sizes),
      if (hiddenTags > 0) _more('+$hiddenTags', null, sizes),
    ];
    if (widget.compact) {
      // one line, never taller than a badge: whatever does not fit is clipped, never wrapped under the name
      return Padding(
        padding: const EdgeInsets.only(top: 3),
        child: SizedBox(
        key: const ValueKey('profile-labels'),
        height: sizes.badge,
        child: ClipRect(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [for (final c in children) Padding(padding: const EdgeInsets.only(right: 4), child: c)],
            ),
          ),
        ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        key: const ValueKey('profile-labels'),
        alignment: widget.alignment,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 6,
        // badges first, then tags, as in the reference screenshot (a Viscount badge, then Super Admin and Sahi BDM tags)
        children: children,
      ),
    );
  }

  Widget _more(String text, VoidCallback? onTap, LabelSizes sizes) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: sizes.padX, vertical: sizes.padY),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), border: Border.all(color: AppColors.stroke)),
          child: Text(text, style: TextStyle(fontSize: sizes.chipText, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
        ),
      );
}

/// The height of a tag that is a picture or a plate on a profile.
const double kTagPictureHeight = 28;

/// One staff tag, in the look the panel chose: a PICTURE shown as it is (the name is part of the artwork), a PLATE (a background picture with the name
/// written on it) or a solid coloured PILL. A picture that can't be loaded (offline, a deleted file) falls back to the pill, so a tag never vanishes.
///
/// A plate is exactly as wide as its name needs (plus a little), as tall as [sizes] say, and its picture fills it, cropped rather than stretched: it used to
/// expand to the whole width of the row, which stretched the artwork and left the name floating in the middle of it.
class TagPill extends StatelessWidget {
  const TagPill({super.key, required this.tag, this.sizes = LabelSizes.profile});
  final ProfileTag tag;
  final LabelSizes sizes;

  String get _label => tag.emoji == null ? tag.name : '${tag.emoji} ${tag.name}';

  Widget _pill() {
    final dark = ThemeData.estimateBrightnessForColor(tag.color) == Brightness.dark;
    return Container(
      key: ValueKey('tag-${tag.id}'),
      padding: EdgeInsets.symmetric(horizontal: sizes.padX, vertical: sizes.padY),
      decoration: BoxDecoration(color: tag.color, borderRadius: BorderRadius.circular(20)),
      child: Text(
        _label,
        style: TextStyle(fontSize: sizes.pillText, fontWeight: FontWeight.w700, color: tag.textColor ?? (dark ? Colors.white : const Color(0xFF1B1030))),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = tag.imageUrl;
    if (url == null || tag.look == TagLook.pill) return _pill();
    if (!LabelPicture.supports(url)) return _pill(); // a video file is not drawn on a profile
    if (tag.look == TagLook.picture) {
      // the artwork exactly as uploaded: a picture, a GIF / WebP, an SVG or an SVGA animation; the pill stands in while it loads and if it can't be drawn
      return Semantics(
        label: tag.name,
        child: LabelPicture(key: ValueKey('tag-${tag.id}'), url: url, height: sizes.tag, maxWidth: sizes.tag * 8, fallback: _pill()),
      );
    }
    final plate = DecoratedBox(decoration: BoxDecoration(color: tag.color));
    final kind = mediaKindFor(url);
    return ClipRRect(
      key: ValueKey('tag-${tag.id}'),
      borderRadius: BorderRadius.circular(sizes.tag / 2),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: kind == MediaKind.svga || kind == MediaKind.svg
                ? RemoteMedia(url, fit: BoxFit.cover, loop: true, fallback: plate)
                : Image(image: DiskCachedNetworkImage(url), fit: BoxFit.cover, errorBuilder: (_, _, _) => plate),
          ),
          // the name decides the width: a row (not a Center) so the plate does not grow to fill the space it is given
          Container(
            height: sizes.tag,
            padding: EdgeInsets.symmetric(horizontal: sizes.padX + 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  _label,
                  style: TextStyle(
                    fontSize: sizes.pillText,
                    fontWeight: FontWeight.w800,
                    color: tag.textColor ?? Colors.white,
                    shadows: const [Shadow(color: Color(0x99000000), blurRadius: 2, offset: Offset(0, 1))],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BadgeChip extends StatelessWidget {
  const _BadgeChip({required this.badge, required this.sizes, this.onTap});
  final ProfileBadge badge;
  final LabelSizes sizes;
  final VoidCallback? onTap;

  /// A badge picture is drawn as uploaded (still, SVG, GIF / WebP or SVGA). A video file (MP4) is not played here: a decoder per badge would cost battery.
  /// That, and a badge with no picture, is drawn as the emoji chip.
  bool get _hasPicture {
    final url = badge.iconUrl;
    return url != null && LabelPicture.supports(url);
  }

  Widget _chip() => Container(
        padding: EdgeInsets.symmetric(horizontal: sizes.padX, vertical: sizes.padY),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.gold.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(badge.emoji, style: TextStyle(fontSize: sizes.chipEmoji)),
            const SizedBox(width: 4),
            Text(badge.name, style: TextStyle(fontSize: sizes.chipText, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => GestureDetector(
        key: ValueKey('badge-${badge.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: _hasPicture
            // the picture IS the badge (its artwork carries the name), shown as it is; if it can't load, the chip takes over
            ? Semantics(
                label: badge.name,
                child: LabelPicture(key: ValueKey('badge-icon-${badge.id}'), url: badge.iconUrl!, height: sizes.badge, fallback: _chip()),
              )
            : _chip(),
      );
}

/// The second line of a row in a list of people: [text] ("ID: 100123", "Visited 2h ago") with the person's badges and tags under it, in the compact size. Costs nothing
/// when the person has none, and a whole list costs two database reads in all ([ProfileLabelsCache]).
class PersonLine extends StatelessWidget {
  const PersonLine({super.key, required this.profileId, required this.text, this.style});
  final String profileId;
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: style ?? const TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
          ProfileLabelsRow(profileId: profileId, compact: true),
        ],
      );
}
