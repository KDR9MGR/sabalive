import 'package:flutter/material.dart';

import '../../core/utils/errors.dart';
import '../../core/widgets/app_avatar.dart';
import '../../data/models.dart';
import '../../data/social_repository.dart';
import '../../theme/app_colors.dart';

class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
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
      final ids = await _repo.blockedIds();
      final users = <AppUser>[];
      for (final id in ids) {
        final u = await _repo.profile(id);
        if (u != null) users.add(u);
      }
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

  Future<void> _unblock(AppUser u) async {
    setState(() => _users = _users.where((x) => x.id != u.id).toList());
    try {
      await _repo.unblock(u.id);
    } catch (_) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked Users')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!,
                  style: const TextStyle(color: AppColors.textMuted)))
              : _users.isEmpty
                  ? const Center(
                      child: Text("You haven't blocked anyone.",
                          style: TextStyle(color: AppColors.textMuted)))
                  : ListView.builder(
                      itemCount: _users.length,
                      itemBuilder: (context, i) {
                        final u = _users[i];
                        return ListTile(
                          leading: AppAvatar(name: u.name, size: 42),
                          title: Text(u.name,
                              style: const TextStyle(
                                  fontFamily: 'Poppins',
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13.5)),
                          subtitle: Text(u.username,
                              style: const TextStyle(
                                  fontSize: 11.5, color: AppColors.textMuted)),
                          trailing: TextButton(
                            onPressed: () => _unblock(u),
                            child: const Text('Unblock'),
                          ),
                        );
                      },
                    ),
    );
  }
}
