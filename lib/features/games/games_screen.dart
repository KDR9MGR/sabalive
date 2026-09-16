import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Placeholder for interactive games (spin wheel, dice, fishing, PK mini-games).
/// The game engine + coin-bet economy land in a later milestone.
class GamesScreen extends StatelessWidget {
  const GamesScreen({super.key});

  static const _games = [
    ('Lucky Spin', '🎡', 'Spin to win coins & gifts'),
    ('Dice Duel', '🎲', 'Roll against the room'),
    ('Fishing', '🐠', 'Cast for rare catches'),
    ('Teen Patti', '🃏', 'Classic 3-card game'),
    ('Fruit Loot', '🍉', 'Match & multiply'),
    ('PK Arena', '⚔️', 'Host vs host battles'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Games')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: AppColors.brandGradient,
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Row(
              children: [
                Text('🎮', style: TextStyle(fontSize: 28)),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Games are coming soon — you\'ll be able to play these live '
                    'in rooms and bet coins.',
                    style: TextStyle(color: Colors.white, fontSize: 12.5, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.1,
            children: [
              for (final (name, emoji, desc) in _games)
                Opacity(
                  opacity: 0.55,
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.stroke),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(emoji, style: const TextStyle(fontSize: 34)),
                        const SizedBox(height: 8),
                        Text(name,
                            style: const TextStyle(
                                fontFamily: 'Poppins',
                                fontWeight: FontWeight.w600,
                                fontSize: 13)),
                        const SizedBox(height: 2),
                        Text(desc,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 10, color: AppColors.textMuted)),
                        const SizedBox(height: 6),
                        const Text('SOON',
                            style: TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1,
                                color: AppColors.gold)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
