import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../router/app_nav.dart';
import '../../state/session_controller.dart';
import '../../theme/app_colors.dart';
import '../home/home_screen.dart';
import '../live/live_feed_screen.dart';
import '../messages/messages_screen.dart';
import '../rankings/rankings_screen.dart';
import '../profile/profile_screen.dart';

class MainShell extends StatelessWidget {
  const MainShell({super.key});

  // "Live" sits in the centre slot — the prominent raised button. While
  // Live is the active tab, Games takes over the Rankings slot next to it
  // (pushes its own screen rather than swapping tabs); every other tab
  // shows Rankings there as normal.
  static const _tabs = [
    _TabDef('Home', Icons.home_rounded, Icons.home_outlined),
    _TabDef('Messages', Icons.chat_bubble_rounded, Icons.chat_bubble_outline_rounded),
    _TabDef('Live', Icons.podcasts_rounded, Icons.podcasts_rounded),
    _TabDef('Rankings', Icons.emoji_events_rounded, Icons.emoji_events_outlined),
    _TabDef('Profile', Icons.person_rounded, Icons.person_outline_rounded),
  ];

  static const _liveIndex = 2;
  static const _rankingsIndex = 3;

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
          MessagesScreen(),
          LiveFeedScreen(),
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
        children: [
          for (var i = 0; i < tabs.length; i++)
            if (i == MainShell._rankingsIndex && index == MainShell._liveIndex)
              _item(
                icon: Icons.sports_esports_rounded,
                label: 'Games',
                selected: false,
                raised: false,
                onTap: () => AppNav.games(context),
              )
            else
              _item(
                icon: index == i ? tabs[i].active : tabs[i].inactive,
                label: tabs[i].label,
                selected: index == i,
                raised: i == MainShell._liveIndex,
                onTap: () => onTap(i),
              ),
        ],
      ),
    );
  }

  Widget _item({
    required IconData icon,
    required String label,
    required bool selected,
    required bool raised,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: raised ? 44 : 40,
              height: raised ? 44 : 34,
              decoration: BoxDecoration(
                gradient: raised
                    ? AppColors.primaryGradient
                    : selected
                        ? LinearGradient(colors: [
                            AppColors.primary.withValues(alpha: 0.18),
                            AppColors.magenta.withValues(alpha: 0.18),
                          ])
                        : null,
                borderRadius: BorderRadius.circular(raised ? 16 : 12),
                boxShadow: raised
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
                icon,
                size: raised ? 24 : 22,
                color: raised
                    ? Colors.white
                    : selected
                        ? AppColors.primaryBright
                        : AppColors.textMuted,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Poppins',
                fontSize: 10,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? AppColors.primaryBright : AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
