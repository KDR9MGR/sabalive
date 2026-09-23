import 'package:flutter/material.dart';

import '../../core/utils/formatters.dart';
import '../../data/levels_repository.dart';
import '../../theme/app_colors.dart';

/// Real level/XP progress — profiles.xp/level, earned by sending or
/// receiving gifts (award_gift_xp trigger), against the level_thresholds
/// catalog.
class MyLevelScreen extends StatefulWidget {
  const MyLevelScreen({super.key});

  @override
  State<MyLevelScreen> createState() => _MyLevelScreenState();
}

class _MyLevelScreenState extends State<MyLevelScreen> {
  MyLevel? _data;

  @override
  void initState() {
    super.initState();
    LevelsRepository().mine().then((v) {
      if (mounted) setState(() => _data = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(title: const Text('My Level')),
      body: data == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
              children: [
                _header(data),
                const SizedBox(height: 24),
                const Text('All Levels',
                    style: TextStyle(
                        fontFamily: 'Poppins',
                        fontWeight: FontWeight.w600,
                        fontSize: 15)),
                const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.3,
                  children: [
                    for (final t in data.thresholds)
                      _levelCard(t, current: t.level == data.level, unlocked: t.level <= data.level),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _header(MyLevel data) {
    final next = data.next;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: AppColors.brandGradient,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.military_tech_rounded, color: Colors.white, size: 22),
                Text('${data.level}',
                    style: const TextStyle(
                        fontFamily: 'Poppins',
                        fontWeight: FontWeight.w700,
                        fontSize: 20,
                        color: Colors.white)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text('Level ${data.level}',
              style: const TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                  color: Colors.white)),
          const SizedBox(height: 12),
          Text(
            next == null ? 'Max level reached' : 'Progress to Level ${next.level}',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12.5),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: data.progress,
              minHeight: 8,
              backgroundColor: Colors.white.withValues(alpha: 0.25),
              valueColor: const AlwaysStoppedAnimation(Colors.white),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${withThousands(data.xp)} XP',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 11.5)),
              if (next != null)
                Text('${withThousands(next.xpRequired)} XP',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 11.5)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _levelCard(LevelThreshold t, {required bool current, required bool unlocked}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: current ? AppColors.primaryBright : AppColors.stroke,
            width: current ? 1.6 : 1),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: unlocked
                  ? AppColors.primary.withValues(alpha: 0.16)
                  : Colors.white.withValues(alpha: 0.05),
              border: Border.all(
                  color: unlocked ? AppColors.primaryBright : AppColors.stroke),
            ),
            alignment: Alignment.center,
            child: Icon(
              unlocked ? Icons.military_tech_rounded : Icons.lock_outline_rounded,
              size: 20,
              color: unlocked ? AppColors.primaryBright : AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 8),
          Text('Level ${t.level}',
              style: TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                  color: current ? AppColors.primaryBright : AppColors.textPrimary)),
          Text('${withThousands(t.xpRequired)} XP',
              style: const TextStyle(fontSize: 10.5, color: AppColors.textMuted)),
        ],
      ),
    );
  }
}
