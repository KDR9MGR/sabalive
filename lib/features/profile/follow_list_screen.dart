import 'package:flutter/material.dart';

import '../../core/utils/errors.dart';
import '../../core/widgets/app_avatar.dart';
import '../../data/models.dart';
import '../../data/social_repository.dart';
import '../../router/app_nav.dart';
import '../../theme/app_colors.dart';

class FollowListScreen extends StatefulWidget {
  const FollowListScreen({
    super.key,
    required this.userId,
    required this.followers,
    this.title,
  });

  final String userId;
  final bool followers; // true = followers, false = following
  final String? title;

  @override
  State<FollowListScreen> createState() => _FollowListScreenState();
}

class _FollowListScreenState extends State<FollowListScreen> {
  final _repo = SocialRepository();
  bool _loading = true;
  String? _error;
  List<AppUser> _users = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final users = await _repo.followList(widget.userId, followers: widget.followers);
      if (!mounted) return;
      setState(() {
        _users = users;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? (widget.followers ? 'Followers' : 'Following')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _centered(_error!, retry: true)
              : _users.isEmpty
                  ? _centered(widget.followers
                      ? 'No followers yet.'
                      : 'Not following anyone yet.')
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        itemCount: _users.length,
                        itemBuilder: (context, i) {
                          final u = _users[i];
                          return ListTile(
                            onTap: () => AppNav.userProfile(context, u),
                            leading: AppAvatar(name: u.name, size: 44),
                            title: Text(u.name,
                                style: const TextStyle(
                                    fontFamily: 'Poppins',
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14)),
                            subtitle: Text(u.username,
                                style: const TextStyle(
                                    fontSize: 11.5, color: AppColors.textMuted)),
                            trailing: u.isLive
                                ? Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: AppColors.danger,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: const Text('LIVE',
                                        style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.white)),
                                  )
                                : const Icon(Icons.chevron_right_rounded,
                                    color: AppColors.textMuted),
                          );
                        },
                      ),
                    ),
    );
  }

  Widget _centered(String text, {bool retry = false}) => ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(40, 100, 40, 0),
            child: Column(
              children: [
                Text(text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textMuted)),
                if (retry) ...[
                  const SizedBox(height: 10),
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ],
              ],
            ),
          ),
        ],
      );
}
