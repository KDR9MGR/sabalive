import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/pills.dart';
import '../../core/widgets/section_header.dart';
import '../../router/app_nav.dart';
import '../../state/live_streams_controller.dart';
import '../../state/session_controller.dart';
import '../../theme/app_colors.dart';
import 'widgets/live_card.dart';

class LiveFeedScreen extends StatefulWidget {
  const LiveFeedScreen({super.key});

  @override
  State<LiveFeedScreen> createState() => _LiveFeedScreenState();
}

class _LiveFeedScreenState extends State<LiveFeedScreen> {
  int _tab = 1; // 0 Following, 1 Recommended
  int _cat = 0;
  final _cats = ['All', 'Music', 'Gaming', 'Chatting', 'Dance', 'PK Battles'];

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final all = context.watch<LiveStreamsController>().streams;
    final byCat = _cat == 0
        ? all
        : all.where((s) => s.category == _cats[_cat]).toList();
    final list = _tab == 0
        ? byCat.where((s) => session.isFollowing(s.host.id)).toList()
        : byCat;
    final trending = all.take(4).toList();

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 12, 6),
                    child: Row(
                      children: [
                        Text('Live', style: Theme.of(context).textTheme.headlineSmall),
                        const Spacer(),
                        IconButton(
                            onPressed: () => AppNav.search(context),
                            icon: const Icon(Icons.search_rounded)),
                        IconButton(
                            onPressed: () => AppNav.notifications(context),
                            icon: const Icon(Icons.notifications_none_rounded)),
                      ],
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 6)),
                SliverToBoxAdapter(
                  child: ChipRow(
                    items: _cats,
                    index: _cat,
                    onChanged: (i) => setState(() => _cat = i),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: SegmentedTabs(
                      tabs: const ['Following', 'Recommended'],
                      index: _tab,
                      onChanged: (i) => setState(() => _tab = i),
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 18)),
                if (list.isEmpty)
                  SliverToBoxAdapter(
                    child: _EmptyFeed(
                      following: _tab == 0,
                      noneLiveAtAll: all.isEmpty,
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        childAspectRatio: 0.78,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => LiveCard(
                          stream: list[i],
                          onTap: () => AppNav.watchLive(context, list[i]),
                        ),
                        childCount: list.length,
                      ),
                    ),
                  ),
                if (trending.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  SliverToBoxAdapter(
                    child: SectionHeader(title: 'Trending Now', onAction: () {}),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => LiveListTile(
                          stream: trending[i],
                          rank: i + 1,
                          onTap: () => AppNav.watchLive(context, trending[i]),
                        ),
                        childCount: trending.length,
                      ),
                    ),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 120)),
              ],
            ),
          ),
          Positioned(
            right: 20,
            bottom: 100 + MediaQuery.of(context).padding.bottom,
            child: _goLiveFab(context),
          ),
        ],
      ),
    );
  }

  Widget _goLiveFab(BuildContext context) {
    return GestureDetector(
      onTap: () => AppNav.goLive(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          gradient: AppColors.primaryGradient,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.45),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam_rounded, color: Colors.white, size: 20),
            SizedBox(width: 8),
            Text('Go Live',
                style: TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: Colors.white,
                )),
          ],
        ),
      ),
    );
  }
}

class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed({required this.following, required this.noneLiveAtAll});
  final bool following;
  final bool noneLiveAtAll;

  @override
  Widget build(BuildContext context) {
    final message = noneLiveAtAll
        ? "No one's live right now — be the first!"
        : following
            ? 'None of the people you follow are live right now.'
            : 'No live rooms in this category right now.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 30, 20, 30),
      child: Column(
        children: [
          const Icon(Icons.podcasts_rounded, size: 46, color: AppColors.textMuted),
          const SizedBox(height: 12),
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
