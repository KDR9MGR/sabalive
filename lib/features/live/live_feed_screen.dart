import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/pills.dart';
import '../../core/widgets/section_header.dart';
import '../../data/mock_data.dart';
import '../../router/app_nav.dart';
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
    final all = Mock.liveStreams;
    final byCat = _cat == 0
        ? all
        : all.where((s) => s.category == _cats[_cat]).toList();
    final list = _tab == 0
        ? byCat.where((s) => session.isFollowing(s.host.id)).toList()
        : byCat;

    return Scaffold(
      body: SafeArea(
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
                        onPressed: () {},
                        icon: const Icon(Icons.emoji_events_rounded,
                            color: AppColors.gold)),
                    IconButton(
                        onPressed: () {},
                        icon: const Icon(Icons.search_rounded)),
                    IconButton(
                        onPressed: () => AppNav.notifications(context),
                        icon: const Icon(Icons.notifications_none_rounded)),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(child: _goLiveCard(context)),
            const SliverToBoxAdapter(child: SizedBox(height: 18)),
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
              const SliverToBoxAdapter(child: _EmptyFeed())
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
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
            SliverToBoxAdapter(
              child: SectionHeader(title: 'Trending Now', onAction: () {}),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => LiveListTile(
                    stream: Mock.liveStreams[i],
                    rank: i + 1,
                    onTap: () => AppNav.watchLive(context, Mock.liveStreams[i]),
                  ),
                  childCount: Mock.liveStreams.length,
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
        ),
      ),
    );
  }

  Widget _goLiveCard(BuildContext context) {
    return GestureDetector(
      onTap: () => AppNav.goLive(context),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: AppColors.primaryGradient,
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.4),
              blurRadius: 26,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.videocam_rounded,
                  color: Colors.white, size: 28),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Go Live Now',
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                        color: Colors.white,
                      )),
                  SizedBox(height: 2),
                  Text('Share your moment with the world',
                      style: TextStyle(color: Colors.white70, fontSize: 12.5)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_rounded, color: Colors.white),
          ],
        ),
      ),
    );
  }
}

class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(20, 30, 20, 30),
      child: Column(
        children: [
          Icon(Icons.podcasts_rounded, size: 46, color: AppColors.textMuted),
          SizedBox(height: 12),
          Text('None of the people you follow are live right now.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
