import 'package:flutter/material.dart' hide Text;

import '../../core/widgets/label_picture.dart';
import '../../data/badges_repository.dart';
import '../../theme/app_colors.dart';
import '../../core/i18n/text.dart';

/// Full badge catalog + what you've actually earned — real data from
/// `badges`/`user_badges`, no mock. Badges are admin-awarded (judged
/// achievements like "Event Winner"), so this is read-only.
class BadgesScreen extends StatefulWidget {
  const BadgesScreen({super.key, required this.profileId, @visibleForTesting this.loader});
  final String profileId;

  /// Replaces the database read (tests).
  final Future<List<BadgeInfo>> Function(String profileId)? loader;

  @override
  State<BadgesScreen> createState() => _BadgesScreenState();
}

class _BadgesScreenState extends State<BadgesScreen> {
  List<BadgeInfo>? _badges;

  @override
  void initState() {
    super.initState();
    (widget.loader ?? BadgesRepository().allWithOwnership)(widget.profileId).then((b) {
      if (mounted) setState(() => _badges = b);
    });
  }

  @override
  Widget build(BuildContext context) {
    final badges = _badges;
    return Scaffold(
      appBar: AppBar(title: const Text('Badges')),
      body: badges == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
              children: [
                _myBadge(badges),
                const SizedBox(height: 24),
                const Text('All Badges',
                    style: TextStyle(
                        fontFamily: 'Poppins',
                        fontWeight: FontWeight.w600,
                        fontSize: 15)),
                const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.15,
                  children: [for (final b in badges) _badgeCard(b)],
                ),
              ],
            ),
    );
  }

  Widget _myBadge(List<BadgeInfo> badges) {
    final owned = badges.where((b) => b.owned).toList();
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: AppColors.brandGradient,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        children: [
          if (owned.isEmpty)
            const Text('—', style: TextStyle(fontSize: 44))
          else
            // the picture uploaded for the badge, as it is (the emoji only when none was uploaded)
            _badgeArt(owned.first, 64, key: const ValueKey('my-badge-art')),
          const SizedBox(height: 8),
          Text(
            owned.isEmpty ? 'No badges yet' : '${owned.length} badge${owned.length == 1 ? '' : 's'} earned',
            style: const TextStyle(
                fontFamily: 'Poppins',
                fontWeight: FontWeight.w700,
                fontSize: 15,
                color: Colors.white),
          ),
          const SizedBox(height: 4),
          Text(
            owned.isEmpty
                ? 'Earn them by streaming & gifting'
                : owned.map((b) => b.name).join(' · '),
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  /// A badge's own picture at [height] (still, GIF / WebP or SVGA), or its emoji when the panel uploaded none or the file can't be drawn.
  Widget _badgeArt(BadgeInfo b, double height, {Key? key}) {
    final emoji = Text(b.emoji, style: TextStyle(fontSize: height * 0.73));
    final url = b.iconUrl;
    if (url == null || !LabelPicture.supports(url)) return SizedBox(key: key, height: height, child: Center(child: emoji));
    return SizedBox(
      key: key,
      height: height,
      child: Center(child: LabelPicture(url: url, height: height, maxWidth: 130, fallback: emoji)),
    );
  }

  Widget _badgeCard(BadgeInfo b) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: b.owned ? AppColors.gold : AppColors.stroke),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Opacity(
            opacity: b.owned ? 1 : 0.35,
            child: _badgeArt(b, 44, key: ValueKey('badge-art-${b.id}')),
          ),
          const SizedBox(height: 8),
          Text(b.name,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                  color: b.owned ? AppColors.textPrimary : AppColors.textMuted)),
          const SizedBox(height: 3),
          Text(b.criteria,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
        ],
      ),
    );
  }
}
