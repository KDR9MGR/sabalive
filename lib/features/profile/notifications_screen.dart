import 'package:flutter/material.dart';

import '../../core/utils/errors.dart';
import '../../data/models.dart';
import '../../data/social_repository.dart';
import '../../theme/app_colors.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final _repo = SocialRepository();
  bool _loading = true;
  String? _error;
  List<AppNotification> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await _repo.notifications();
      if (!mounted) return;
      setState(() {
        _items = items;
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

  Future<void> _markAll() async {
    setState(() => _items = [
          for (final n in _items)
            AppNotification(n.icon, n.color, n.text, n.time, unread: false, id: n.id)
        ]);
    try {
      await _repo.markAllNotificationsRead();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          if (_items.any((n) => n.unread))
            TextButton(
              onPressed: _markAll,
              child: const Text('Mark all read',
                  style: TextStyle(color: AppColors.primaryBright, fontSize: 12)),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _centered(_error!, retry: true);
    }
    if (_items.isEmpty) {
      return _centered('No notifications yet.');
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _items.length,
      separatorBuilder: (_, _) =>
          const Divider(color: AppColors.stroke, height: 1, indent: 68),
      itemBuilder: (context, i) {
        final n = _items[i];
        return Container(
          color: n.unread
              ? AppColors.primary.withValues(alpha: 0.06)
              : Colors.transparent,
          child: ListTile(
            onTap: n.id == null || !n.unread
                ? null
                : () async {
                    setState(() => _items[i] = AppNotification(
                        n.icon, n.color, n.text, n.time,
                        unread: false, id: n.id));
                    try {
                      await _repo.markNotificationRead(n.id!);
                    } catch (_) {}
                  },
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: n.color.withValues(alpha: 0.16),
                shape: BoxShape.circle,
              ),
              child: Icon(n.icon, color: n.color, size: 20),
            ),
            title:
                Text(n.text, style: const TextStyle(fontSize: 13, height: 1.35)),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(n.time,
                  style:
                      const TextStyle(fontSize: 11, color: AppColors.textMuted)),
            ),
            trailing: n.unread
                ? Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppColors.primaryBright,
                      shape: BoxShape.circle,
                    ),
                  )
                : null,
          ),
        );
      },
    );
  }

  Widget _centered(String text, {bool retry = false}) {
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 100, 40, 0),
          child: Column(
            children: [
              Icon(Icons.notifications_none_rounded,
                  size: 44, color: AppColors.textMuted.withValues(alpha: 0.6)),
              const SizedBox(height: 12),
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
}
