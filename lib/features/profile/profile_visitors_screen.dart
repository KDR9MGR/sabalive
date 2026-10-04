import 'package:flutter/material.dart' hide Text;

import '../../core/utils/formatters.dart';
import '../../core/widgets/app_avatar.dart';
import '../../data/profile_visits_repository.dart';
import '../../router/app_nav.dart';
import '../../theme/app_colors.dart';
import '../../core/i18n/text.dart';

/// Who's viewed your profile recently — real data from `profile_visits`,
/// scoped to your own visitors by RLS.
class ProfileVisitorsScreen extends StatefulWidget {
  const ProfileVisitorsScreen({super.key});

  @override
  State<ProfileVisitorsScreen> createState() => _ProfileVisitorsScreenState();
}

class _ProfileVisitorsScreenState extends State<ProfileVisitorsScreen> {
  final _repo = ProfileVisitsRepository();
  List<ProfileVisit> _visitors = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _repo.myVisitors().then((v) {
      if (!mounted) return;
      setState(() {
        _visitors = v;
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile Visitors')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _visitors.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No visitors yet — your profile visits will show up here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _visitors.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final v = _visitors[i];
                    return ListTile(
                      onTap: () => AppNav.userProfile(context, v.user),
                      leading: AppAvatar(name: v.user.name, imageUrl: v.user.avatarUrl, size: 44),
                      title: Text(v.user.name,
                          style: const TextStyle(
                              fontFamily: 'Poppins',
                              fontWeight: FontWeight.w600,
                              fontSize: 13.5)),
                      subtitle: Text('Visited ${relativeTime(v.visitedAt)}',
                          style: const TextStyle(
                              fontSize: 11.5, color: AppColors.textMuted)),
                      trailing: const Icon(Icons.chevron_right_rounded,
                          color: AppColors.textMuted),
                    );
                  },
                ),
    );
  }
}
