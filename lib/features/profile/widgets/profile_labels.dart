import 'package:flutter/material.dart' hide Text;

import '../../../core/i18n/text.dart';
import '../../../core/media/disk_cached_image.dart';
import '../../../core/widgets/label_picture.dart';
import '../../../core/widgets/remote_media.dart' show MediaKind, RemoteMedia, mediaKindFor;
import '../../../data/profile_labels_repository.dart';
import '../../../theme/app_colors.dart';

/// How many tags / badges one profile shows before "+N".
const int kProfileLabelsShown = 6;

/// What a profile shows under the name besides the Store items: the BADGES it earned, then the staff TAGS it was given (set in the panel's Tags page).
/// A badge with an uploaded picture is the picture itself, as a banner; one without is an outlined chip with its emoji and name. Tapping a badge (or the
/// "+N") calls [onBadgesTap], which opens the full Badges page. Nothing is drawn while there is nothing to show or while it loads, so a profile never
/// jumps for people without any.
class ProfileLabelsRow extends StatefulWidget {
  const ProfileLabelsRow({
    super.key,
    required this.profileId,
    this.alignment = WrapAlignment.start,
    this.onBadgesTap,
    @visibleForTesting this.loader,
  });

  final String profileId;
  final WrapAlignment alignment;
  final VoidCallback? onBadgesTap;

  /// Replaces the database read (tests).
  final Future<ProfileLabels> Function(String profileId)? loader;

  @override
  State<ProfileLabelsRow> createState() => _ProfileLabelsRowState();
}

class _ProfileLabelsRowState extends State<ProfileLabelsRow> {
  ProfileLabels _labels = const ProfileLabels();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ProfileLabelsRow old) {
    super.didUpdateWidget(old);
    if (old.profileId != widget.profileId) {
      _labels = const ProfileLabels();
      _load();
    }
  }

  Future<void> _load() async {
    final id = widget.profileId;
    try {
      final labels = await (widget.loader ?? ProfileLabelsRepository().load)(id);
      if (mounted && id == widget.profileId) setState(() => _labels = labels);
    } catch (_) {
      // no labels is always a fine answer
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_labels.isEmpty) return const SizedBox.shrink();
    final tags = _labels.tags.take(kProfileLabelsShown).toList();
    final badges = _labels.badges.take(kProfileLabelsShown).toList();
    final hiddenTags = _labels.tags.length - tags.length;
    final hiddenBadges = _labels.badges.length - badges.length;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        key: const ValueKey('profile-labels'),
        alignment: widget.alignment,
        spacing: 6,
        runSpacing: 6,
        // badges first, then tags, as in the reference screenshot (a Viscount badge, then Super Admin and Sahi BDM tags)
        children: [
          for (final b in badges) _BadgeChip(badge: b, onTap: widget.onBadgesTap),
          if (hiddenBadges > 0) _more('+$hiddenBadges', widget.onBadgesTap),
          for (final t in tags) TagPill(tag: t),
          if (hiddenTags > 0) _more('+$hiddenTags', null),
        ],
      ),
    );
  }

  Widget _more(String text, VoidCallback? onTap) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), border: Border.all(color: AppColors.stroke)),
          child: Text(text, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
        ),
      );
}

/// The height of a tag that is a picture or a plate.
const double kTagPictureHeight = 26;

/// One staff tag, in the look the panel chose: a PICTURE shown as it is (the name is part of the artwork), a PLATE (a background picture with the name
/// written on it) or a solid coloured PILL. A picture that can't be loaded (offline, a deleted file) falls back to the pill, so a tag never vanishes.
class TagPill extends StatelessWidget {
  const TagPill({super.key, required this.tag});
  final ProfileTag tag;

  String get _label => tag.emoji == null ? tag.name : '${tag.emoji} ${tag.name}';

  Widget _pill() {
    final dark = ThemeData.estimateBrightnessForColor(tag.color) == Brightness.dark;
    return Container(
      key: ValueKey('tag-${tag.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: tag.color, borderRadius: BorderRadius.circular(20)),
      child: Text(
        _label,
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: tag.textColor ?? (dark ? Colors.white : const Color(0xFF1B1030))),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = tag.imageUrl;
    if (url == null || tag.look == TagLook.pill) return _pill();
    if (!LabelPicture.supports(url)) return _pill(); // a video file is not drawn on a profile
    if (tag.look == TagLook.picture) {
      // the artwork exactly as uploaded: a picture, a GIF / WebP or an SVGA animation; the pill stands in while it loads and if it can't be drawn
      return Semantics(
        label: tag.name,
        child: LabelPicture(key: ValueKey('tag-${tag.id}'), url: url, height: kTagPictureHeight, maxWidth: 220, fallback: _pill()),
      );
    }
    final plate = DecoratedBox(decoration: BoxDecoration(color: tag.color, borderRadius: BorderRadius.circular(20)));
    return Stack(
      key: ValueKey('tag-${tag.id}'),
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: mediaKindFor(url) == MediaKind.svga
              ? RemoteMedia(url, fit: BoxFit.fill, loop: true, fallback: plate)
              : Image(image: DiskCachedNetworkImage(url), fit: BoxFit.fill, errorBuilder: (_, _, _) => plate),
        ),
        Container(
          height: kTagPictureHeight,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            _label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              color: tag.textColor ?? Colors.white,
              shadows: const [Shadow(color: Color(0x99000000), blurRadius: 2, offset: Offset(0, 1))],
            ),
          ),
        ),
      ],
    );
  }
}

class _BadgeChip extends StatelessWidget {
  const _BadgeChip({required this.badge, this.onTap});
  final ProfileBadge badge;
  final VoidCallback? onTap;

  /// A badge picture is drawn as uploaded (still, GIF / WebP or SVGA). A video file (MP4) is not played here: a decoder per badge would cost battery.
  /// That, and a badge with no picture, is drawn as the emoji chip.
  bool get _hasPicture {
    final url = badge.iconUrl;
    return url != null && LabelPicture.supports(url);
  }

  Widget _chip() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.gold.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(badge.emoji, style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 4),
            Text(badge.name, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
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
                child: LabelPicture(key: ValueKey('badge-icon-${badge.id}'), url: badge.iconUrl!, height: kTagPictureHeight, fallback: _chip()),
              )
            : _chip(),
      );
}
