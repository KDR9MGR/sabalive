import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/utils/formatters.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/pills.dart';
import '../../data/mock_data.dart';
import '../../data/models.dart';
import '../../router/app_nav.dart';
import '../../theme/app_colors.dart';

class RankingsScreen extends StatefulWidget {
  const RankingsScreen({super.key});

  @override
  State<RankingsScreen> createState() => _RankingsScreenState();
}

class _RankingsScreenState extends State<RankingsScreen> {
  int _board = 0; // Hosts / Gifters / Rising
  int _period = 1; // Daily / Weekly / Monthly

  @override
  Widget build(BuildContext context) {
    final entries = List.of(Mock.rankings());
    if (_board == 1) {
      entries.shuffle(math.Random(7));
    } else if (_board == 2) {
      entries.sort((a, b) => b.rankChange.compareTo(a.rankChange));
    }
    final top3 = entries.take(3).toList();
    final rest = entries.skip(3).toList();

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
                    Text('Rankings',
                        style: Theme.of(context).textTheme.headlineSmall),
                    const Spacer(),
                    IconButton(
                        onPressed: () {},
                        icon: const Icon(Icons.info_outline_rounded)),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SegmentedTabs(
                  tabs: const ['Hosts', 'Gifters', 'Rising'],
                  index: _board,
                  onChanged: (i) => setState(() => _board = i),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 14)),
            SliverToBoxAdapter(
              child: ChipRow(
                items: const ['Daily', 'Weekly', 'Monthly'],
                index: _period,
                onChanged: (i) => setState(() => _period = i),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 18)),
            SliverToBoxAdapter(child: _podium(context, top3)),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final e = rest[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 26,
                            child: Text('${i + 4}',
                                style: const TextStyle(
                                    fontFamily: 'Poppins',
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textMuted)),
                          ),
                          AppAvatar(name: e.user.name, size: 40),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(e.user.name,
                                    style: const TextStyle(
                                        fontFamily: 'Poppins',
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13.5)),
                                Text('Lv ${e.user.level}',
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: AppColors.textMuted)),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.diamond_rounded,
                                      size: 12, color: AppColors.diamond),
                                  const SizedBox(width: 3),
                                  Text(compactCount(e.score),
                                      style: const TextStyle(
                                          fontFamily: 'Poppins',
                                          fontWeight: FontWeight.w600,
                                          fontSize: 12.5)),
                                ],
                              ),
                              _delta(e.rankChange),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                  childCount: rest.length,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _delta(int change) {
    if (change == 0) {
      return const Text('—',
          style: TextStyle(fontSize: 10, color: AppColors.textMuted));
    }
    final up = change > 0;
    return Row(
      children: [
        Icon(up ? Icons.arrow_drop_up_rounded : Icons.arrow_drop_down_rounded,
            size: 16, color: up ? AppColors.success : AppColors.danger),
        Text('${change.abs()}',
            style: TextStyle(
                fontSize: 10,
                color: up ? AppColors.success : AppColors.danger)),
      ],
    );
  }

  Widget _podium(BuildContext context, List<RankingEntry> top3) {
    if (top3.length < 3) return const SizedBox.shrink();
    Widget col(int place) {
      final e = top3[place == 1 ? 0 : (place == 2 ? 1 : 2)];
      final height = place == 1 ? 120.0 : (place == 2 ? 92.0 : 76.0);
      final medal = place == 1 ? AppColors.gold : (place == 2 ? const Color(0xFFC0C7D1) : const Color(0xFFCD7F32));
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => AppNav.watchLive(context, Mock.liveStreams.first),
          child: Column(
            children: [
              if (place == 1)
                const Icon(Icons.workspace_premium_rounded,
                    color: AppColors.gold, size: 22),
              AppAvatar(
                name: e.user.name,
                size: place == 1 ? 64 : 52,
                ring: true,
                ringColor: medal,
              ),
              const SizedBox(height: 6),
              Text(e.user.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w600,
                      fontSize: 12)),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.diamond_rounded,
                      size: 11, color: AppColors.diamond),
                  const SizedBox(width: 3),
                  Text(compactCount(e.score),
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textSecondary)),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                height: height,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      medal.withValues(alpha: 0.5),
                      AppColors.surface,
                    ],
                  ),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(14)),
                  border: Border.all(color: AppColors.stroke),
                ),
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('$place',
                      style: const TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w700,
                          fontSize: 20,
                          color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [col(2), col(1), col(3)],
      ),
    );
  }
}
