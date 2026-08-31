import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/session_controller.dart';
import '../../theme/app_colors.dart';
import '../home/home_screen.dart';
import '../live/live_feed_screen.dart';
import '../messages/messages_screen.dart';
import '../rankings/rankings_screen.dart';
import '../profile/profile_screen.dart';

class MainShell extends StatelessWidget {
  const MainShell({super.key});

  static const _tabs = [
    _TabDef('Home', Icons.home_rounded, Icons.home_outlined),
    _TabDef('Live', Icons.podcasts_rounded, Icons.podcasts_rounded),
    _TabDef('Messages', Icons.chat_bubble_rounded, Icons.chat_bubble_outline_rounded),
    _TabDef('Rankings', Icons.emoji_events_rounded, Icons.emoji_events_outlined),
    _TabDef('Profile', Icons.person_rounded, Icons.person_outline_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final index = session.tab;

    return Scaffold(
      extendBody: true,
      body: IndexedStack(
        index: index,
        children: const [
          HomeScreen(),
          LiveFeedScreen(),
          MessagesScreen(),
          RankingsScreen(),
          ProfileScreen(),
        ],
      ),
      bottomNavigationBar: _BottomBar(
        index: index,
        tabs: _tabs,
        onTap: (i) => session.tab = i,
      ),
    );
  }
}

class _TabDef {
  const _TabDef(this.label, this.active, this.inactive);
  final String label;
  final IconData active;
  final IconData inactive;
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.tabs, required this.onTap});

  final int index;
  final List<_TabDef> tabs;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        top: 8,
        bottom: 8 + MediaQuery.of(context).padding.bottom * 0.4,
      ),
      decoration: BoxDecoration(
        color: AppColors.bgElevated.withValues(alpha: 0.96),
        border: const Border(top: BorderSide(color: AppColors.stroke)),
      ),
      child: Row(
        children: List.generate(tabs.length, (i) {
          final selected = i == index;
          final isLive = i == 1;
          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onTap(i),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: isLive ? 44 : 40,
                    height: isLive ? 44 : 34,
                    decoration: BoxDecoration(
                      gradient: isLive
                          ? AppColors.primaryGradient
                          : selected
                              ? LinearGradient(colors: [
                                  AppColors.primary.withValues(alpha: 0.18),
                                  AppColors.magenta.withValues(alpha: 0.18),
                                ])
                              : null,
                      borderRadius: BorderRadius.circular(isLive ? 16 : 12),
                      boxShadow: isLive
                          ? [
                              BoxShadow(
                                color: AppColors.primary.withValues(alpha: 0.5),
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ]
                          : null,
                    ),
                    child: Icon(
                      selected ? tabs[i].active : tabs[i].inactive,
                      size: isLive ? 24 : 22,
                      color: isLive
                          ? Colors.white
                          : selected
                              ? AppColors.primaryBright
                              : AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    tabs[i].label,
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      fontSize: 10,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected
                          ? AppColors.primaryBright
                          : AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}
