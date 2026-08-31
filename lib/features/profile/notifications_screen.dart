import 'package:flutter/material.dart';

import '../../data/mock_data.dart';
import '../../theme/app_colors.dart';

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final items = Mock.notifications();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton(
            onPressed: () {},
            child: const Text('Mark all read',
                style: TextStyle(color: AppColors.primaryBright, fontSize: 12)),
          ),
        ],
      ),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: items.length,
        separatorBuilder: (_, _) =>
            const Divider(color: AppColors.stroke, height: 1, indent: 68),
        itemBuilder: (context, i) {
          final n = items[i];
          return Container(
            color: n.unread
                ? AppColors.primary.withValues(alpha: 0.06)
                : Colors.transparent,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: n.color.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(n.icon, color: n.color, size: 20),
              ),
              title: Text(n.text,
                  style: const TextStyle(fontSize: 13, height: 1.35)),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(n.time,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textMuted)),
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
      ),
    );
  }
}
