import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/formatters.dart';
import '../../core/widgets/pills.dart';
import '../../core/widgets/saba_logo.dart';
import '../../core/widgets/section_header.dart';
import '../../data/mock_data.dart';
import '../../router/app_nav.dart';
import '../../state/auth_controller.dart';
import '../../state/live_streams_controller.dart';
import '../../state/session_controller.dart';
import '../../theme/app_colors.dart';
import '../live/widgets/live_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _cat = 0;
  final _cats = ['All', ...Mock.categories.take(5).map((c) => c.label)];

  @override
  Widget build(BuildContext context) {
    final source = context.watch<LiveStreamsController>().streams;
    final streams = _cat == 0
        ? source
        : source.where((s) => s.category == _cats[_cat]).toList();
    final trending = source;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () =>
              context.read<LiveStreamsController>().refresh(),
          child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _header(context)),
            SliverToBoxAdapter(child: _banner(context)),
            const SliverToBoxAdapter(child: SizedBox(height: 18)),
            SliverToBoxAdapter(
              child: ChipRow(
                items: _cats,
                index: _cat,
                onChanged: (i) => setState(() => _cat = i),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 18)),
            SliverToBoxAdapter(
              child: SectionHeader(
                  title: source.isNotEmpty ? '🔴 Live Now' : 'Live Now',
                  onAction: () => AppNav.search(context)),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            if (streams.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                  child: Text(
                    source.isEmpty
                        ? "No one's live right now — be the first!"
                        : 'No live rooms in this category right now.',
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
                  ),
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
                    childAspectRatio: 0.82,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => LiveCard(
                      stream: streams[i],
                      onTap: () => AppNav.watchLive(context, streams[i]),
                    ),
                    childCount: streams.length,
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
            SliverToBoxAdapter(
              child: SectionHeader(title: 'Categories', onAction: () {}),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            SliverToBoxAdapter(child: _categoryStrip()),
            if (trending.isNotEmpty) ...[
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
              SliverToBoxAdapter(
                child: SectionHeader(
                  title: 'Trending Now',
                  onAction: () => AppNav.search(context),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 4)),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => LiveListTile(
                      stream: trending[i],
                      rank: i + 1,
                      onTap: () => AppNav.watchLive(context, trending[i]),
                    ),
                    childCount: trending.length < 4 ? trending.length : 4,
                  ),
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
      child: Row(
        children: [
          const SabaLogo(size: 34, glow: false),
          const SizedBox(width: 10),
          const Text('SABA LIVE',
              style: TextStyle(
                fontFamily: 'Poppins',
                fontWeight: FontWeight.w700,
                fontSize: 16,
                letterSpacing: 0.4,
                color: AppColors.textPrimary,
              )),
          const Spacer(),
          _iconBtn(Icons.search_rounded, () => AppNav.search(context)),
          _iconBtn(Icons.emoji_events_rounded,
              () => context.read<SessionController>().tab = 3,
              color: AppColors.gold),
          _iconBtn(Icons.notifications_none_rounded,
              () => AppNav.notifications(context)),
        ],
      ),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap, {Color? color}) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, color: color ?? AppColors.textPrimary),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _banner(BuildContext context) {
    final name = context.watch<AuthController>().user?.name;
    final greeting = (name == null || name.isEmpty)
        ? 'Welcome back'
        : 'Welcome back, ${name.split(' ').first}';

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: AppColors.brandGradient,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: AppColors.magenta.withValues(alpha: 0.3),
            blurRadius: 26,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(greeting,
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                      color: Colors.white,
                    )),
                const SizedBox(height: 4),
                Text('Go live or find someone to watch right now',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 12.5)),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: () => AppNav.goLive(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text('Go Live',
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5,
                          color: AppColors.primaryDeep,
                        )),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.waving_hand_rounded,
                color: Colors.white, size: 34),
          ),
        ],
      ),
    );
  }

  Widget _categoryStrip() {
    return SizedBox(
      height: 108,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: Mock.categories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final c = Mock.categories[i];
          return Column(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.stroke),
                ),
                child: Icon(c.icon, color: AppColors.primaryBright, size: 26),
              ),
              const SizedBox(height: 6),
              Text(c.label,
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textSecondary)),
              Text('${compactCount(c.streams)} live',
                  style: const TextStyle(
                      fontSize: 9, color: AppColors.textMuted)),
            ],
          );
        },
      ),
    );
  }
}
